//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: aurora_tx_datapath
//
// Description:
//
//   This module is a wrapper for the TX datapath of the Aurora block. The
//   module takes the incoming CHDR packets from a single Aurora interface and
//   routes the packets to the appropriate RFNoC ports. The data is also
//   resized to the RFNoC CHDR width and a buffer is included to allow full
//   throughput to be achieved. A TX control module allows for software control
//   over when data is transferred to RFNoC.
//
//   ┌─────────────┬───────────────────────────────────────────────────────┐
//   │ TX Datapath |                                                       │
//   ├─────────────┘                                                       │
//   │   ┌─────────┐   ┌──────────┐   ┌────────────────┐   ┌────────────┐  │
//   │   │         │   │          │   │                │   │            │  │
//   │   │         ├──►│ Buffer 0 ├──►│ CHDR Resize* 0 ├──►│ TX Ctrl 0  ├──┼─►
//   │   │         │   │          │   │                │   │            │  │
//   │   │         │   └──────────┘   └────────────────┘   └────────────┘  │
//   │   │         │   ┌──────────┐   ┌────────────────┐   ┌────────────┐  │
//   │   │         │   │          │   │                │   │            │  │
//   │   │         ├──►│ Buffer 1 ├──►│ CHDR Resize* 1 ├──►│ TX Ctrl 1  ├──┼─►
//   │   │  CHDR   │   │          │   │                │   │            │  │
//   │   │         │   └──────────┘   └────────────────┘   └────────────┘  │
//   │   │ Channel │         .                .                  .         │
//  ─┼──►│         │         .                .                  .         │
//   │   │  Demux  │         .                .                  .         │
//   │   │         │         .                .                  .         │
//   │   │         │         .                .                  .         │
//   │   │         │         .                .                  .         │
//   │   │         │         .                .                  .         │
//   │   │         │         .                .                  .         │
//   │   │         │   ┌──────────┐   ┌────────────────┐   ┌────────────┐  │
//   │   │         │   │          │   │                │   │            │  │
//   │   │         ├──►│ Buffer N ├──►│ CHDR Resize* N ├──►│ TX Ctrl N  ├──┼─►
//   │   │         │   │          │   │                │   │            │  │
//   │   └─────────┘   └──────────┘   └────────────────┘   └────────────┘  │
//   │                                                                     │
//   └─────────────────────────────────────────────────────────────────────┘
//
//  *) For CHDR_W >= AURORA_W, the CHDR Resize module is moved between the
//     CHDR Demux module and the Buffer to optimize throughput.
//
// Parameters:
//
//   CHDR_W         : Width of the CHDR data bus in bits.
//   NUM_PORTS      : Number of RFNoC ports to generate.
//   MTU            : Log2 of maximum transmission unit of CHDR_W data packets.
//   AURORA_W       : Width of the Aurora data bus in bits, equivalent to the
//                    bus width of the Aurora IP to be connected.
//   EN_TX_CONTROL  : Include the TX control module when 1. Bypass it when 0.
//   TS_QUEUE_DEPTH : Log2 the size of the timestamp queue in the TX control
//                    module. Set to -1 for no timestamp queue.
//   CHANNEL_OFFSET : The offset for virtual channel numbers. Each packet will
//                    be routed to the output port VC-CHANNEL_OFFSET.
//   BUFFER_SIZE    : Log2 of the desired internal buffer size in CHDR_W words.
//                    This must be at least one maximum sized packet in order
//                    to prevent blocking upstream traffic. By default, it is
//                    sized to store one CHDR packet.
//

`default_nettype none


module aurora_tx_datapath
  import ctrlport_pkg::*;
#(
  parameter int CHDR_W         = 64,
  parameter int NUM_PORTS      = 2,
  parameter int MTU            = 10,
  parameter int AURORA_W       = 256,
  parameter bit EN_TX_CONTROL  = 1,
  parameter int TS_QUEUE_DEPTH = 32,
  parameter int CHANNEL_OFFSET = 0,
  parameter int BUFFER_SIZE    = MTU
) (
  // Aurora interface
  input  wire aurora_clk,
  input  wire aurora_rst,

  input  wire  [AURORA_W-1:0] s_aurora_tdata,
  input  wire                 s_aurora_tvalid,
  input  wire                 s_aurora_tlast,
  output logic                s_aurora_tready,

  // RFNoC CHDR interface
  input  wire  rfnoc_chdr_clk,
  input  wire  rfnoc_chdr_rst,

  output logic [NUM_PORTS-1:0][CHDR_W-1:0] m_rfnoc_tdata,
  output logic [NUM_PORTS-1:0]             m_rfnoc_tvalid,
  output logic [NUM_PORTS-1:0]             m_rfnoc_tlast,
  input  wire  [NUM_PORTS-1:0]             m_rfnoc_tready,

  // Control Port (rfnoc_chdr_clk domain)
  input  wire  [NUM_PORTS-1:0]                      ctrlport_req_wr,
  input  wire  [NUM_PORTS-1:0]                      ctrlport_req_rd,
  input  wire  [NUM_PORTS-1:0][CTRLPORT_ADDR_W-1:0] ctrlport_req_addr,
  input  wire  [NUM_PORTS-1:0][CTRLPORT_DATA_W-1:0] ctrlport_req_data,
  output logic [NUM_PORTS-1:0]                      ctrlport_resp_ack,
  output logic [NUM_PORTS-1:0][CTRLPORT_DATA_W-1:0] ctrlport_resp_data
);

  // Convert the buffer size from CHDR words to Aurora words
  parameter int AURORA_BUFFER_SIZE = $clog2(2**BUFFER_SIZE * CHDR_W / AURORA_W);


  //---------------------------------------------------------------------------
  // CHDR Channel Demultiplexer
  //---------------------------------------------------------------------------
  //
  // Route each CHDR packet from Aurora to the appropriate CHDR port.
  //
  //---------------------------------------------------------------------------

  logic [NUM_PORTS-1:0][AURORA_W-1:0] demux_tdata;
  logic [NUM_PORTS-1:0]               demux_tvalid;
  logic [NUM_PORTS-1:0]               demux_tlast;
  logic [NUM_PORTS-1:0]               demux_tready;

  chdr_channel_demux #(
    .NUM_PORTS     (NUM_PORTS     ),
    .CHDR_W        (AURORA_W      ),
    .CHANNEL_OFFSET(CHANNEL_OFFSET),
    .PRE_FIFO_SIZE (1             ),
    .POST_FIFO_SIZE(-1            )
  ) chdr_channel_demux_i (
    .clk       (aurora_clk     ),
    .rst       (aurora_rst     ),
    .in_tdata  (s_aurora_tdata ),
    .in_tvalid (s_aurora_tvalid),
    .in_tlast  (s_aurora_tlast ),
    .in_tready (s_aurora_tready),
    .out_tdata (demux_tdata    ),
    .out_tvalid(demux_tvalid   ),
    .out_tlast (demux_tlast    ),
    .out_tready(demux_tready   )
  );


  //---------------------------------------------------------------------------
  // Channel Logic
  //---------------------------------------------------------------------------
  //
  // Duplicate the same logic for each channel.
  //
  //---------------------------------------------------------------------------

  // Instantiate the CHDR channel logic
  for (genvar port = 0; port < NUM_PORTS; port++) begin : gen_tx_channel

    logic [CHDR_W-1:0] chdr_w_tdata;
    logic              chdr_w_tvalid;
    logic              chdr_w_tlast;
    logic              chdr_w_tready;

    // If CHDR_W is less than AURORA_W, we can resize the data in the CHDR clock
    // domain, otherwise we need to resize it in the Aurora clock domain to
    // achieve the desired throughput.
    if (CHDR_W < AURORA_W) begin : gen_resize_in_chdr_clk

      // This FIFO crosses clock domains and provides a buffer large enough to
      // prevent the upstream from stalling.
      logic [AURORA_W-1:0] buffer_tdata;
      logic                buffer_tvalid;
      logic                buffer_tlast;
      logic                buffer_tready;

      axi_fifo_2clk #(
        .WIDTH   (1 + AURORA_W      ),
        .SIZE    (AURORA_BUFFER_SIZE),
        .PIPELINE("IN"              )
      ) axi_fifo_2clk_i (
        .reset   (aurora_rst                            ),
        .i_aclk  (aurora_clk                            ),
        .i_tdata ({demux_tlast[port], demux_tdata[port]}),
        .i_tvalid(demux_tvalid[port]                    ),
        .i_tready(demux_tready[port]                    ),
        .o_aclk  (rfnoc_chdr_clk                        ),
        .o_tdata ({buffer_tlast, buffer_tdata}          ),
        .o_tvalid(buffer_tvalid                         ),
        .o_tready(buffer_tready                         )
      );

      // Instantiate the CHDR Resize module to resize the Aurora CHDR bus to
      // the RFNoC CHDR bus width.
      logic [CHDR_W-1:0] resize_tdata;
      logic              resize_tvalid;
      logic              resize_tlast;
      logic              resize_tready;

      chdr_resize #(
        .I_CHDR_W(AURORA_W),
        .O_CHDR_W(CHDR_W  ),
        .PIPELINE("INOUT" )
      ) chdr_resize_chan_i (
        .clk          (rfnoc_chdr_clk),
        .rst          (rfnoc_chdr_rst),
        .i_chdr_tdata (buffer_tdata  ),
        .i_chdr_tuser ('0            ),
        .i_chdr_tvalid(buffer_tvalid ),
        .i_chdr_tlast (buffer_tlast  ),
        .i_chdr_tready(buffer_tready ),
        .o_chdr_tdata (resize_tdata  ),
        .o_chdr_tuser (              ),
        .o_chdr_tvalid(resize_tvalid ),
        .o_chdr_tlast (resize_tlast  ),
        .o_chdr_tready(resize_tready )
      );

      assign chdr_w_tdata  = resize_tdata;
      assign chdr_w_tvalid = resize_tvalid;
      assign chdr_w_tlast  = resize_tlast;
      assign resize_tready = chdr_w_tready;

    end else begin : gen_resize_in_aurora_clk

      // Instantiate the CHDR Resize module to resize the Aurora CHDR bus to
      // the RFNoC CHDR bus width.
      logic [CHDR_W-1:0] resize_tdata;
      logic              resize_tvalid;
      logic              resize_tlast;
      logic              resize_tready;

      chdr_resize #(
        .I_CHDR_W(AURORA_W),
        .O_CHDR_W(CHDR_W  ),
        .PIPELINE("INOUT" )
      ) chdr_resize_chan_i (
        .clk          (aurora_clk),
        .rst          (aurora_rst),
        .i_chdr_tdata (demux_tdata[port]),
        .i_chdr_tuser ('0                ),
        .i_chdr_tvalid(demux_tvalid[port]),
        .i_chdr_tlast (demux_tlast[port] ),
        .i_chdr_tready(demux_tready[port]),
        .o_chdr_tdata (resize_tdata      ),
        .o_chdr_tuser (                  ),
        .o_chdr_tvalid(resize_tvalid     ),
        .o_chdr_tlast (resize_tlast      ),
        .o_chdr_tready(resize_tready     )
      );

      logic [CHDR_W-1:0] buffer_tdata;
      logic              buffer_tvalid;
      logic              buffer_tlast;
      logic              buffer_tready;

      // This FIFO crosses clock domains and provides a buffer large enough to
      // prevent the upstream from stalling.
      axi_fifo_2clk #(
        .WIDTH   (1 + CHDR_W ),
        .SIZE    (BUFFER_SIZE),
        .PIPELINE("OUT"      )
      ) axi_fifo_2clk_i (
        .reset   (aurora_rst                  ),
        .i_aclk  (aurora_clk                  ),
        .i_tdata ({resize_tlast, resize_tdata}),
        .i_tvalid(resize_tvalid               ),
        .i_tready(resize_tready               ),
        .o_aclk  (rfnoc_chdr_clk              ),
        .o_tdata ({buffer_tlast, buffer_tdata}),
        .o_tvalid(buffer_tvalid               ),
        .o_tready(buffer_tready               )
      );

      assign chdr_w_tdata  = buffer_tdata;
      assign chdr_w_tvalid = buffer_tvalid;
      assign chdr_w_tlast  = buffer_tlast;
      assign buffer_tready = chdr_w_tready;
    end

    if (EN_TX_CONTROL) begin : gen_tx_control
      aurora_tx_control #(
        .CHDR_W         (CHDR_W        ),
        .PRE_FIFO_DEPTH (-1            ),
        .TS_QUEUE_DEPTH (TS_QUEUE_DEPTH)
      ) aurora_tx_control_i (
        .rfnoc_chdr_clk    (rfnoc_chdr_clk          ),
        .rfnoc_chdr_rst    (rfnoc_chdr_rst          ),
        .s_axis_chdr_tdata (chdr_w_tdata            ),
        .s_axis_chdr_tlast (chdr_w_tlast            ),
        .s_axis_chdr_tvalid(chdr_w_tvalid           ),
        .s_axis_chdr_tready(chdr_w_tready           ),
        .m_axis_chdr_tdata (m_rfnoc_tdata[port]     ),
        .m_axis_chdr_tlast (m_rfnoc_tlast[port]     ),
        .m_axis_chdr_tvalid(m_rfnoc_tvalid[port]    ),
        .m_axis_chdr_tready(m_rfnoc_tready[port]    ),
        .ctrlport_req_wr   (ctrlport_req_wr[port]   ),
        .ctrlport_req_rd   (ctrlport_req_rd[port]   ),
        .ctrlport_req_addr (ctrlport_req_addr[port] ),
        .ctrlport_req_data (ctrlport_req_data[port] ),
        .ctrlport_resp_ack (ctrlport_resp_ack[port] ),
        .ctrlport_resp_data(ctrlport_resp_data[port])
      );
    end else begin : gen_no_tx_control
      assign m_rfnoc_tdata[port]  = chdr_w_tdata;
      assign m_rfnoc_tvalid[port] = chdr_w_tvalid;
      assign m_rfnoc_tlast[port]  = chdr_w_tlast;
      assign chdr_w_tready        = m_rfnoc_tready[port];

      // Respond to all reads/writes to prevent deadlock
      always_ff @(posedge rfnoc_chdr_clk) begin
        ctrlport_resp_ack[port] <= ctrlport_req_wr[port] | ctrlport_req_rd[port];
      end
      assign ctrlport_resp_data[port] = 'hBADC0DE;
    end

  end : gen_tx_channel

endmodule : aurora_tx_datapath


`default_nettype wire
