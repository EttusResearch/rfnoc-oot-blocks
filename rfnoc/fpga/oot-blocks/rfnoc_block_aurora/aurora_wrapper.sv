//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: aurora_wrapper.v
//
// Description:
//
//   Wrapper for the Aurora core. The module encapsulates the Aurora core,
//   streamlines the interface between the Aurora core and the RFNoC block, and
//   handles the IP initialization and reset.
//
// Parameters:
//
//   SIMULATION : Set to 0 for synthesis. Set to 1 for simulation to enable
//                faster simulation of Aurora IP when set to 1.
//

`default_nettype none


module aurora_wrapper #(
  parameter bit SIMULATION = 0
) (
  // TX AXI4-S Interface (user_clk domain)
  input  wire       [255:0] s_axi_tx_tdata,
  input  wire       [ 31:0] s_axi_tx_tkeep,
  input  wire               s_axi_tx_tlast,
  input  wire               s_axi_tx_tvalid,
  output wire logic         s_axi_tx_tready,

  // RX AXI4-S Interface (user_clk domain)
  output wire logic [255:0] m_axi_rx_tdata,
  output wire       [ 31:0] m_axi_rx_tkeep,
  output wire               m_axi_rx_tlast,
  output wire logic         m_axi_rx_tvalid,

  // Native Flow Control Interface (user_clk domain)
  input  wire               s_axi_nfc_tvalid,
  input  wire       [ 15:0] s_axi_nfc_tdata,
  output wire logic         s_axi_nfc_tready,

  // GTX Serial I/O
  input  wire       [  3:0] rxp,
  input  wire       [  3:0] rxn,
  output wire logic [  3:0] txp,
  output wire logic [  3:0] txn,

  // GTX Reference Clock Interface
  input  wire               refclk_p,
  input  wire               refclk_n,

  // Error Indicators (user_clk domain)
  output wire logic         hard_err,
  output wire logic         soft_err,

  // Status Signals (user_clk domain)
  output wire logic         channel_up,
  output wire logic [  3:0] lane_up,
  output wire logic         mmcm_lock,
  output wire logic         crc_pass_fail_n,
  output wire logic         crc_valid,

  // Status Signals (init_clk domain)
  output wire logic         gt_pll_lock,

  // Control Inputs (init_clk domain)
  input  wire               sw_reset,

  // Control Inputs (asynchronous)
  input  wire       [  2:0] loopback,

  // Clocking Interface
  input  wire               init_clk,
  output wire               user_clk,
  output wire               sync_clk
);



  //---------------------------------------------------------------------------
  // Clock Input
  //---------------------------------------------------------------------------

  logic refclk1_in;

  // Clocking signals for MGTs
  IBUFDS_GTE4 #(
    .REFCLK_HROW_CK_SEL(2'b00)
  ) ibufds_gte4_refclk (
    .I    (refclk_p  ),
    .IB   (refclk_n  ),
    .CEB  (1'b0      ),
    .O    (refclk1_in),
    .ODIV2(          )
  );


  //---------------------------------------------------------------------------
  // Reset Logic
  //---------------------------------------------------------------------------

  logic sys_reset_out_user;
  logic sys_reset_out_init;
  logic reset_pb;
  logic pma_init;

  synchronizer #(
    .STAGES     (2),
    .INITIAL_VAL(1)
  ) sys_reset_sync_i (
    .clk(init_clk          ),
    .rst(                  ),
    .in (sys_reset_out_user),
    .out(sys_reset_out_init)
  );

  aurora_core_reset_fsm #(
    .SIMULATION(SIMULATION)
  ) aurora_core_reset_fsm_i (
    .init_clk     (init_clk          ),
    .sw_reset     (sw_reset          ),
    .sys_reset_out(sys_reset_out_init),
    .reset_pb     (reset_pb          ),
    .pma_init     (pma_init          )
  );


  //---------------------------------------------------------------------------
  // Aurora IP
  //---------------------------------------------------------------------------

  logic mmcm_not_locked_out;

  assign mmcm_lock = ~mmcm_not_locked_out;

  // Enable faster simulation in the Aurora IP. This parameter doesn't exist in
  // the synthesizable version, so we exclude it from synthesis.
  //
  //synthesis translate_off
  defparam aurora_100g_i.inst.aurora_100g_core_i.EXAMPLE_SIMULATION = SIMULATION;
  //synthesis translate_on

  // Aurora core module
  aurora_100g aurora_100g_i (
    // TX AXI4-S Interface
    .s_axi_tx_tdata             (s_axi_tx_tdata     ),
    .s_axi_tx_tkeep             (s_axi_tx_tkeep     ),
    .s_axi_tx_tlast             (s_axi_tx_tlast     ),
    .s_axi_tx_tvalid            (s_axi_tx_tvalid    ),
    .s_axi_tx_tready            (s_axi_tx_tready    ),
    // RX AXI4-S Interface
    .m_axi_rx_tdata             (m_axi_rx_tdata     ),
    .m_axi_rx_tkeep             (m_axi_rx_tkeep     ),
    .m_axi_rx_tlast             (m_axi_rx_tlast     ),
    .m_axi_rx_tvalid            (m_axi_rx_tvalid    ),
    // Native Flow Control Interface
    .s_axi_nfc_tvalid           (s_axi_nfc_tvalid   ),
    .s_axi_nfc_tdata            (s_axi_nfc_tdata    ),
    .s_axi_nfc_tready           (s_axi_nfc_tready   ),
    // GTX Serial I/O
    .rxp                        (rxp                ),
    .rxn                        (rxn                ),
    .txp                        (txp                ),
    .txn                        (txn                ),
    // GTX Reference Clock Interface
    .refclk1_in                 (refclk1_in         ),
    .hard_err                   (hard_err           ),
    .soft_err                   (soft_err           ),
    // Status
    .channel_up                 (channel_up         ),
    .lane_up                    (lane_up            ),
    // System Interface
    .init_clk                   (init_clk           ),
    .reset_pb                   (reset_pb           ),  // Async input
    .power_down                 ('0                 ),
    .pma_init                   (pma_init           ),  // Async input
    .loopback                   (loopback           ),
    .gt_rxcdrovrden_in          ('0                 ),
    .mmcm_not_locked_out        (mmcm_not_locked_out),
    .gt_pll_lock                (gt_pll_lock        ),  // init_clk domain
    .gt_powergood               (                   ),
    .tx_out_clk                 (                   ),
    .link_reset_out             (                   ),
    .sys_reset_out              (sys_reset_out_user ),
    .gt_reset_out               (                   ),
    .crc_pass_fail_n            (crc_pass_fail_n    ),
    .crc_valid                  (crc_valid          ),
    // Clocking Interface
    .user_clk_out               (user_clk           ),
    .sync_clk_out               (sync_clk           ),
    // GT quad assignment
    .gt_qpllclk_quad1_out       (                   ),
    .gt_qpllrefclk_quad1_out    (                   ),
    .gt_qpllrefclklost_quad1_out(                   ),
    .gt_qplllock_quad1_out      (                   ),
    // AXI4-Lite Interface
    .s_axi_awaddr               ('0                 ),
    .s_axi_araddr               ('0                 ),
    .s_axi_wdata                ('0                 ),
    .s_axi_wstrb                ('0                 ),
    .s_axi_awvalid              ('0                 ),
    .s_axi_rready               ('1                 ),
    .s_axi_awaddr_lane1         ('0                 ),
    .s_axi_araddr_lane1         ('0                 ),
    .s_axi_wdata_lane1          ('0                 ),
    .s_axi_wstrb_lane1          ('0                 ),
    .s_axi_awvalid_lane1        ('0                 ),
    .s_axi_rready_lane1         ('1                 ),
    .s_axi_awaddr_lane2         ('0                 ),
    .s_axi_araddr_lane2         ('0                 ),
    .s_axi_wdata_lane2          ('0                 ),
    .s_axi_wstrb_lane2          ('0                 ),
    .s_axi_awvalid_lane2        ('0                 ),
    .s_axi_rready_lane2         ('1                 ),
    .s_axi_awaddr_lane3         ('0                 ),
    .s_axi_araddr_lane3         ('0                 ),
    .s_axi_wdata_lane3          ('0                 ),
    .s_axi_wstrb_lane3          ('0                 ),
    .s_axi_awvalid_lane3        ('0                 ),
    .s_axi_rready_lane3         ('1                 ),
    .s_axi_rdata                (                   ),
    .s_axi_awready              (                   ),
    .s_axi_wready               (                   ),
    .s_axi_bvalid               (                   ),
    .s_axi_bresp                (                   ),
    .s_axi_rresp                (                   ),
    .s_axi_bready               ('1                 ),
    .s_axi_arready              (                   ),
    .s_axi_rvalid               (                   ),
    .s_axi_arvalid              ('0                 ),
    .s_axi_wvalid               ('0                 ),
    .s_axi_rdata_lane1          (                   ),
    .s_axi_awready_lane1        (                   ),
    .s_axi_wready_lane1         (                   ),
    .s_axi_bvalid_lane1         (                   ),
    .s_axi_bresp_lane1          (                   ),
    .s_axi_rresp_lane1          (                   ),
    .s_axi_bready_lane1         ('1                 ),
    .s_axi_arready_lane1        (                   ),
    .s_axi_rvalid_lane1         (                   ),
    .s_axi_arvalid_lane1        ('0                 ),
    .s_axi_wvalid_lane1         ('0                 ),
    .s_axi_rdata_lane2          (                   ),
    .s_axi_awready_lane2        (                   ),
    .s_axi_wready_lane2         (                   ),
    .s_axi_bvalid_lane2         (                   ),
    .s_axi_bresp_lane2          (                   ),
    .s_axi_rresp_lane2          (                   ),
    .s_axi_bready_lane2         ('1                 ),
    .s_axi_arready_lane2        (                   ),
    .s_axi_rvalid_lane2         (                   ),
    .s_axi_arvalid_lane2        ('0                 ),
    .s_axi_wvalid_lane2         ('0                 ),
    .s_axi_rdata_lane3          (                   ),
    .s_axi_awready_lane3        (                   ),
    .s_axi_wready_lane3         (                   ),
    .s_axi_bvalid_lane3         (                   ),
    .s_axi_bresp_lane3          (                   ),
    .s_axi_rresp_lane3          (                   ),
    .s_axi_bready_lane3         ('1                 ),
    .s_axi_arready_lane3        (                   ),
    .s_axi_rvalid_lane3         (                   ),
    .s_axi_arvalid_lane3        ('0                 ),
    .s_axi_wvalid_lane3         ('0                 )
  );

endmodule : aurora_wrapper


`default_nettype wire
