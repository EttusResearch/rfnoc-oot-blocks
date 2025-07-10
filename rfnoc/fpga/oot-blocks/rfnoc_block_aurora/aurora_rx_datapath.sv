//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: aurora_rx_datapath.sv
//
// Description:
//
// This module is a wrapper for the RX datapath for the Aurora block. The
// module takes the incoming CHDR data from the CHDR interface of noc shell
// and resizes it to the Aurora bus width. The resized data is then sent to
// buffers and transferred into the Aurora clock domain, before merging all
// the channels into a single Aurora stream.
//
//
//
//   ┌──────────────┬────────────────────────────────────────────────────────┐
//   │  RX Datapath |                                                        │
//   ├──────────────┘                                                        │
//   │   ┌─────────────┐   ┌───────────────────┐      ┌───────────────────┐  │
//   │   │             │   │                   │      │                   │  │
//   │   │             │◄──┤    Buffer  Ch0    │◄─────┤ CHDR Resize* Ch0  │◄─┼─
//   │   │             │   │                   │      │                   │  │
//   │   │             │   └───────────────────┘      └───────────────────┘  │
//   │   │             │   ┌───────────────────┐      ┌───────────────────┐  │
//   │   │             │   │                   │      │                   │  │
//   │   │             │◄──┤    Buffer  Ch1    │◄─────┤ CHDR Resize* Ch1  │◄─┼─
//   │   │    CHDR     │   │                   │      │                   │  │
//   │   │             │   └───────────────────┘      └───────────────────┘  │
//   │   │   Channel   │             .                          .            │
//  ◄┼───┼             │             .                          .            │
//   │   │     MUX     │             .                          .            │
//   │   │             │             .                          .            │
//   │   │             │             .                          .            │
//   │   │             │             .                          .            │
//   │   │             │             .                          .            │
//   │   │             │             .                          .            │
//   │   │             │   ┌───────────────────┐      ┌───────────────────┐  │
//   │   │             │   │                   │      │                   │  │
//   │   │             │◄──┤    Buffer  ChN    │◄─────┤ CHDR Resize* ChN  │◄─┼─
//   │   │             │   │                   │      │                   │  │
//   │   └─────────────┘   └───────────────────┘      └───────────────────┘  │
//   │                                                                       │
//   └───────────────────────────────────────────────────────────────────────┘
//
//  *) For CHDR_W >= AURORA_W the CHDR Resize module is moved after the buffer,
//     in front of the MUX, to allow for optimal throughput.
//
// Parameters:
//   CHDR_W           : Width of the CHDR data bus in bits
//   NUM_PORTS        : Number of RF channels handled by the RX datapath module
//   MTU              : Log2 of maximum transmission unit of CHDR_W data packets
//   AXIS_AURORA_W    : Width of the Aurora data bus in bits, equivalent to the
//                      bus width of the Aurora IP to be connected.
//   CHANNEL_OFFSET: Offset for the RF channels handled by this module instance
//

`default_nettype none

module aurora_rx_datapath #(
  parameter int CHDR_W         = 64,
  parameter int NUM_PORTS      = 2,
  parameter int MTU            = 10,
  parameter int AXIS_AURORA_W  = 256,
  parameter int CHANNEL_OFFSET = 0
) (
  // Clocks and resets
  input wire logic rfnoc_chdr_clk,
  input wire logic rfnoc_chdr_rst,
  input wire logic aurora_clk,
  input wire logic aurora_rst,

  // Aurora interface
  output wire logic [AXIS_AURORA_W-1:0] m_axis_aurora_tdata,
  output wire logic                     m_axis_aurora_tvalid,
  output wire logic                     m_axis_aurora_tlast,
  input  wire logic                     m_axis_aurora_tready,

  // RFNoC CHDR interface
  input  wire logic [NUM_PORTS-1:0][CHDR_W-1:0] s_axis_rfnoc_tdata,
  input  wire logic [NUM_PORTS-1:0]             s_axis_rfnoc_tvalid,
  input  wire logic [NUM_PORTS-1:0]             s_axis_rfnoc_tlast,
  output wire logic [NUM_PORTS-1:0]             s_axis_rfnoc_tready
);

  //--------------------------------------------------------------------------
  // Local Parameters
  //--------------------------------------------------------------------------

  // Log2 of the maximum transmission unit in relative AXIS_AURORA_W data packets
  localparam int MTU_AURORA_BUS_W_LOG2 = $clog2((2 ** MTU * CHDR_W) / AXIS_AURORA_W);

  //--------------------------------------------------------------------------
  // Local Variables
  //--------------------------------------------------------------------------
  logic [NUM_PORTS-1:0][AXIS_AURORA_W-1:0] aurora_w_tdata;
  logic [NUM_PORTS-1:0]                    aurora_w_tvalid;
  logic [NUM_PORTS-1:0]                    aurora_w_tlast;
  logic [NUM_PORTS-1:0]                    aurora_w_tready;

  //--------------------------------------------------------------------------
  // Module Logic
  //--------------------------------------------------------------------------

  // Instantiate the CHDR Channel logic
  for (genvar channel = 0; channel < NUM_PORTS; channel++) begin : gen_rx_channel

    if (CHDR_W < AXIS_AURORA_W) begin : gen_resize_before_buffer
      // If the CHDR width is smaller than the Aurora bus width, we can resize
      // the CHDR data before buffering it, to ease timing.

      // Instantiate the CHDR Resize module to resize the CHDR data to the
      // Aurora bus width.
      logic [AXIS_AURORA_W-1:0] resize_tdata;
      logic                     resize_tvalid;
      logic                     resize_tlast;
      logic                     resize_tready;

      chdr_resize #(
        .I_CHDR_W(CHDR_W),
        .O_CHDR_W(AXIS_AURORA_W),
        .I_DATA_W(CHDR_W),
        .O_DATA_W(AXIS_AURORA_W),
        .USER_W  (1),
        .PIPELINE("IN")
      ) chdr_resize_chan_i (
        .clk          (rfnoc_chdr_clk),
        .rst          (rfnoc_chdr_rst),
        .i_chdr_tdata (s_axis_rfnoc_tdata[channel]),
        .i_chdr_tuser ('0),
        .i_chdr_tvalid(s_axis_rfnoc_tvalid[channel]),
        .i_chdr_tlast (s_axis_rfnoc_tlast[channel]),
        .i_chdr_tready(s_axis_rfnoc_tready[channel]),
        .o_chdr_tdata (resize_tdata),
        .o_chdr_tuser (),
        .o_chdr_tvalid(resize_tvalid),
        .o_chdr_tlast (resize_tlast),
        .o_chdr_tready(resize_tready)
      );

      // Instantiate the Aurora Buffer module to buffer the resized CHDR data
      // and transfer it into the Aurora clock domain.
      axi_fifo_2clk #(
        .WIDTH   (1 + AXIS_AURORA_W),
        .SIZE    (MTU_AURORA_BUS_W_LOG2),
        .PIPELINE("IN")
      ) aurora_buffer_chan_i (
        .reset   (rfnoc_chdr_rst),
        .i_aclk  (rfnoc_chdr_clk),
        .i_tdata ({resize_tlast, resize_tdata}),
        .i_tvalid(resize_tvalid),
        .i_tready(resize_tready),
        .o_aclk  (aurora_clk),
        .o_tdata ({aurora_w_tlast[channel], aurora_w_tdata[channel]}),
        .o_tvalid(aurora_w_tvalid[channel]),
        .o_tready(aurora_w_tready[channel])
      );

    end else begin: gen_resize_after_buffer
      // If the CHDR width is greater than the Aurora bus width, we resize
      // the CHDR data in the aurora clock domain, to optimize throughput.

      logic [CHDR_W-1:0] buffer_tdata;
      logic              buffer_tvalid;
      logic              buffer_tlast;
      logic              buffer_tready;

      // Instantiate the Aurora Buffer module to buffer the resized CHDR data
      // and transfer it into the Aurora clock domain.
      axi_fifo_2clk #(
        .WIDTH   (1 + CHDR_W),
        .SIZE    (MTU),
        .PIPELINE("IN")
      ) aurora_buffer_chan_i (
        .reset   (rfnoc_chdr_rst),
        .i_aclk  (rfnoc_chdr_clk),
        .i_tdata ({s_axis_rfnoc_tlast[channel], s_axis_rfnoc_tdata[channel]}),
        .i_tvalid(s_axis_rfnoc_tvalid[channel]),
        .i_tready(s_axis_rfnoc_tready[channel]),
        .o_aclk  (aurora_clk),
        .o_tdata ({buffer_tlast, buffer_tdata}),
        .o_tvalid(buffer_tvalid),
        .o_tready(buffer_tready)
      );

       // Instantiate the CHDR Resize module to resize the CHDR data to the
       // Aurora bus width.
      chdr_resize #(
        .I_CHDR_W(CHDR_W),
        .O_CHDR_W(AXIS_AURORA_W),
        .I_DATA_W(CHDR_W),
        .O_DATA_W(AXIS_AURORA_W),
        .USER_W  (1),
        .PIPELINE("IN")
      ) chdr_resize_chan_i (
        .clk          (aurora_clk),
        .rst          (aurora_rst),
        .i_chdr_tdata (buffer_tdata),
        .i_chdr_tuser ('0),
        .i_chdr_tvalid(buffer_tvalid),
        .i_chdr_tlast (buffer_tlast),
        .i_chdr_tready(buffer_tready),
        .o_chdr_tdata (aurora_w_tdata[channel]),
        .o_chdr_tuser (),
        .o_chdr_tvalid(aurora_w_tvalid[channel]),
        .o_chdr_tlast (aurora_w_tlast[channel]),
        .o_chdr_tready(aurora_w_tready[channel])
      );

    end
  end

  // Instantiate the Aurora Channel Mux module in order to merge all the
  // channels into a single CHDR data stream of the Aurora bus width.
  chdr_channel_mux #(
    .NUM_PORTS     (NUM_PORTS),
    .CHDR_W        (AXIS_AURORA_W),
    .CHANNEL_OFFSET(CHANNEL_OFFSET),
    .PRE_FIFO_SIZE (1),
    .POST_FIFO_SIZE(1),
    .PRIORITY      (0)
  ) chdr_channel_mux_i (
    .clk       (aurora_clk),
    .rst       (aurora_rst),
    .in_tdata  (aurora_w_tdata),
    .in_tvalid (aurora_w_tvalid),
    .in_tlast  (aurora_w_tlast),
    .in_tready (aurora_w_tready),
    .out_tdata (m_axis_aurora_tdata),
    .out_tvalid(m_axis_aurora_tvalid),
    .out_tlast (m_axis_aurora_tlast),
    .out_tready(m_axis_aurora_tready)
  );

endmodule

`default_nettype wire
