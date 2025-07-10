//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: aurora_tx_control
//
// Description:
//
// This module implements the control logic for a single Aurora transmit
// channel. It monitors the status of the Aurora transmit channel and
// controls the transmission of data coming in from the the Aurora link.
// Depending on the configuration of the channel, it may also set some of
// the CHDR header fields of the CHDR packets passing through:
//
//  - EOB bit   : If the stop trigger is received while there is an active burst
//                transmission in progress, the EOB bit is set for the next
//                full packet of the burst, to close out the current streaming
//                session and indicate the end of the burst.
//  - Timestamp : If the packet type is CHDR_PKT_TYPE_DATA_TS, and there is a
//                timestamp available in the timestamp queue, the timestamp is
//                written to the CHDR header of the first packet of the burst.
//                Subsequent packets of this burst will have the timestamp
//                incremented based on this initial timestamp.
//
// The module has a built in post FIFO buffer of SIZE 1.
//
// Parameters:
//
//  - CHDR_W          : Width of the CHDR data field
//  - PRE_FIFO_DEPTH  : Depth of the pre-FIFO buffer. Set to -1 for no FIFO.
//  - TS_QUEUE_DEPTH  : Depth of the timestamp queue in Log2. Set to -1
//                      for no queue. In this case, the timestamp must either be
//                      already set in the CHDR header coming in from the Aurora
//                      link in case timed streaming is needed.
//

`default_nettype none

module aurora_tx_control
  import ctrlport_pkg::*;
#(
  parameter int CHDR_W         = 64,
  parameter int PRE_FIFO_DEPTH = 1,
  parameter int TS_QUEUE_DEPTH = 5
) (
  // Clocks and resets
  input  wire logic                       rfnoc_chdr_clk,
  input  wire logic                       rfnoc_chdr_rst,
  // CHDR Input Port
  input  wire logic [         CHDR_W-1:0] s_axis_chdr_tdata,
  input  wire logic                       s_axis_chdr_tlast,
  input  wire logic                       s_axis_chdr_tvalid,
  output wire logic                       s_axis_chdr_tready,
  // CHDR Output Port
  output wire logic [         CHDR_W-1:0] m_axis_chdr_tdata,
  output wire logic                       m_axis_chdr_tlast,
  output wire logic                       m_axis_chdr_tvalid,
  input  wire logic                       m_axis_chdr_tready,
  // CtrlPort Master
  input  wire logic                       ctrlport_req_wr,
  input  wire logic                       ctrlport_req_rd,
  input  wire logic [CTRLPORT_ADDR_W-1:0] ctrlport_req_addr,
  input  wire logic [CTRLPORT_DATA_W-1:0] ctrlport_req_data,
  output logic                            ctrlport_resp_ack,
  output logic      [CTRLPORT_DATA_W-1:0] ctrlport_resp_data
);

  //--------------------------------------------------------------------------
  // Includes/Imports
  //--------------------------------------------------------------------------

  import rfnoc_chdr_utils_pkg::*;
  import aurora_regs_pkg::*;


  //--------------------------------------------------------------------------
  // Local Parameters
  //--------------------------------------------------------------------------
  localparam int ITEM_SIZE = 32;
  localparam int ITEM_SIZE_BYTE = ITEM_SIZE / 8;
  localparam int ITEM_SIZE_BYTE_LOG2 = $clog2(ITEM_SIZE_BYTE);
  localparam int CHDR_EOB_POS = 57;
  localparam int CHDR_W_BYTE = CHDR_W / 8;
  localparam int CHDR_W_BYTE_LOG2 = $clog2(CHDR_W_BYTE);
  localparam int CHDR_HEADER_W_BYTE = CHDR_W / 8;
  localparam int CHDR_TIMESTAMP_W_BYTE = CHDR_TIMESTAMP_W / 8;
  localparam int FSM_DELAY = 4;

  if (TS_QUEUE_DEPTH >= REG_TS_SIZE_LEN) begin : check_ts_fifo_depth
    $error("TS_QUEUE_DEPTH must be less than REG_TS_SIZE_LEN");
  end


  //--------------------------------------------------------------------------
  // Registers
  //--------------------------------------------------------------------------

  // User registers
  logic [      REG_CHAN_TX_CTRL_LEN-1:0] reg_chan_tx_ctrl;
  logic [       REG_CHAN_TS_LOW_LEN-1:0] reg_chan_ts_low;
  logic [      REG_CHAN_TS_HIGH_LEN-1:0] reg_chan_ts_high;
  logic [  REG_CHAN_STOP_POLICY_LEN-1:0] reg_chan_stop_policy;
  logic [ REG_CHAN_TS_QUEUE_STS_LEN-1:0] reg_chan_ts_queue_sts;
  logic [           REG_TS_SIZE_LEN-1:0] reg_ts_queue_size;
  logic [       REG_TS_FULLNESS_LEN-1:0] reg_ts_queue_fullness;
  logic [REG_CHAN_TS_QUEUE_CTRL_LEN-1:0] reg_chan_ts_queue_ctrl;

  // Internal register variables
  logic                                  reg_tx_start_trig;
  logic                                  reg_tx_stop_trig;
  logic                                  reg_ts_queue_clr;

  // Helper signals
  logic                                  ts_valid;

  assign reg_tx_start_trig = reg_chan_tx_ctrl[REG_CHAN_TX_START_POS];
  assign reg_tx_stop_trig = reg_chan_tx_ctrl[REG_CHAN_TX_STOP_POS];
  assign reg_chan_ts_queue_sts = {reg_ts_queue_size, reg_ts_queue_fullness};
  assign reg_ts_queue_size = 1 << TS_QUEUE_DEPTH;
  assign reg_ts_queue_clr = reg_chan_ts_queue_ctrl[REG_TS_QUEUE_CTRL_CLR_POS];


  always_ff @(posedge rfnoc_chdr_clk) begin
    // Default assignments
    ctrlport_resp_ack  <= 1'b0;
    ctrlport_resp_data <= 'hBAD_C0DE;

    // Always clear these regs after being set
    reg_chan_tx_ctrl       <= '0;
    reg_chan_ts_queue_ctrl <= '0;
    ts_valid               <= 1'b0;

    // Read user registers
    if (ctrlport_req_rd) begin  // Read request
      ctrlport_resp_ack <= 1;  // Always immediately ack
      case (ctrlport_req_addr)
        REG_CHAN_STOP_POLICY_ADDR: begin
          ctrlport_resp_data <= CTRLPORT_DATA_W'(reg_chan_stop_policy);
        end
        REG_CHAN_TS_QUEUE_STS_ADDR: begin
          ctrlport_resp_data <= CTRLPORT_DATA_W'(reg_chan_ts_queue_sts);
        end
      endcase
    end

    // Write user registers
    if (ctrlport_req_wr) begin  // Write request
      ctrlport_resp_ack <= 1;  // Always immediately ack
      unique case (ctrlport_req_addr)
        REG_CHAN_TX_CTRL_ADDR: begin
          reg_chan_tx_ctrl <= ctrlport_req_data[REG_CHAN_TX_CTRL_LEN-1:0];
        end
        REG_CHAN_TS_LOW_ADDR: begin
          reg_chan_ts_low <= ctrlport_req_data[REG_CHAN_TS_LOW_LEN-1:0];
        end
        REG_CHAN_TS_HIGH_ADDR: begin
          reg_chan_ts_high <= ctrlport_req_data[REG_CHAN_TS_HIGH_LEN-1:0];
          ts_valid         <= 1;
        end
        REG_CHAN_STOP_POLICY_ADDR: begin
          reg_chan_stop_policy <=
            ctrlport_req_data[REG_CHAN_STOP_POLICY_LEN-1:0];
        end
        REG_CHAN_TS_QUEUE_CTRL_ADDR: begin
          reg_chan_ts_queue_ctrl <=
            ctrlport_req_data[REG_CHAN_TS_QUEUE_CTRL_LEN-1:0];
        end
      endcase
    end

    if (rfnoc_chdr_rst) begin
      ctrlport_resp_ack    <= 1'b0;
      ctrlport_resp_data   <= 'X;
      reg_chan_tx_ctrl     <= '0;
      reg_chan_ts_low      <= 'X;
      reg_chan_ts_high     <= 'X;
      reg_chan_stop_policy <= 1'b0;
    end
  end


  //--------------------------------------------------------------------------
  // CHDR Input buffer
  //--------------------------------------------------------------------------

  logic [CHDR_W-1:0] out_pre_fifo_tdata;
  logic              out_pre_fifo_tlast;
  logic              out_pre_fifo_tvalid;
  logic              out_pre_fifo_tready;

  axi_fifo #(
    .WIDTH(1 + CHDR_W),
    .SIZE (PRE_FIFO_DEPTH)
  ) axi_fifo_pre_buffer (
    .clk(rfnoc_chdr_clk),
    .reset(rfnoc_chdr_rst),
    .clear(1'b0),
    .i_tdata({s_axis_chdr_tlast, s_axis_chdr_tdata}),
    .i_tvalid(s_axis_chdr_tvalid),
    .i_tready(s_axis_chdr_tready),
    .o_tdata({out_pre_fifo_tlast, out_pre_fifo_tdata}),
    .o_tvalid(out_pre_fifo_tvalid),
    .o_tready(out_pre_fifo_tready),
    .space(),
    .occupied()
  );


  //--------------------------------------------------------------------------
  // Timestamp Queue
  //--------------------------------------------------------------------------

  logic [CHDR_TIMESTAMP_W-1:0] out_ts_queue_tdata;
  logic                        out_ts_queue_tvalid;
  logic                        out_ts_queue_tready;

  axi_fifo #(
    .WIDTH(CHDR_TIMESTAMP_W),
    .SIZE (TS_QUEUE_DEPTH)
  ) axi_fifo_timestamp_queue (
    .clk(rfnoc_chdr_clk),
    .reset(rfnoc_chdr_rst),
    .clear(reg_ts_queue_clr),
    .i_tdata({reg_chan_ts_high, reg_chan_ts_low}),
    .i_tvalid(ts_valid),
    .i_tready(),
    .o_tdata(out_ts_queue_tdata),
    .o_tvalid(out_ts_queue_tvalid),
    .o_tready(out_ts_queue_tready),
    .space(),
    .occupied(reg_ts_queue_fullness)
  );


  //--------------------------------------------------------------------------
  // Channel Control State Machine
  //--------------------------------------------------------------------------

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_DROPPING,
    ST_SOB_HEADER,
    ST_PKT_HEADER,
    ST_CHDR_W_64_TS,
    ST_CHDR_W_64_EOB_TS,
    ST_TRNSMT,
    ST_TRNSMT_EOB
  } state_t;

  state_t state = ST_IDLE, next_state;

  // CHDR FSM inputs
  logic [          CHDR_W-1:0] out_fsm_tdata;
  logic                        out_fsm_tlast;
  logic                        out_fsm_tvalid;
  logic                        out_fsm_tready;

  // FSM signals
  logic [   CHDR_LENGTH_W-1:0] curr_payload_len;
  logic                        stop_req_received;
  logic                        start_req_received;
  logic [CHDR_TIMESTAMP_W-1:0] timestamp = '0;
  logic [CHDR_TIMESTAMP_W-1:0] next_timestamp = '0;
  logic                        ts_in_packet;
  logic                        ts_popped;
  logic [                15:0] post_fifo_space;
  logic                        post_fifo_ready;
  logic                        post_fifo_valid;
  logic [ CHDR_PKT_TYPE_W-1:0] curr_pkt_type;
  logic                        is_eob;


  always_ff @(posedge rfnoc_chdr_clk) begin : advance_state_logic
    if (rfnoc_chdr_rst) begin
      state <= ST_IDLE;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin : state_transition_logic
    next_state = state;

    curr_pkt_type = chdr_get_pkt_type(out_pre_fifo_tdata[CHDR_HEADER_W-1:0]);
    is_eob = chdr_get_eob(out_pre_fifo_tdata[CHDR_HEADER_W-1:0]);

    case (state)

      // Idle state - wait for start trigger
      ST_IDLE: begin
        if (start_req_received) begin
          next_state = ST_SOB_HEADER;
        end else if (out_pre_fifo_tvalid &&
                     out_pre_fifo_tready &&
                     !reg_chan_stop_policy) begin
          next_state = ST_DROPPING;
        end
      end

      // Dropping state - drop packets until the end of the packet.
      ST_DROPPING: begin
        // If we start dropping a packet, continue to drop until the end of
        // the packet. This is to ensure that we do not have partial packets
        // in the pipeline.
        if (out_pre_fifo_tlast &&
            out_pre_fifo_tvalid &&
            out_pre_fifo_tready) begin
          next_state = ST_IDLE;
        end
      end

      // Start of Burst - wait for header.
      ST_SOB_HEADER: begin
        // Forward header
        // First transmission of packet, assumed to contain header.
        if (out_pre_fifo_tvalid && out_pre_fifo_tready) begin
          if (CHDR_W == 64 && curr_pkt_type == CHDR_PKT_TYPE_DATA_TS) begin
            if (is_eob || stop_req_received) begin
              next_state = ST_CHDR_W_64_EOB_TS;
            end else begin
              next_state = ST_CHDR_W_64_TS;
            end
            // If the packet is the last in the burst, set the EOB bit
          end else if (is_eob || stop_req_received) begin
            next_state = ST_TRNSMT_EOB;
          end else begin
            next_state = ST_TRNSMT;
          end
          // If the stop trigger was received before starting the burst, go
          // back to idle state.
        end else if (stop_req_received) begin
          next_state = ST_IDLE;
        end
      end

      // Wait for pkt header
      ST_PKT_HEADER: begin
        // Forward header
        // First transmission of packet, assumed to contain header.
        if (out_pre_fifo_tvalid && out_pre_fifo_tready) begin
          if (CHDR_W == 64 && curr_pkt_type == CHDR_PKT_TYPE_DATA_TS) begin
            if (is_eob || stop_req_received) begin
              next_state = ST_CHDR_W_64_EOB_TS;
            end else begin
              next_state = ST_CHDR_W_64_TS;
            end
          end else begin
            // If the packet is the last in the burst, set the EOB bit.
            if (is_eob || stop_req_received) begin
              next_state = ST_TRNSMT_EOB;
            end else begin
              next_state = ST_TRNSMT;
            end
          end

        end
      end

      // For CHDR_W == 64 and packet type == CHDR_PKT_TYPE_DATA_TS add the timestamp in the
      // next data word after the header.
      ST_CHDR_W_64_TS: begin
        if (out_pre_fifo_tvalid && out_pre_fifo_tready) begin
          next_state = ST_TRNSMT;
        end
      end

      // For CHDR_W == 64 and packet type == CHDR_PKT_TYPE_DATA_TS add the timestamp in the
      // next data word after the header.
      ST_CHDR_W_64_EOB_TS: begin
        if (out_pre_fifo_tvalid && out_pre_fifo_tready) begin
          next_state = ST_TRNSMT_EOB;
        end
      end

      // Transmit state - forward packet data
      ST_TRNSMT: begin
        if (out_pre_fifo_tlast &&
            out_pre_fifo_tvalid &&
            out_pre_fifo_tready) begin
          next_state = ST_PKT_HEADER;
        end

      end

      // End of packet state - transmit last packet
      ST_TRNSMT_EOB: begin
        if (out_pre_fifo_tlast &&
            out_pre_fifo_tvalid &&
            out_pre_fifo_tready) begin
          // If host has indicated that the streaming session is over, go back
          // to idle state. Otherwise, go back to start of packet state and
          // wait for the start of the next burst.
          if (stop_req_received) begin
            next_state = ST_IDLE;
          end else begin
            next_state = ST_SOB_HEADER;
          end
        end
      end

      default: begin
        next_state = ST_IDLE;
      end
    endcase
  end

  always_ff @(posedge rfnoc_chdr_clk) begin : output_fsm_logic
    // Default assignments
    out_fsm_tdata       <= out_pre_fifo_tdata;
    out_fsm_tlast       <= out_pre_fifo_tlast;
    out_fsm_tvalid      <= out_pre_fifo_tvalid & post_fifo_valid;
    out_pre_fifo_tready <= post_fifo_ready;

    // Reset ready signal for TS queue to ensure only one TS is popped at a
    // time.
    out_ts_queue_tready <= 1'b0;
    ts_popped           <= 1'b0;

    // Output buffer space, check if there is enough space in the post FIFO to
    // accept the next FSM_DELAY data words.
    post_fifo_ready     <= post_fifo_space >= FSM_DELAY;
    post_fifo_valid     <= post_fifo_ready;

    // Retain stop trigger
    if (reg_tx_stop_trig) begin
      stop_req_received <= 1'b1;
    end
    // Retain start trigger
    if (reg_tx_start_trig) begin
      start_req_received <= 1'b1;
    end

    unique case (state)
      ST_IDLE: begin
        stop_req_received <= 1'b0;
        // According to stop policy, either buffer or drop packets
        if (reg_chan_stop_policy == TX_POLICY_BUFFER) begin
          out_pre_fifo_tready <= 1'b0;
          out_fsm_tvalid      <= 1'b0;
        end else if (reg_chan_stop_policy == TX_POLICY_DROP) begin
          out_fsm_tvalid      <= 1'b0;
          out_pre_fifo_tready <= 1'b1;
        end
      end

      ST_DROPPING: begin
        out_fsm_tvalid      <= 1'b0;
        out_pre_fifo_tready <= 1'b1;
      end

      ST_SOB_HEADER: begin
        start_req_received <= 1'b0;
        ts_in_packet       <= 1'b1;  // Use TS in packet by default
        ts_popped          <= ts_popped;
        // If data was buffered during idle state, delay first tvalid.
        if (start_req_received) begin
          out_fsm_tvalid <= out_fsm_tvalid & out_pre_fifo_tvalid;
        end
        // Retain relevant header information for processing.
        curr_payload_len <= chdr_calc_payload_length(
          CHDR_W, out_pre_fifo_tdata[CHDR_HEADER_W-1:0]
        );

        if (curr_pkt_type == CHDR_PKT_TYPE_DATA_TS) begin
          // Retrieve timestamp from the timestamp queue if available.
          // Do only once when entering this state.
          if (out_ts_queue_tvalid || ts_popped) begin
            ts_in_packet <= 1'b0;  // Do not use TS in packet
            if (!ts_popped) begin
              // Set the timestamp to the TS queue value.
              timestamp           <= out_ts_queue_tdata;
              out_ts_queue_tready <= 1'b1;
              ts_popped           <= 1'b1;
            end
            // For CHDR_W other than 64, add timestamp to the first word of the
            // packet, directly following the header.
            if (CHDR_W >= 128) begin
              if (ts_popped) begin
                out_fsm_tdata[CHDR_HEADER_W+:CHDR_TIMESTAMP_W] <= timestamp;
              end else begin
                // If the timestamp is not popped, set the timestamp to the
                // TS queue value.
                out_fsm_tdata[CHDR_HEADER_W+:CHDR_TIMESTAMP_W] <=
                  out_ts_queue_tdata;
              end
            end
          end
        end

        // If the stop trigger was received during the transmission of the
        // previous packet, set the EOB bit for the next and last packet of the
        // burst.
        if (stop_req_received) begin
          out_fsm_tdata[CHDR_EOB_POS] <= 1'b1;
        end
      end

      ST_PKT_HEADER: begin
        // Retain relevant header information for processing.
        curr_payload_len <= chdr_calc_payload_length(
          CHDR_W, out_pre_fifo_tdata[CHDR_HEADER_W-1:0]
        );
        if (curr_pkt_type == CHDR_PKT_TYPE_DATA_TS) begin
          if (!ts_in_packet) begin
            if (CHDR_W >= 128) begin
              out_fsm_tdata[CHDR_HEADER_W+:CHDR_TIMESTAMP_W] <= next_timestamp;
            end
            // Increment timestamp by the number of samples in the packet.
            timestamp <= next_timestamp;
          end
        end
        // If the stop trigger was received during the transmission of the
        // previous packet, set the EOB bit for the next and last packet of the
        // burst.
        if (stop_req_received) begin
          out_fsm_tdata[CHDR_EOB_POS] <= 1'b1;
        end
      end

      ST_CHDR_W_64_TS, ST_CHDR_W_64_EOB_TS: begin
        if (!ts_in_packet) begin
          // For CHDR_W == 64 and packet type == CHDR_PKT_TYPE_DATA_TS add the
          // timestamp in the next data word after the header.
          out_fsm_tdata <= timestamp;
        end
      end

      ST_TRNSMT: begin
        // Calculate the timestamp for the next packet. Requires packet payload
        // length to be >0.
        next_timestamp <= timestamp +
          ((curr_payload_len) >> ITEM_SIZE_BYTE_LOG2);
      end
      ST_TRNSMT_EOB: begin
        ts_in_packet <= 1'b0;
      end
    endcase
    if (rfnoc_chdr_rst) begin
      timestamp <= '0;
      next_timestamp <= '0;
      stop_req_received <= 1'b0;
      start_req_received <= 1'b0;
      ts_in_packet <= 1'b0;
      ts_popped <= 1'b0;
    end

  end


  //---------------------------------------------------------------------------
  // CHDR Output buffer
  //---------------------------------------------------------------------------

  axi_fifo #(
    .WIDTH(1 + CHDR_W),
    .SIZE (2)
  ) axi_fifo_out_buffer (
    .clk(rfnoc_chdr_clk),
    .reset(rfnoc_chdr_rst),
    .clear(1'b0),
    .i_tdata({out_fsm_tlast, out_fsm_tdata}),
    .i_tvalid(out_fsm_tvalid),
    .i_tready(out_fsm_tready),
    .o_tdata({m_axis_chdr_tlast, m_axis_chdr_tdata}),
    .o_tvalid(m_axis_chdr_tvalid),
    .o_tready(m_axis_chdr_tready),
    .space(post_fifo_space),
    .occupied()
  );


endmodule : aurora_tx_control


`default_nettype wire
