//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: aurora_flow_control.sv
//
// Description:
//
//   This module is a simple flow control block for Aurora 64b/66b. It uses a
//   single data FIFO to buffer one full packet coming in from the Aurora
//   interface. The flow control block will monitor the data FIFO and send flow
//   control messages to the Aurora IP to pause and resume the data flow,
//   depending on the FIFO fill level.
//
//   The flow control method is based on the Xilinx PG074 document. The flow
//   control mechanism is called Native Flow Control (NFC) and is used to pause
//   and resume the data flow between the Aurora data source and this module.
//
//   The following flow control parameters are set by inputs to this module:
//
//   nfc_pause_count: This is the pause count to provide to the Aurora NFC
//       interface when flow control is triggered. When the nfc_pause_threshold
//       is reached, an NFC message will be sent via Aurora to request the
//       transmit side to pause transmissions for nfc_pause_count cycles of the
//       Aurora user clock. After this message is received, the transmitter will
//       pause all transmissions for nfc_pause_count cycles before automatically
//       resuming transmissions.
//       When set to 0, the Aurora NFC XOFF Start/Stop flow control mode, is 
//       used, where an indefinite pause is requested once the pause threshold 
//       is reached. This will cause the transmitter to completely stop sending
//       data, until an NFC resume message is received. A resume message is sent
//       when the data FIFO has more than nfc_resume_thresh space available.
//
//   nfc_pause_thresh: The threshold for remaining space in the data FIFO, at
//      which to pause or stop the Aurora transfer by sending a pause/stop message.
//
//   nfc_resume_thresh: The threshold for remaining space in the data FIFO, at
//      which to resume the Aurora transfer. This is checked when XOFF Start/Stop
//      flow control mode is used and should therefore be set to a value around
//      greater than nfc_pause threshold.
//
//   NOTE: The flow control functionality depends on the Aurora transmitter 
//       supporting the same NFC immediate flow control mode as per the Aurora 
//       64b/66b protocol specification v1.3.
//
//
// Parameters:
//
//   DATA_WIDTH:          The width of the data bus in bits.
//   MAX_PKT_SIZE_WORDS:  The size of the packet in data words, each being
//                        DATA_WIDTH in size.

`default_nettype none

module aurora_flow_control #(
  parameter int DATA_WIDTH = 256,
  parameter int MAX_PKT_SIZE_WORDS = 1024,
  parameter int THRESH_WIDTH = 8
) (
  // Clock and Reset
  input wire clk,
  input wire rst,

  // Flow-control Parameters
  input wire [             7:0] nfc_pause_count,
  input wire [THRESH_WIDTH-1:0] nfc_pause_thresh,
  input wire [THRESH_WIDTH-1:0] nfc_resume_thresh,

  // Data interface in (from Aurora)
  input wire [  DATA_WIDTH-1:0] i_tdata,
  input wire [DATA_WIDTH/8-1:0] i_tkeep,
  input wire                    i_tvalid,
  input wire                    i_tlast,

  // CRC interface in (from Aurora)
  // CRC pass/fail indicator, 1 indicates pass, 0 indicates fail.
  input wire i_crc_pass,
  // CRC valid indicator, expected to be valid at tlast.
  input wire i_crc_valid,

  // Data interface out (to Deframer)
  output logic [  DATA_WIDTH-1:0] o_tdata,
  output logic [DATA_WIDTH/8-1:0] o_tkeep,
  output logic                    o_tvalid,
  output logic                    o_tlast,
  input  wire                     o_tready,

  // Flow control interface to Aurora
  output logic        m_axi_nfc_tvalid,
  output logic [15:0] m_axi_nfc_tdata,
  input  wire         m_axi_nfc_tready,

  // Monitoring signals
  output logic fc_overflow_stb,
  output logic crc_error_stb
);

  //---------------------------------------------------------------------------
  //
  //---------------------------------------------------------------------------
  // Local parameters
  //---------------------------------------------------------------------------

  // Deadlock can occur if we don't have enough room in the data FIFO to store
  // a complete packet when data flow is paused by flow control. Here we ensure
  // that the buffer is large enough to store a maximum sized packet before
  // flow control can be paused.
  localparam int DATA_FIFO_SIZE_LOG2 = $clog2(
    MAX_PKT_SIZE_WORDS + 2 ** THRESH_WIDTH
  );

  // For the NFC pause request, the nfc_pause_count is the number of cycles to
  // pause the data flow. The NFC_PAUSE_EXTENSION_DELAY is used to ensure that
  // before the nfc_pause_count runs out, we check if we are still above
  // the pause threshold. If we are above the threshold, we will send a new
  // pause request to the Aurora IP to extend the pause.
  localparam int NFC_PAUSE_EXTENSION_DELAY = 10;

  // If the pause count is less than the resume delay, fall back to the
  // default value of 100 cycles. This is to ensure that we have a minimum
  // delay before sending the resume request.
  localparam int NFC_PAUSE_COUNT_FALLBACK = 100;


  // NFC request structure, little endian,
  // see Xilinx PG074 Flow control interface NFC message for details*.
  // * although IP is v12, please refer to v11.2, as v12 has documentation
  // error in figure 19.
  typedef struct packed unsigned {
    logic [6:0] reserved;
    logic       xoff;
    logic [7:0] data;
  } nfc_request_t;

  //----------------------------------------------------------------------------
  // NFC request templates
  //----------------------------------------------------------------------------
  // Pause request: xoff = 0, data = nfc_pause_count
  //  - Sender pauses for nfc_pause_count cycles.
  //  - This is sent when the data FIFO has less than nfc_pause_thresh space
  //    available and nfc_pause_count is non-zero.
  // Stop request: xoff = 1, data = 0
  //  - Sender stops sending data.
  //  - This is sent when the data FIFO has less than nfc_pause_thresh space
  //    available and nfc_pause_count is zero.
  // Resume request: xoff = 0, data = 0
  //  - Sender resumes sending data.
  //  - This is sent when the data FIFO has more than nfc_resume_thresh space
  //    available.
  wire nfc_request_t NFC_PAUSE_REQUEST = '{0, 0, nfc_pause_count};
  wire nfc_request_t NFC_PAUSE_REQUEST_FALLBACK =
  '{0, 0, NFC_PAUSE_COUNT_FALLBACK}
  ;
  wire nfc_request_t NFC_STOP_REQUEST = '{0, 1, 0};
  wire nfc_request_t NFC_RESUME_REQUEST = '{0, 0, 0};

  //---------------------------------------------------------------------------
  // Local signals
  //---------------------------------------------------------------------------
  // Control FIFO signals
  logic [DATA_FIFO_SIZE_LOG2-1:0] ctrl_packet_word_cnt_wr = 0; // # words written to data fifo.
  logic [DATA_FIFO_SIZE_LOG2-1:0] ctrl_packet_cnt_wr_buf = 0;   // Buffer for words written.
  logic ctrl_packet_crc_pass_wr = 0;  // CRC pass indicator input.
  logic [DATA_FIFO_SIZE_LOG2-1:0] ctrl_packet_word_cnt_rd = 0; // # words to read from fifo.
  logic [DATA_FIFO_SIZE_LOG2-1:0] ctrl_packet_cnt_rd_buf;       // Buffer for # blocks to read.
  logic ctrl_packet_crc_pass_rd;  // CRC pass indicator output.
  logic ctrl_fifo_write_tvalid = '0;  // Write valid data to ctrl fifo.
  logic ctrl_fifo_write_tready;  // Indicates if the ctrl fifo can accept data.
  logic ctrl_fifo_read_tready = '0;  // Read data from ctrl fifo.
  logic ctrl_fifo_read_tvalid;  // Indicates data available in ctrl fifo.
  logic [15:0] ctrl_fifo_fullness;  // Control fifo full indicator.

  // Data FIFO signals
  logic [15:0] data_fifo_space_remaining;  // Remaining space in data fifo.
  logic data_in_tready;
  logic data_out_tvalid;  // Data out valid signal.
  logic data_out_tready;  // Data out ready signal.

  // Monitoring signals
  logic [31:0] nfc_idle_timeout = 0;  // Timeout counter for NFC messages.
  logic of_packet_corrupted = 0;  // Packet corrupted indicator
                                  // asserted at buffer overflow.

  // Internal signals
  logic data_out_enable = '0;  // Enable output tvalid signal.
  logic out_tready_bypass = '0;  // Bypass output tready signal.

  // Simulation signals
  //synthesis translate_off

  // Disable buffer overflow check.
  // This is used by select testbenches to disable the buffer overflow check,
  // in order to allow the testbench to continue to run after a buffer overflow
  // occurs. This is used to verify that packets corrupted by buffer overflows
  // are correctly detected and dropped
  logic disable_buffer_overflow_assertion = 0;
  //synthesis translate_on

  //---------------------------------------------------------------------------
  // Internal submodules
  //---------------------------------------------------------------------------

  // AXI FIFO buffer for one aurora packet plus some delay overhead.
  axi_fifo #(
    .WIDTH($bits(i_tdata) + $bits(i_tkeep) + $bits(i_tlast)),
    .SIZE (DATA_FIFO_SIZE_LOG2)
  ) flow_control_fifo (
    .clk(clk),
    .reset(rst),
    .clear(1'b0),
    .i_tdata({i_tlast, i_tkeep, i_tdata}),
    .i_tvalid(i_tvalid),
    .i_tready(data_in_tready),
    .o_tdata({o_tlast, o_tkeep, o_tdata}),
    .o_tvalid(data_out_tvalid),
    .o_tready(data_out_tready),
    .space(data_fifo_space_remaining),
    .occupied()
  );

  // Control FIFO buffer for control metadata.
  axi_fifo #(
    .WIDTH(1 + $bits(ctrl_packet_word_cnt_wr)),
    .SIZE (DATA_FIFO_SIZE_LOG2)
  ) control_fifo (
    .clk(clk),
    .reset(rst),
    .clear(1'b0),
    .i_tdata({
      ctrl_packet_crc_pass_wr && !of_packet_corrupted, ctrl_packet_cnt_wr_buf
    }),
    .i_tvalid(ctrl_fifo_write_tvalid),
    .i_tready(ctrl_fifo_write_tready),
    .o_tdata({ctrl_packet_crc_pass_rd, ctrl_packet_cnt_rd_buf}),
    .o_tvalid(ctrl_fifo_read_tvalid),
    .o_tready(ctrl_fifo_read_tready),
    .space(),
    .occupied(ctrl_fifo_fullness)
  );

  //synthesis translate_off
  always @(posedge clk) begin
    // Some Testbenches want to check for buffer overflows occuring, so we use
    // this parameter to switch on/off the overflow detection within the module.
    if (!disable_buffer_overflow_assertion) begin
      if (i_tvalid && !data_in_tready) begin
        $fatal(1, "Buffer overflow detected on FC data fifo!");
      end
      if (ctrl_fifo_write_tvalid && !ctrl_fifo_write_tready) begin
        $fatal(1, "Buffer overflow detected on FC control fifo!");
      end
    end
  end

  // Check that the NFC parameters are set correctly:

  // The pause count must be greater than the extension delay to ensure that
  // we don't have negative timeout determining the time to wait before sending
  // a new pause request.
  always_comb
    assert (rst || (nfc_pause_count > NFC_PAUSE_EXTENSION_DELAY) || 
      (nfc_pause_count == 0) || $isunknown(
      nfc_pause_count
    ))
    else $warning("NFC pause count is less than the extension delay!");

  // The pause threshold must be less than the resume threshold to ensure,
  // otherwise we will never resume transmissions after sending an XOFF nfc request.
  always_comb
    assert (rst || (nfc_pause_thresh < nfc_resume_thresh) || $isunknown(
      nfc_pause_thresh
    ) || $isunknown(
      nfc_resume_thresh
    ))
    else $fatal(1, "NFC resume threshold is less than the pause threshold!");

  // The pause count fallback value must be greater than the pause extension delay
  // otherwise it defeats the purpose of having a fallback value to use when the 
  // pause count is less than the extension delay.
  always_comb
    assert (NFC_PAUSE_COUNT_FALLBACK > NFC_PAUSE_EXTENSION_DELAY)
    else
      $fatal(1, "NFC pause count fallback is less than the extension delay!");

  //synthesis translate_on

  //---------------------------------------------------------------------------
  // Flow control logic
  //---------------------------------------------------------------------------
  //
  // The flow control logic is implemented as three separate processes:
  // 1. Write process: This process is responsible for writing incoming data
  //    to the data FIFO, and for writing control information to the control FIFO.
  // 2. Read process: This process is responsible for forwarding valid
  //    packets from the data FIFO to the output interface.
  // 3. Monitor process: This process is responsible for monitoring the fill
  //    level of the data FIFO and sending flow control messages to the Aurora
  //    IP to pause and resume the data flow.
  //
  //---------------------------------------------------------------------------

  //----------------------------------------------------------------------------
  // Write process
  //----------------------------------------------------------------------------
  typedef enum logic [1:0] {
    READY_FOR_DATA,
    WRITE_PACKET,
    END_OF_PACKET
  } write_proc_state_t;

  write_proc_state_t current_write_state;
  write_proc_state_t next_write_state;

  always_comb begin : Write_proc_FSM_comb
    next_write_state = current_write_state;
    case (current_write_state)
      READY_FOR_DATA: begin
        if (i_tvalid) begin
          next_write_state = WRITE_PACKET;
        end
      end
      WRITE_PACKET: begin
        if (i_tvalid && i_tlast) begin
          next_write_state = END_OF_PACKET;
        end
      end
      END_OF_PACKET: begin
        if (i_tvalid) begin
          next_write_state = WRITE_PACKET;
        end else begin
          next_write_state = READY_FOR_DATA;
        end
      end
    endcase
  end

  always_ff @(posedge clk) begin : Write_proc_FSM_registered
    current_write_state     <= next_write_state;
    ctrl_fifo_write_tvalid  <= 0;
    ctrl_packet_crc_pass_wr <= 0;
    crc_error_stb           <= 0;

    case (next_write_state)
      READY_FOR_DATA: begin
        if (i_tvalid) begin
          ctrl_packet_word_cnt_wr <= 1;
        end
      end
      WRITE_PACKET: begin
        if (i_tvalid) begin
          ctrl_packet_word_cnt_wr <= ctrl_packet_word_cnt_wr + 1;
        end
      end
      END_OF_PACKET: begin
        // If we have a valid packet and the output is ready, we can send it.
        if (i_tvalid && i_tlast) begin
          ctrl_fifo_write_tvalid <= 1;
          ctrl_packet_cnt_wr_buf <= ctrl_packet_word_cnt_wr;
          if (i_crc_valid && i_crc_pass) begin
            ctrl_packet_crc_pass_wr <= 1;
          end else begin
            // If CRC is not valid at tlast, we will not forward the packet.
            // PG074 specifies Aurora CRC valid coincides with tlast, so assuming
            // that the CRC is always valid at tlast and not later.
            ctrl_packet_crc_pass_wr <= 0;
            crc_error_stb <= 1;
          end
          ctrl_packet_word_cnt_wr <= 0;
        end else if (i_tvalid) begin
          ctrl_packet_word_cnt_wr <= ctrl_packet_word_cnt_wr + 1;
        end
      end
    endcase

    if (rst) begin
      current_write_state      <= READY_FOR_DATA;
      ctrl_fifo_write_tvalid   <= 0;
      ctrl_packet_word_cnt_wr  <= 0;
      ctrl_packet_crc_pass_wr  <= 0;
      crc_error_stb            <= 0;
    end
  end

  // Forwarding process, drop packet if CRC failed.
  always_comb begin : forward_valid_packets
    // If we have a valid packet, or the packet is broken, push out the packet.
    o_tvalid = data_out_tvalid && data_out_enable;
    data_out_tready = (o_tready && data_out_enable) || out_tready_bypass;
  end


  //----------------------------------------------------------------------------
  // Read process
  //----------------------------------------------------------------------------
  typedef enum logic [1:0] {
    WAIT_FOR_DATA,
    LOAD_CTRL_METADATA,
    FORWARD_DATA
  } read_proc_state_t;
  read_proc_state_t current_read_state;
  read_proc_state_t next_read_state;

  always_comb begin : Read_proc_FSM_comb
    next_read_state = current_read_state;
    case (current_read_state)
      WAIT_FOR_DATA: begin
        if (ctrl_fifo_read_tvalid) begin
          // If we have a valid packet and the output is ready, we can send it.
          next_read_state = LOAD_CTRL_METADATA;
        end else begin
          next_read_state = WAIT_FOR_DATA;
        end
      end
      LOAD_CTRL_METADATA: begin
        next_read_state = FORWARD_DATA;
      end
      FORWARD_DATA: begin
        if (ctrl_packet_word_cnt_rd > 0) begin
          // If we have a valid packet and the output is ready, we can send it.
          next_read_state = FORWARD_DATA;
        end else if (~(data_out_tready && data_out_tvalid)) begin
          next_read_state = FORWARD_DATA;
        end else if (ctrl_fifo_read_tvalid) begin
          next_read_state = LOAD_CTRL_METADATA;
        end else begin
          next_read_state = WAIT_FOR_DATA;
        end
      end
    endcase
  end

  always_ff @(posedge clk) begin : Read_proc_FSM_registered
    current_read_state    <= next_read_state;
    ctrl_fifo_read_tready <= 0;
    case (next_read_state)
      WAIT_FOR_DATA: begin
        data_out_enable   <= 0;
        out_tready_bypass <= 0;
      end
      LOAD_CTRL_METADATA: begin
        // If we have a valid packet and the output is ready, we can send it.
        if (data_out_tready && data_out_tvalid) begin
          ctrl_packet_word_cnt_rd <= ctrl_packet_word_cnt_rd - 1;
        end
        ctrl_fifo_read_tready    <= 1;
        ctrl_packet_word_cnt_rd <= ctrl_packet_cnt_rd_buf;
        data_out_enable          <= ctrl_packet_crc_pass_rd;
        out_tready_bypass        <= !ctrl_packet_crc_pass_rd;
      end
      FORWARD_DATA: begin
        // If we are currently pushing out a packet, check if we can send the next
        // block of the packet. If so, it is sent and we decrement the counter.
        if (data_out_tready && data_out_tvalid) begin
          ctrl_packet_word_cnt_rd <= ctrl_packet_word_cnt_rd - 1;
        end
      end
    endcase

    if (rst) begin
      current_read_state       <= WAIT_FOR_DATA;
      ctrl_fifo_read_tready    <= 0;
      ctrl_packet_word_cnt_rd <= 0;
      data_out_enable          <= 0;
      out_tready_bypass        <= 0;
    end
  end


  //----------------------------------------------------------------------------
  // Monitor process
  //----------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    SEND_NFC_PAUSE,
    SEND_NFC_STOP,
    NFC_PAUSE_SENT,
    NFC_STOP_SENT,
    SEND_NFC_RESUME
  } monitor_proc_state_t;
  monitor_proc_state_t current_monitor_state;
  monitor_proc_state_t next_monitor_state;

  always_comb begin : Monitor_proc_FSM_comb
    next_monitor_state = current_monitor_state;

    case (current_monitor_state)
      IDLE: begin
        if (data_fifo_space_remaining < nfc_pause_thresh) begin
          if (nfc_pause_count > 0) begin
            next_monitor_state = SEND_NFC_PAUSE;
          end else begin
            next_monitor_state = SEND_NFC_STOP;
          end
        end
      end
      SEND_NFC_PAUSE: begin
        next_monitor_state = NFC_PAUSE_SENT;
      end
      SEND_NFC_STOP: begin
        next_monitor_state = NFC_STOP_SENT;
      end
      NFC_PAUSE_SENT: begin
        next_monitor_state = current_monitor_state;
        if (nfc_idle_timeout == '0) begin
          if (data_fifo_space_remaining < nfc_pause_thresh) begin
            next_monitor_state = SEND_NFC_PAUSE;
          end else begin
            next_monitor_state = IDLE;
          end
        end
      end
      NFC_STOP_SENT: begin
        next_monitor_state = current_monitor_state;
        if (data_fifo_space_remaining > nfc_resume_thresh) begin
          next_monitor_state = SEND_NFC_RESUME;
        end
      end
      SEND_NFC_RESUME: begin
        next_monitor_state = IDLE;
      end
    endcase
  end

  always_ff @(posedge clk) begin : Monitor_proc_FSM_registered
    current_monitor_state <= next_monitor_state;
    fc_overflow_stb <= 0;
    // If we are sending a NFC message and it is accepted, clear the valid 
    // signal.
    if (m_axi_nfc_tvalid && m_axi_nfc_tready) begin
      m_axi_nfc_tvalid <= 1'b0;
    end

    // NFC message handling
    case (next_monitor_state)
      IDLE: begin
        nfc_idle_timeout <= '0;
      end
      SEND_NFC_PAUSE: begin
        m_axi_nfc_tvalid <= 1'b1;
        // Set the timeout for the NFC message slightly less than the pause count
        // to ensure that we can potentially send another pause request.
        if (nfc_pause_count > NFC_PAUSE_EXTENSION_DELAY) begin
          m_axi_nfc_tdata  <= NFC_PAUSE_REQUEST;
          nfc_idle_timeout <= nfc_pause_count - NFC_PAUSE_EXTENSION_DELAY;
        end else begin
          // If the pause count is less than the delay, we will not be able to
          // send another pause request.
          m_axi_nfc_tdata <= NFC_PAUSE_REQUEST_FALLBACK;
          nfc_idle_timeout <= NFC_PAUSE_COUNT_FALLBACK - NFC_PAUSE_EXTENSION_DELAY;
        end
      end
      SEND_NFC_STOP: begin
        m_axi_nfc_tvalid <= 1'b1;
        m_axi_nfc_tdata  <= NFC_STOP_REQUEST;
      end
      NFC_PAUSE_SENT: begin
        nfc_idle_timeout <= nfc_idle_timeout - 1;
      end
      NFC_STOP_SENT: begin
      end
      SEND_NFC_RESUME: begin
        m_axi_nfc_tvalid <= 1'b1;
        m_axi_nfc_tdata  <= NFC_RESUME_REQUEST;
      end
    endcase

    if (of_packet_corrupted) begin
      // Clear the overflow indicator once the corrupted packet has ended.
      if (i_tvalid && i_tlast && (data_fifo_space_remaining > 0)) begin
        of_packet_corrupted <= 0;
      end
    end
    // If the data fifo is full and we receive data, set the overflow indicator.
    if (data_fifo_space_remaining == '0 && i_tvalid && !of_packet_corrupted) begin
      fc_overflow_stb <= 1'b1;
      of_packet_corrupted <= 1'b1;
    end

    if (rst) begin
      current_monitor_state <= IDLE;
      fc_overflow_stb <= '0;
      nfc_idle_timeout <= '0;
      m_axi_nfc_tvalid <= '0;
      m_axi_nfc_tdata <= 'X;
      of_packet_corrupted <= '0;
    end
  end


endmodule


`default_nettype wire
