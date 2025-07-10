//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: rfnoc_block_aurora
//
// Description:
//
//   RFNoC block for Aurora communication with non-RFNoC devices.
//
// Parameters:
//
//   THIS_PORTID         : Control crossbar port to which this block is
//                         connected.
//   CHDR_W              : AXIS-CHDR data bus width.
//   MTU                 : Log2 of maximum transmission unit.
//   NUM_PORTS           : Number of RFNoC channels.
//   QSFP_NUM            : Which QSFP port will be used for this Aurora block.
//   EN_TX_CONTROL       : Include the TX control logic when 1. Bypass it when
//                         0.
//   TS_QUEUE_DEPTH_LOG2 : Log base two of the size of the timestamp queue.
//   SIMULATION          : Set to 0 for synthesis. Set to 1 for simulation to
//                         enable faster simulation of Aurora IP.
//

`default_nettype none


module rfnoc_block_aurora #(
  logic [9:0] THIS_PORTID         = 10'd0,
  int         CHDR_W              = 64,
  logic [5:0] MTU                 = 6'd10,
  int         NUM_PORTS           = 1,
  int         QSFP_NUM            = 0,
  bit         EN_TX_CONTROL       = 1,
  int         TS_QUEUE_DEPTH_LOG2 = 5,
  bit         SIMULATION          = 0
) (
  // RFNoC Framework Clocks and Resets
  input  wire rfnoc_chdr_clk,
  input  wire rfnoc_ctrl_clk,

  // RFNoC Backend Interface
  input  wire [511:0] rfnoc_core_config,
  output wire [511:0] rfnoc_core_status,

  //-----------------------------------
  // QSFP Interface
  //-----------------------------------

  // QSFP Clocks
  input  wire  refclk_p,
  input  wire  refclk_n,
  input  wire  dclk,

  // MGT Pins
  output logic [3:0] tx_p,
  output logic [3:0] tx_n,
  input  wire  [3:0] rx_p,
  input  wire  [3:0] rx_n,

  // Transport Adapter Status
  output logic         recovered_clk,
  input  wire  [ 15:0] device_id,
  output logic [  3:0] rx_irq,
  output logic [  3:0] tx_irq,
  output logic [127:0] port_info,  // rfnoc_ctrl_clk
  output logic [  3:0] link_up,    // Asynchronous
  output logic [  3:0] activity,   // Asynchronous

  // AXI-Lite Register Interface
  input  wire         axil_rst,
  input  wire         axil_clk,
  input  wire  [39:0] axil_awaddr,
  input  wire         axil_awvalid,
  output logic        axil_awready,
  input  wire  [31:0] axil_wdata,
  input  wire  [ 3:0] axil_wstrb,
  input  wire         axil_wvalid,
  output logic        axil_wready,
  output logic [ 1:0] axil_bresp,
  output logic        axil_bvalid,
  input  wire         axil_bready,
  input  wire  [39:0] axil_araddr,
  input  wire         axil_arvalid,
  output logic        axil_arready,
  output logic [31:0] axil_rdata,
  output logic [ 1:0] axil_rresp,
  output logic        axil_rvalid,
  input  wire         axil_rready,

  // Ethernet DMA AXI to CPU memory
  input  wire          axi_rst,
  input  wire          axi_clk,
  output logic [ 48:0] axi_araddr,
  output logic [  1:0] axi_arburst,
  output logic [  3:0] axi_arcache,
  output logic [  7:0] axi_arlen,
  output logic [  0:0] axi_arlock,
  output logic [  2:0] axi_arprot,
  output logic [  3:0] axi_arqos,
  input  wire          axi_arready,
  output logic [  2:0] axi_arsize,
  output logic         axi_arvalid,
  output logic [ 48:0] axi_awaddr,
  output logic [  1:0] axi_awburst,
  output logic [  3:0] axi_awcache,
  output logic [  7:0] axi_awlen,
  output logic [  0:0] axi_awlock,
  output logic [  2:0] axi_awprot,
  output logic [  3:0] axi_awqos,
  input  wire          axi_awready,
  output logic [  2:0] axi_awsize,
  output logic         axi_awvalid,
  output logic         axi_bready,
  input  wire  [  1:0] axi_bresp,
  input  wire          axi_bvalid,
  input  wire  [127:0] axi_rdata,
  input  wire          axi_rlast,
  output logic         axi_rready,
  input  wire  [  1:0] axi_rresp,
  input  wire          axi_rvalid,
  output logic [127:0] axi_wdata,
  output logic         axi_wlast,
  input  wire          axi_wready,
  output logic [ 15:0] axi_wstrb,
  output logic         axi_wvalid,

  //-----------------------------------
  // RFNoC Data Interface
  //-----------------------------------

  // AXIS-CHDR Input Ports (from framework)
  input  wire [CHDR_W*NUM_PORTS-1:0] s_rfnoc_chdr_tdata,
  input  wire [       NUM_PORTS-1:0] s_rfnoc_chdr_tlast,
  input  wire [       NUM_PORTS-1:0] s_rfnoc_chdr_tvalid,
  output wire [       NUM_PORTS-1:0] s_rfnoc_chdr_tready,

  // AXIS-CHDR Output Ports (to framework)
  output wire [CHDR_W*NUM_PORTS-1:0] m_rfnoc_chdr_tdata,
  output wire [       NUM_PORTS-1:0] m_rfnoc_chdr_tlast,
  output wire [       NUM_PORTS-1:0] m_rfnoc_chdr_tvalid,
  input  wire [       NUM_PORTS-1:0] m_rfnoc_chdr_tready,

  //-----------------------------------
  // RFNoC Control Interface
  //-----------------------------------

  // AXIS-Ctrl Input Port (from framework)
  input  wire [31:0] s_rfnoc_ctrl_tdata,
  input  wire        s_rfnoc_ctrl_tlast,
  input  wire        s_rfnoc_ctrl_tvalid,
  output wire        s_rfnoc_ctrl_tready,

  // AXIS-Ctrl Output Port (to framework)
  output wire [31:0] m_rfnoc_ctrl_tdata,
  output wire        m_rfnoc_ctrl_tlast,
  output wire        m_rfnoc_ctrl_tvalid,
  input  wire        m_rfnoc_ctrl_tready
);

  `include `"`UHD_FPGA_DIR/usrp3/lib/control/usrp_utils.svh`"
  `include `"`UHD_FPGA_DIR/usrp3/lib/rfnoc/transport_adapters/rfnoc_ta_x4xx_eth/x4xx_mgt_types.vh`"

  import ctrlport_pkg::*;
  import rfnoc_chdr_utils_pkg::*;

  import aurora_regs_pkg::*;

  // This is the number of MGT lanes used by the Aurora IP.
  localparam int NUM_LANES = 4;


  //---------------------------------------------------------------------------
  // Signal Declarations
  //---------------------------------------------------------------------------

  logic                       ctrlport_req_wr;
  logic                       ctrlport_req_rd;
  logic [CTRLPORT_ADDR_W-1:0] ctrlport_req_addr;
  logic [CTRLPORT_DATA_W-1:0] ctrlport_req_data;
  logic                       ctrlport_resp_ack;
  logic [CTRLPORT_DATA_W-1:0] ctrlport_resp_data;

  logic [NUM_PORTS-1:0][CHDR_W-1:0] in_noc_shell_tdata;
  logic [NUM_PORTS-1:0][       0:0] in_noc_shell_tlast;
  logic [NUM_PORTS-1:0][       0:0] in_noc_shell_tvalid;
  logic [NUM_PORTS-1:0][       0:0] in_noc_shell_tready;

  logic [NUM_PORTS-1:0][CHDR_W-1:0] out_noc_shell_tdata;
  logic [NUM_PORTS-1:0][       0:0] out_noc_shell_tlast;
  logic [NUM_PORTS-1:0][       0:0] out_noc_shell_tvalid;
  logic [NUM_PORTS-1:0][       0:0] out_noc_shell_tready;


  //---------------------------------------------------------------------------
  // NoC Shell
  //---------------------------------------------------------------------------

  logic rfnoc_chdr_rst;

  noc_shell_aurora #(
    .CHDR_W     (CHDR_W     ),
    .THIS_PORTID(THIS_PORTID),
    .MTU        (MTU        ),
    .NUM_PORTS  (NUM_PORTS  )
  ) noc_shell_aurora_i (
    //---------------------
    // Framework Interface
    //---------------------
    // Clock Inputs
    .rfnoc_chdr_clk      (rfnoc_chdr_clk      ),
    .rfnoc_ctrl_clk      (rfnoc_ctrl_clk      ),
    // Reset Outputs
    .rfnoc_chdr_rst      (rfnoc_chdr_rst      ),
    .rfnoc_ctrl_rst      (                    ),
    // RFNoC Backend Interface
    .rfnoc_core_config   (rfnoc_core_config   ),
    .rfnoc_core_status   (rfnoc_core_status   ),
    // CHDR Input Ports  (from framework)
    .s_rfnoc_chdr_tdata  (s_rfnoc_chdr_tdata  ),
    .s_rfnoc_chdr_tlast  (s_rfnoc_chdr_tlast  ),
    .s_rfnoc_chdr_tvalid (s_rfnoc_chdr_tvalid ),
    .s_rfnoc_chdr_tready (s_rfnoc_chdr_tready ),
    // CHDR Output Ports (to framework)
    .m_rfnoc_chdr_tdata  (m_rfnoc_chdr_tdata  ),
    .m_rfnoc_chdr_tlast  (m_rfnoc_chdr_tlast  ),
    .m_rfnoc_chdr_tvalid (m_rfnoc_chdr_tvalid ),
    .m_rfnoc_chdr_tready (m_rfnoc_chdr_tready ),
    // AXIS-Ctrl Input Port (from framework)
    .s_rfnoc_ctrl_tdata  (s_rfnoc_ctrl_tdata  ),
    .s_rfnoc_ctrl_tlast  (s_rfnoc_ctrl_tlast  ),
    .s_rfnoc_ctrl_tvalid (s_rfnoc_ctrl_tvalid ),
    .s_rfnoc_ctrl_tready (s_rfnoc_ctrl_tready ),
    // AXIS-Ctrl Output Port (to framework)
    .m_rfnoc_ctrl_tdata  (m_rfnoc_ctrl_tdata  ),
    .m_rfnoc_ctrl_tlast  (m_rfnoc_ctrl_tlast  ),
    .m_rfnoc_ctrl_tvalid (m_rfnoc_ctrl_tvalid ),
    .m_rfnoc_ctrl_tready (m_rfnoc_ctrl_tready ),
    //---------------------
    // Client Interface
    //---------------------
    // CtrlPort Clock and Reset
    .ctrlport_clk        (                    ),
    .ctrlport_rst        (                    ),
    // CtrlPort Master
    .m_ctrlport_req_wr   (ctrlport_req_wr     ),
    .m_ctrlport_req_rd   (ctrlport_req_rd     ),
    .m_ctrlport_req_addr (ctrlport_req_addr   ),
    .m_ctrlport_req_data (ctrlport_req_data   ),
    .m_ctrlport_resp_ack (ctrlport_resp_ack   ),
    .m_ctrlport_resp_data(ctrlport_resp_data  ),
    // AXI-Stream Clock and Reset
    .axis_chdr_clk       (                    ),
    .axis_chdr_rst       (                    ),
    // Data Stream to User Logic: in
    .m_in_chdr_tdata     (in_noc_shell_tdata  ),
    .m_in_chdr_tlast     (in_noc_shell_tlast  ),
    .m_in_chdr_tvalid    (in_noc_shell_tvalid ),
    .m_in_chdr_tready    (in_noc_shell_tready ),
    // Data Stream from User Logic: out
    .s_out_chdr_tdata    (out_noc_shell_tdata ),
    .s_out_chdr_tlast    (out_noc_shell_tlast ),
    .s_out_chdr_tvalid   (out_noc_shell_tvalid),
    .s_out_chdr_tready   (out_noc_shell_tready)
  );


  //---------------------------------------------------------------------------
  // CtrlPort Splitter
  //---------------------------------------------------------------------------

  logic                       core_ctrlport_req_wr;
  logic                       core_ctrlport_req_rd;
  logic [CTRLPORT_ADDR_W-1:0] core_ctrlport_req_addr;
  logic [CTRLPORT_DATA_W-1:0] core_ctrlport_req_data;
  logic                       core_ctrlport_resp_ack = 1'b0;
  logic [CTRLPORT_DATA_W-1:0] core_ctrlport_resp_data;

  logic [NUM_PORTS-1:0]                      chan_ctrlport_req_wr;
  logic [NUM_PORTS-1:0]                      chan_ctrlport_req_rd;
  logic [NUM_PORTS-1:0][CTRLPORT_ADDR_W-1:0] chan_ctrlport_req_addr;
  logic [NUM_PORTS-1:0][CTRLPORT_DATA_W-1:0] chan_ctrlport_req_data;
  logic [NUM_PORTS-1:0]                      chan_ctrlport_resp_ack;
  logic [NUM_PORTS-1:0][CTRLPORT_DATA_W-1:0] chan_ctrlport_resp_data;

  ctrlport_decoder #(
    .NUM_SLAVES  (NUM_PORTS + 1     ),
    .BASE_ADDR   (0                 ),
    .SLAVE_ADDR_W(AURORA_CHAN_ADDR_W)
  ) ctrlport_decoder_i (
    .ctrlport_clk           (rfnoc_chdr_clk                                    ),
    .ctrlport_rst           (rfnoc_chdr_rst                                    ),
    .s_ctrlport_req_wr      (ctrlport_req_wr                                   ),
    .s_ctrlport_req_rd      (ctrlport_req_rd                                   ),
    .s_ctrlport_req_addr    (ctrlport_req_addr                                 ),
    .s_ctrlport_req_data    (ctrlport_req_data                                 ),
    .s_ctrlport_req_byte_en ('1                                                ),
    .s_ctrlport_req_has_time('0                                                ),
    .s_ctrlport_req_time    ('0                                                ),
    .s_ctrlport_resp_ack    (ctrlport_resp_ack                                 ),
    .s_ctrlport_resp_status (                                                  ),
    .s_ctrlport_resp_data   (ctrlport_resp_data                                ),
    .m_ctrlport_req_wr      ({chan_ctrlport_req_wr,    core_ctrlport_req_wr   }),
    .m_ctrlport_req_rd      ({chan_ctrlport_req_rd,    core_ctrlport_req_rd   }),
    .m_ctrlport_req_addr    ({chan_ctrlport_req_addr,  core_ctrlport_req_addr }),
    .m_ctrlport_req_data    ({chan_ctrlport_req_data,  core_ctrlport_req_data }),
    .m_ctrlport_req_byte_en (                                                  ),
    .m_ctrlport_req_has_time(                                                  ),
    .m_ctrlport_req_time    (                                                  ),
    .m_ctrlport_resp_ack    ({chan_ctrlport_resp_ack,  core_ctrlport_resp_ack }),
    .m_ctrlport_resp_status ('0                                                ),
    .m_ctrlport_resp_data   ({chan_ctrlport_resp_data, core_ctrlport_resp_data})
  );


  //---------------------------------------------------------------------------
  // Configuration
  //---------------------------------------------------------------------------

  localparam int NUM_CORES = 1;
  localparam int AURORA_W  = 256;

  // Calculate the MTU in units of Aurora words
  localparam int AURORA_MTU = $clog2((2**MTU * (CHDR_W/8)) / (AURORA_W/8));

  localparam [  REG_PAUSE_COUNT_LEN-1:0] DEF_NFC_PAUSE_COUNT   = 100;
  localparam [ REG_PAUSE_THRESH_LEN-1:0] DEF_NFC_PAUSE_THRESH  = 160;
  localparam [REG_RESUME_THRESH_LEN-1:0] DEF_NFC_RESUME_THRESH = 200;


  //---------------------------------------------------------------------------
  // Core Registers
  //---------------------------------------------------------------------------

  localparam logic [CTRLPORT_DATA_W-1:0] COMPAT_NUM = {16'h0001, 16'h0000};

  // Use the full CtrlPort data width for the counters
  localparam int COUNTER_W = CTRLPORT_DATA_W;

  logic [NUM_LANES-1:0] r_aurora_lane_up;
  logic                 r_aurora_link_up;
  logic                 r_aurora_hard_err;
  logic                 r_aurora_soft_err;
  logic                 r_aurora_mmcm_lock;
  logic                 r_aurora_pll_lock;
  logic                 r_aurora_sw_rst = 1'b1;
  logic                 r_tx_datapath_rst = 1'b1;
  logic                 r_rx_datapath_rst = 1'b1;
  logic                 rfnoc_chdr_rst_prev = 1'b0;

  logic [REG_PAUSE_COUNT_LEN-1:0] r_nfc_pause_count;
  logic [REG_PAUSE_THRESH_LEN-1:0] r_nfc_pause_thresh;
  logic [REG_RESUME_THRESH_LEN-1:0] r_nfc_resume_thresh;

  logic [COUNTER_W-1:0] r_aurora_tx_pkt_ctr;
  logic [COUNTER_W-1:0] r_aurora_rx_pkt_ctr;
  logic [COUNTER_W-1:0] r_aurora_overflow_ctr;
  logic [COUNTER_W-1:0] r_aurora_crc_err_ctr;

  always_ff @(posedge rfnoc_chdr_clk) begin : aurora_core_regs
    core_ctrlport_resp_ack  <= 1'b0;
    core_ctrlport_resp_data <= 'hBAD_C0DE;
    rfnoc_chdr_rst_prev     <= rfnoc_chdr_rst;
    r_aurora_sw_rst         <= 1'b0;
    r_tx_datapath_rst       <= 1'b0;
    r_rx_datapath_rst       <= 1'b0;

    //-------------------------------------------------------------------------
    // Reads
    //-------------------------------------------------------------------------

    if (core_ctrlport_req_rd) begin : read_case
      core_ctrlport_resp_ack <= 1'b1;

      case (core_ctrlport_req_addr[AURORA_CHAN_ADDR_W-1:0])
        REG_COMPAT_ADDR : begin
          core_ctrlport_resp_data <= COMPAT_NUM;
        end
        REG_CORE_CONFIG_ADDR : begin
          core_ctrlport_resp_data <=
            (REG_NUM_CORES_LEN'(NUM_CORES) << REG_NUM_CORES_POS) |
            (REG_NUM_CHAN_LEN'(NUM_PORTS) << REG_NUM_CHAN_POS);
        end
        REG_CORE_STATUS_ADDR : begin
          core_ctrlport_resp_data <=
            (REG_LANE_STATUS_LEN'(r_aurora_lane_up) << REG_LANE_STATUS_POS) |
            (r_aurora_link_up << REG_LINK_STATUS_POS) |
            (r_aurora_hard_err << REG_HARD_ERR_POS) |
            (r_aurora_soft_err << REG_SOFT_ERR_POS) |
            (r_aurora_mmcm_lock << REG_MMCM_LOCK_POS) |
            (r_aurora_pll_lock << REG_PLL_LOCK_POS);
        end
        REG_CORE_FC_PAUSE_ADDR : begin
          core_ctrlport_resp_data <= CTRLPORT_DATA_W'(r_nfc_pause_count);
        end
        REG_CORE_FC_THRESHOLD_ADDR : begin
          core_ctrlport_resp_data <=
            (REG_PAUSE_THRESH_LEN'( r_nfc_pause_thresh) << REG_PAUSE_THRESH_POS) |
            (REG_RESUME_THRESH_LEN'(r_nfc_resume_thresh) << REG_RESUME_THRESH_POS);
        end
        REG_CORE_TX_PKT_CTR_ADDR: begin
          core_ctrlport_resp_data <= CTRLPORT_DATA_W'(r_aurora_tx_pkt_ctr);
        end
        REG_CORE_RX_PKT_CTR_ADDR: begin
          core_ctrlport_resp_data <= CTRLPORT_DATA_W'(r_aurora_rx_pkt_ctr);
        end
        REG_CORE_OVERFLOW_CTR_ADDR: begin
          core_ctrlport_resp_data <= CTRLPORT_DATA_W'(r_aurora_overflow_ctr);
        end
        REG_CORE_CRC_ERR_CTR_ADDR: begin
          core_ctrlport_resp_data <= CTRLPORT_DATA_W'(r_aurora_crc_err_ctr);
        end
      endcase
    end : read_case

    //-------------------------------------------------------------------------
    // Writes
    //-------------------------------------------------------------------------

    if (core_ctrlport_req_wr) begin : write_case
      core_ctrlport_resp_ack <= 1'b1;

      case (core_ctrlport_req_addr[AURORA_CHAN_ADDR_W-1:0])
        REG_CORE_RESET_ADDR : begin
          r_aurora_sw_rst   <= core_ctrlport_req_data[REG_AURORA_RESET_POS];
          r_tx_datapath_rst <= core_ctrlport_req_data[REG_TX_DATAPATH_RESET_POS];
          r_rx_datapath_rst <= core_ctrlport_req_data[REG_RX_DATAPATH_RESET_POS];
        end
        REG_CORE_FC_PAUSE_ADDR : begin
          r_nfc_pause_count <=
            core_ctrlport_req_data[REG_PAUSE_THRESH_POS+:REG_PAUSE_COUNT_LEN];
        end
        REG_CORE_FC_THRESHOLD_ADDR : begin
          r_nfc_pause_thresh <=
            core_ctrlport_req_data[REG_PAUSE_THRESH_POS+:REG_PAUSE_THRESH_LEN];
          r_nfc_resume_thresh <=
            core_ctrlport_req_data[REG_RESUME_THRESH_POS+:REG_RESUME_THRESH_LEN];
        end
      endcase
    end : write_case

    if (rfnoc_chdr_rst) begin
      core_ctrlport_resp_ack  <= 1'b0;
      core_ctrlport_resp_data <= 'X;
      r_aurora_sw_rst         <= 1'b1;
      r_tx_datapath_rst       <= 1'b1;
      r_rx_datapath_rst       <= 1'b1;
      r_nfc_pause_count       <= DEF_NFC_PAUSE_COUNT;
      r_nfc_pause_thresh      <= DEF_NFC_PAUSE_THRESH;
      r_nfc_resume_thresh     <= DEF_NFC_RESUME_THRESH;
      rfnoc_chdr_rst_prev     <= 1'b1;
    end
  end : aurora_core_regs


  //---------------------------------------------------------------------------
  // Aurora Clock Domain Reset
  //---------------------------------------------------------------------------
  //
  // Keep the Aurora clock domain in reset until the clock is locked.
  //
  //---------------------------------------------------------------------------

  logic aurora_clk;
  logic aurora_rst = 1'b1;

  logic a_aurora_mmcm_lock;

  always_ff @(posedge aurora_clk) begin
    aurora_rst <= ~a_aurora_mmcm_lock;
  end


  //---------------------------------------------------------------------------
  // Aurora TX Datapath (Aurora -> RFNoC)
  //---------------------------------------------------------------------------

  logic [AURORA_W-1:0] a_to_aurora_tdata;
  logic                a_to_aurora_tlast;
  logic                a_to_aurora_tvalid;
  logic                a_to_aurora_tready;

  logic [AURORA_W-1:0] a_from_aurora_tdata;
  logic                a_from_aurora_tlast;
  logic                a_from_aurora_tvalid;

  logic [AURORA_W-1:0] a_from_fc_tdata;
  logic                a_from_fc_tvalid;
  logic                a_from_fc_tlast;
  logic                a_from_fc_tready;

  aurora_tx_datapath #(
    .CHDR_W        (CHDR_W             ),
    .NUM_PORTS     (NUM_PORTS          ),
    .MTU           (MTU                ),
    .AURORA_W      (AURORA_W           ),
    .EN_TX_CONTROL (EN_TX_CONTROL      ),
    .TS_QUEUE_DEPTH(TS_QUEUE_DEPTH_LOG2),
    .CHANNEL_OFFSET(0                  ),
    .BUFFER_SIZE   (MTU                )
  ) aurora_tx_datapath_i (
    .aurora_clk        (aurora_clk             ),
    .aurora_rst        (aurora_rst             ),
    .s_aurora_tdata    (a_from_fc_tdata        ),
    .s_aurora_tvalid   (a_from_fc_tvalid       ),
    .s_aurora_tlast    (a_from_fc_tlast        ),
    .s_aurora_tready   (a_from_fc_tready       ),
    .rfnoc_chdr_clk    (rfnoc_chdr_clk         ),
    .rfnoc_chdr_rst    (r_tx_datapath_rst      ),
    .m_rfnoc_tdata     (out_noc_shell_tdata    ),
    .m_rfnoc_tvalid    (out_noc_shell_tvalid   ),
    .m_rfnoc_tlast     (out_noc_shell_tlast    ),
    .m_rfnoc_tready    (out_noc_shell_tready   ),
    .ctrlport_req_wr   (chan_ctrlport_req_wr   ),
    .ctrlport_req_rd   (chan_ctrlport_req_rd   ),
    .ctrlport_req_addr (chan_ctrlport_req_addr ),
    .ctrlport_req_data (chan_ctrlport_req_data ),
    .ctrlport_resp_ack (chan_ctrlport_resp_ack ),
    .ctrlport_resp_data(chan_ctrlport_resp_data)
  );


  //---------------------------------------------------------------------------
  // Aurora RX Datapath (RFNoC -> Aurora)
  //---------------------------------------------------------------------------

  aurora_rx_datapath #(
    .CHDR_W        (CHDR_W   ),
    .NUM_PORTS     (NUM_PORTS),
    .MTU           (MTU      ),
    .AXIS_AURORA_W (AURORA_W ),
    .CHANNEL_OFFSET(0        )
  ) aurora_rx_datapath_i (
    .rfnoc_chdr_clk      (rfnoc_chdr_clk     ),
    .rfnoc_chdr_rst      (r_rx_datapath_rst  ),
    .aurora_clk          (aurora_clk         ),
    .aurora_rst          (aurora_rst         ),
    .m_axis_aurora_tdata (a_to_aurora_tdata  ),
    .m_axis_aurora_tvalid(a_to_aurora_tvalid ),
    .m_axis_aurora_tlast (a_to_aurora_tlast  ),
    .m_axis_aurora_tready(a_to_aurora_tready ),
    .s_axis_rfnoc_tdata  (in_noc_shell_tdata ),
    .s_axis_rfnoc_tvalid (in_noc_shell_tvalid),
    .s_axis_rfnoc_tlast  (in_noc_shell_tlast ),
    .s_axis_rfnoc_tready (in_noc_shell_tready)
  );


  //---------------------------------------------------------------------------
  // CRC Override
  //---------------------------------------------------------------------------
  //
  // The CRC in the Xilinx IP does not work correctly in simulation, so we only
  // use it during synthesis. In simulation, we use the "a_sim_crc_pass"
  // signal, which can be changed in simulation to induce CRC errors.
  //
  //---------------------------------------------------------------------------

  logic a_from_aurora_crc_pass;
  logic a_from_aurora_crc_valid;

  logic a_crc_pass;
  logic a_sim_crc_pass = 1;

  assign a_crc_pass = SIMULATION ? a_sim_crc_pass : a_from_aurora_crc_pass;


  //---------------------------------------------------------------------------
  // Aurora IP
  //---------------------------------------------------------------------------

  logic [  REG_PAUSE_COUNT_LEN-1:0] a_nfc_pause_count;
  logic [ REG_PAUSE_THRESH_LEN-1:0] a_nfc_pause_thresh;
  logic [REG_RESUME_THRESH_LEN-1:0] a_nfc_resume_thresh;

  logic [15:0] a_nfc_tdata;
  logic        a_nfc_tvalid;
  logic        a_nfc_tready;

  logic a_fc_overflow_stb;
  logic a_crc_error_stb;

  logic [NUM_LANES-1:0] a_aurora_lane_up;
  logic                 a_aurora_link_up;
  logic                 a_aurora_hard_err;
  logic                 a_aurora_soft_err;
  logic                 a_aurora_pll_lock;
  logic                 a_aurora_sw_rst;
  logic                 a_tx_datapath_rst;
  logic                 d_aurora_sw_rst;

  aurora_flow_control #(
    .DATA_WIDTH    (AURORA_W     ),
    .MAX_PKT_SIZE_WORDS(2**AURORA_MTU)
  ) aurora_flow_control_i (
    .clk              (aurora_clk                     ),  
    .rst              (aurora_rst || a_tx_datapath_rst),
    .nfc_pause_count  (a_nfc_pause_count              ),
    .nfc_pause_thresh (a_nfc_pause_thresh             ),
    .nfc_resume_thresh(a_nfc_resume_thresh            ),
    .i_tdata          (a_from_aurora_tdata            ),
    .i_tkeep          ('1                             ),    
    .i_tvalid         (a_from_aurora_tvalid           ),
    .i_tlast          (a_from_aurora_tlast            ),
    .i_crc_pass       (a_crc_pass                     ),
    .i_crc_valid      (a_from_aurora_crc_valid        ),
    .o_tdata          (a_from_fc_tdata                ),
    .o_tkeep          (                               ),
    .o_tvalid         (a_from_fc_tvalid               ),
    .o_tlast          (a_from_fc_tlast                ),
    .o_tready         (a_from_fc_tready               ),
    .m_axi_nfc_tvalid (a_nfc_tvalid                   ),
    .m_axi_nfc_tdata  (a_nfc_tdata                    ),
    .m_axi_nfc_tready (a_nfc_tready                   ),
    .fc_overflow_stb  (a_fc_overflow_stb              ),
    .crc_error_stb    (a_crc_error_stb                )
  );

  aurora_wrapper #(
    .SIMULATION(SIMULATION)
  ) aurora_wrapper_i (
    // TX AXI4-S Interface
    .s_axi_tx_tdata  (a_to_aurora_tdata      ),
    .s_axi_tx_tkeep  (                       ),
    .s_axi_tx_tlast  (a_to_aurora_tlast      ),
    .s_axi_tx_tvalid (a_to_aurora_tvalid     ),
    .s_axi_tx_tready (a_to_aurora_tready     ),
    // RX AXI4-S Interface
    .m_axi_rx_tdata  (a_from_aurora_tdata    ),
    .m_axi_rx_tkeep  (                       ),
    .m_axi_rx_tlast  (a_from_aurora_tlast    ),
    .m_axi_rx_tvalid (a_from_aurora_tvalid   ),
    // Native Flow Control Interface
    .s_axi_nfc_tvalid(a_nfc_tvalid           ),
    .s_axi_nfc_tdata (a_nfc_tdata            ),
    .s_axi_nfc_tready(a_nfc_tready           ),
    // GTX Serial I/O
    .rxp             (rx_p                   ),
    .rxn             (rx_n                   ),
    .txp             (tx_p                   ),
    .txn             (tx_n                   ),
    // GTX Reference Clock Interface
    .refclk_p        (refclk_p               ),
    .refclk_n        (refclk_n               ),
    .hard_err        (a_aurora_hard_err      ),
    .soft_err        (a_aurora_soft_err      ),
    // Status Signals
    .channel_up      (a_aurora_link_up       ),
    .lane_up         (a_aurora_lane_up       ),
    .mmcm_lock       (a_aurora_mmcm_lock     ),
    .gt_pll_lock     (a_aurora_pll_lock      ),
    .crc_pass_fail_n (a_from_aurora_crc_pass ),
    .crc_valid       (a_from_aurora_crc_valid),
    // Control inputs
    .sw_reset        (d_aurora_sw_rst        ),
    .loopback        ('0                     ),
    // Clocking interface
    .init_clk        (dclk                   ),
    .user_clk        (aurora_clk             ),
    .sync_clk        (                       )
  );


  //---------------------------------------------------------------------------
  // Aurora Counters
  //---------------------------------------------------------------------------

  logic a_aurora_rx_pkt_stb;
  logic a_aurora_tx_pkt_stb;

  logic [COUNTER_W-1:0] a_aurora_tx_pkt_ctr   = '0;
  logic [COUNTER_W-1:0] a_aurora_rx_pkt_ctr   = '0;
  logic [COUNTER_W-1:0] a_aurora_overflow_ctr = '0;
  logic [COUNTER_W-1:0] a_aurora_crc_err_ctr  = '0;

  always_ff @(posedge aurora_clk) begin
    // The Aurora packet counters use the Aurora link as the point of reference  
    // for "RX" and "TX". Note that this is reversed from the perspective of
    // the aurora_tx_datapath and aurora_rx_datapath cores.
    // - a_aurora_rx_pkt_stb asserts when the Aurora interface receives a packet.  
    // - a_aurora_tx_pkt_stb asserts when the Aurora interface transmits a packet.  
    a_aurora_tx_pkt_stb <= (a_to_aurora_tvalid && a_to_aurora_tready && a_to_aurora_tlast);
    a_aurora_rx_pkt_stb <= (a_from_aurora_tvalid && a_from_aurora_tlast);

    if (a_fc_overflow_stb)   a_aurora_overflow_ctr <= a_aurora_overflow_ctr + 1;
    if (a_crc_error_stb)     a_aurora_crc_err_ctr  <= a_aurora_crc_err_ctr + 1;
    if (a_aurora_tx_pkt_stb) a_aurora_tx_pkt_ctr   <= a_aurora_tx_pkt_ctr + 1;
    if (a_aurora_rx_pkt_stb) a_aurora_rx_pkt_ctr   <= a_aurora_rx_pkt_ctr + 1;

    if (a_aurora_sw_rst) begin
      a_aurora_overflow_ctr <= '0;
      a_aurora_crc_err_ctr  <= '0;
      a_aurora_tx_pkt_ctr   <= '0;
      a_aurora_rx_pkt_ctr   <= '0;
    end
  end

  //synthesis translate_off
  always @(a_aurora_overflow_ctr) begin
    if (a_aurora_overflow_ctr > 0) begin
      $warning("Flow control reported an overflow");
    end
  end
  //synthesis translate_on


  //---------------------------------------------------------------------------
  // Aurora <-> RFNoC Clock Crossings
  //---------------------------------------------------------------------------

  synchronizer #(
    .WIDTH(4)
  ) synchronizer_lane_up (
    .clk(rfnoc_chdr_clk  ),
    .rst(1'b0            ),
    .in (a_aurora_lane_up),
    .out(r_aurora_lane_up)
  );

  synchronizer synchronizer_channel_up (
    .clk(rfnoc_chdr_clk     ),
    .rst(1'b0               ),
    .in (a_aurora_link_up),
    .out(r_aurora_link_up)
  );

  synchronizer synchronizer_hard_err (
    .clk(rfnoc_chdr_clk   ),
    .rst(1'b0             ),
    .in (a_aurora_hard_err),
    .out(r_aurora_hard_err)
  );

  synchronizer synchronizer_soft_err (
    .clk(rfnoc_chdr_clk   ),
    .rst(1'b0             ),
    .in (a_aurora_soft_err),
    .out(r_aurora_soft_err)
  );

  synchronizer synchronizer_mmcm_lock (
    .clk(rfnoc_chdr_clk    ),
    .rst(1'b0              ),
    .in (a_aurora_mmcm_lock),
    .out(r_aurora_mmcm_lock)
  );

  synchronizer synchronizer_pll_lock (
    .clk(rfnoc_chdr_clk   ),
    .rst(1'b0             ),
    .in (a_aurora_pll_lock),
    .out(r_aurora_pll_lock)
  );

  pulse_synchronizer #(
    .MODE("POSEDGE")
  ) pulse_synchronizer_d_clk_sw_rst (
    .clk_a  (rfnoc_chdr_clk ),
    .rst_a  (1'b0           ),
    .pulse_a(r_aurora_sw_rst),
    .busy_a (               ),
    .clk_b  (dclk           ),
    .pulse_b(d_aurora_sw_rst)
  );

  pulse_synchronizer #(
    .MODE("POSEDGE")
  ) pulse_synchronizer_a_clk_sw_rst (
    .clk_a  (rfnoc_chdr_clk ),
    .rst_a  (1'b0           ),
    .pulse_a(r_aurora_sw_rst),
    .busy_a (               ),
    .clk_b  (aurora_clk     ),
    .pulse_b(a_aurora_sw_rst)
  );

  pulse_synchronizer #(
    .MODE("POSEDGE")
  ) pulse_synchronizer_a_clk_tx_rst (
    .clk_a  (rfnoc_chdr_clk),
    .rst_a  (1'b0),
    .pulse_a(r_tx_datapath_rst),
    .busy_a (),
    .clk_b  (aurora_clk),
    .pulse_b(a_tx_datapath_rst)
  );

  handshake_latch #(
    .WIDTH(REG_PAUSE_COUNT_LEN)
  ) handshake_latch_pause_count (
    .clk_a  (rfnoc_chdr_clk   ),
    .rst_a  (1'b0             ),
    .valid_a(1'b1             ),
    .data_a (r_nfc_pause_count),
    .busy_a (                 ),
    .clk_b  (aurora_clk       ),
    .valid_b(                 ),
    .data_b (a_nfc_pause_count)
  );

  handshake_latch #(
    .WIDTH(REG_PAUSE_THRESH_LEN)
  ) handshake_latch_pause_thresh (
    .clk_a  (rfnoc_chdr_clk    ),
    .rst_a  (1'b0              ),
    .valid_a(1'b1              ),
    .data_a (r_nfc_pause_thresh),
    .busy_a (                  ),
    .clk_b  (aurora_clk        ),
    .valid_b(                  ),
    .data_b (a_nfc_pause_thresh)
  );

  handshake_latch #(
    .WIDTH(REG_RESUME_THRESH_LEN)
  ) handshake_latch_resume_thresh (
    .clk_a  (rfnoc_chdr_clk     ),
    .rst_a  (1'b0               ),
    .valid_a(1'b1               ),
    .data_a (r_nfc_resume_thresh),
    .busy_a (                   ),
    .clk_b  (aurora_clk         ),
    .valid_b(                   ),
    .data_b (a_nfc_resume_thresh)
  );

  handshake_latch #(
    .WIDTH(COUNTER_W)
  ) handshake_latch_overflow_ctr (
    .clk_a  (aurora_clk           ),
    .rst_a  (1'b0                 ),
    .valid_a(1'b1                 ),
    .data_a (a_aurora_overflow_ctr),
    .busy_a (                     ),
    .clk_b  (rfnoc_chdr_clk       ),
    .valid_b(                     ),
    .data_b (r_aurora_overflow_ctr)
  );

  handshake_latch #(
    .WIDTH(COUNTER_W)
  ) handshake_latch_crc_err_ctr (
    .clk_a  (aurora_clk          ),
    .rst_a  (1'b0                ),
    .valid_a(1'b1                ),
    .data_a (a_aurora_crc_err_ctr),
    .busy_a (                    ),
    .clk_b  (rfnoc_chdr_clk      ),
    .valid_b(                    ),
    .data_b (r_aurora_crc_err_ctr)
  );

  handshake_latch #(
    .WIDTH(COUNTER_W)
  ) handshake_latch_tx_pkt_ctr (
    .clk_a  (aurora_clk         ),
    .rst_a  (1'b0               ),
    .valid_a(1'b1               ),
    .data_a (a_aurora_tx_pkt_ctr),
    .busy_a (                   ),
    .clk_b  (rfnoc_chdr_clk     ),
    .valid_b(                   ),
    .data_b (r_aurora_tx_pkt_ctr)
  );

  handshake_latch #(
    .WIDTH(COUNTER_W)
  ) handshake_latch_rx_pkt_ctr (
    .clk_a  (aurora_clk         ),
    .rst_a  (1'b0               ),
    .valid_a(1'b1               ),
    .data_a (a_aurora_rx_pkt_ctr),
    .busy_a (                   ),
    .clk_b  (rfnoc_chdr_clk     ),
    .valid_b(                   ),
    .data_b (r_aurora_rx_pkt_ctr)
  );


  //---------------------------------------------------------------------------
  // Transport Adapter Interfaces
  //---------------------------------------------------------------------------

  logic a_aurora_activity_rst;
  logic a_aurora_valid_reg, a_aurora_valid_reg_prev, a_aurora_valid_pulse;
  logic a_aurora_activity;

  // Register the activity signals to make these paths easy for timing
  always_ff @(posedge aurora_clk) begin
    // Reset the activity driver to turn off the activity LED when link is down
    a_aurora_activity_rst   <= aurora_rst | ~a_aurora_link_up;
    // We infer "activity" from rising edges on the TX or RX valid signals
    a_aurora_valid_reg      <= a_to_aurora_tvalid | a_from_aurora_tvalid;
    a_aurora_valid_reg_prev <= a_aurora_valid_reg;
    // Create a single-cycle pulse
    a_aurora_valid_pulse    <= a_aurora_valid_reg && !a_aurora_valid_reg_prev;
  end

  // Stretch the activity pulse to make the LED flashes visible LED. We toggle
  // more frequently in simulation so we can more easily see it toggle.
  pulse_stretch #(
    .SCALE (SIMULATION ? 8 : 12_500_000)
  ) pulse_stretch_activity_i (
    .clk            (aurora_clk           ),
    .rst            (a_aurora_activity_rst),
    .pulse          (a_aurora_valid_pulse ),
    .pulse_stretched(a_aurora_activity    )
  );

  // Control clock domain signals
  logic c_aurora_activity;
  logic c_aurora_link_up;

  // Cross the activity indicator to the rfnoc_ctrl_clk domain
  synchronizer synchronizer_c_activity (
    .clk(rfnoc_ctrl_clk   ),
    .rst('0               ),
    .in (a_aurora_activity),
    .out(c_aurora_activity)
  );

  // Cross the channel-up indicator to the rfnoc_ctrl_clk domain
  synchronizer synchronizer_c_channel_up (
    .clk(rfnoc_ctrl_clk     ),
    .rst('0                 ),
    .in (a_aurora_link_up),
    .out(c_aurora_link_up)
  );

  // The link_up and activity signals are read asynchronously, so the clock
  // domain doesn't matter. But we use the rfnoc_ctrl_clock since these also
  // need to go to that domain.
  assign link_up  = { 3'b0, c_aurora_link_up  };
  assign activity = { 3'b0, c_aurora_activity };

  // The port_info signals need to be on the rfnoc_ctrl_clk domain. Set
  // protocol to disabled since this is not a transport adapter.
  for (genvar idx = 0; idx < 4; idx++) begin : gen_port_info
    assign port_info[32*idx +: 32] = {
      8'h0,               // TA compat number
      6'h0,               // Unused
      activity[idx],      // Activity LEDs
      link_up[idx],       // Link status
      8'(`MGT_Disabled),  // Protocol
      8'(QSFP_NUM)        // Port number
    };
  end


  //---------------------------------------------------------------------------
  // Unused Transport Adapter Interfaces
  //---------------------------------------------------------------------------
  //
  // Tie off these signals in a safe way since they're not needed by this RFNoC
  // block.
  //
  //---------------------------------------------------------------------------

  assign recovered_clk = 1'b0;
  assign rx_irq        = 1'b0;
  assign tx_irq        = 1'b0;

  // AXI-Lite Register Interface
  assign axil_awready = '1;
  assign axil_wready  = '1;
  assign axil_bresp   = '0;
  assign axil_bvalid  = '0;
  assign axil_arready = '1;
  assign axil_rdata   = '0;
  assign axil_rresp   = '0;
  assign axil_rvalid  = '0;

  // Ethernet DMA AXI to CPU memory
  assign axi_araddr  = '0;
  assign axi_arburst = '0;
  assign axi_arcache = '0;
  assign axi_arlen   = '0;
  assign axi_arlock  = '0;
  assign axi_arprot  = '0;
  assign axi_arqos   = '0;
  assign axi_arsize  = '0;
  assign axi_arvalid = '0;
  assign axi_awaddr  = '0;
  assign axi_awburst = '0;
  assign axi_awcache = '0;
  assign axi_awlen   = '0;
  assign axi_awlock  = '0;
  assign axi_awprot  = '0;
  assign axi_awqos   = '0;
  assign axi_awsize  = '0;
  assign axi_awvalid = '0;
  assign axi_bready  = '1;
  assign axi_rready  = '1;
  assign axi_wdata   = '0;
  assign axi_wlast   = '0;
  assign axi_wstrb   = '0;
  assign axi_wvalid  = '0;

endmodule : rfnoc_block_aurora


`default_nettype wire
