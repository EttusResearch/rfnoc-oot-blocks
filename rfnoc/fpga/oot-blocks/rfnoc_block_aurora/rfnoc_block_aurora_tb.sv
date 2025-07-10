//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: rfnoc_block_aurora_tb
//
// Description: Testbench for the Aurora RFNoC block.
//

`default_nettype none


module rfnoc_block_aurora_tb #(
  int CHDR_W              = 64,
  int NUM_PORTS           = 1,
  bit EN_TX_CONTROL       = 1,
  int TS_QUEUE_DEPTH_LOG2 = 5
);

  `include "test_exec.svh"
  `include `"`UHD_FPGA_DIR/usrp3/lib/control/usrp_utils.svh`"
  `include `"`UHD_FPGA_DIR/usrp3/lib/rfnoc/transport_adapters/rfnoc_ta_x4xx_eth/x4xx_mgt_types.vh`"

  import PkgTestExec::*;
  import rfnoc_chdr_utils_pkg::*;
  import PkgChdrData::*;
  import PkgRfnocBlockCtrlBfm::*;
  import PkgRfnocItemUtils::*;
  import PkgRandom::*;

  // Import register descriptions
  import aurora_regs_pkg::*;


  //---------------------------------------------------------------------------
  // Testbench Configuration
  //---------------------------------------------------------------------------

  // RFNoC configuration
  localparam [9:0] THIS_PORTID    = 10'h123;
  localparam [7:0] QSFP_NUM       = 8'hAD;
  localparam int   NUM_PORTS_I    = NUM_PORTS;
  localparam int   NUM_PORTS_O    = NUM_PORTS;
  localparam int   ITEM_W         = 32;
  localparam int   ITEM_BYTES     = ITEM_W / 8;
  localparam int   CHDR_BYTES     = CHDR_W / 8;      // Bytes per CHDR word
  localparam int   BYTE_MTU       = $clog2(8*1024);  // 8 KiB packets             // FIXME: Smaller MTU hangs TB
  localparam int   ITEM_MTU       = $clog2(2**BYTE_MTU / ITEM_BYTES);
  localparam int   CHDR_MTU       = $clog2(2**BYTE_MTU / CHDR_BYTES);
  localparam int   DEFAULT_BPP    = 128;             // Default bytes per packet
  localparam int   STALL_PROB     = 50;              // Default BFM stall probability
  localparam real  CHDR_CLK_PER   = 5.0;             // 200 MHz
  localparam real  CTRL_CLK_PER   = 8.0;             // 125 MHz
  localparam real  REFCLK_PER     = 6.4;             // 156.25 MHz
  localparam real  DCLK_PER       = 10.0;            // 100 MHz
  localparam real  CABLE_DELAY_NS = 50.0;            // Cable delay to model (~5 ns/m)

  localparam int  NUM_CORES     = 1;   // Only support 1 Aurora core for now
  localparam int  NUM_LANES     = 4;   // Only support 4 lanes per core for now
  localparam int  AURORA_W      = 256; // Only support 256-bit Aurora link for now
  localparam real BIT_PERIOD_NS = 0.4; // Bit period for 25 Gbps

  localparam int TS_QUEUE_DEPTH = 2**TS_QUEUE_DEPTH_LOG2;

  localparam int NUM_BURSTS = 25; // Number of bursts per test
  localparam bit VERBOSE    = 0;  // Enable additional print statements
  localparam bit RANDOM     = 1;  // Use random data instead of sequential data

  typedef struct {
    int master;
    int slave;
  } stall_cfg_t;

  stall_cfg_t stall_probs [] = '{
    '{STALL_PROB, STALL_PROB},
    '{90,         10},
    '{10,         90}
  };

  typedef enum int { CORE, CHAN } region_t;


  //---------------------------------------------------------------------------
  // Clocks and Resets
  //---------------------------------------------------------------------------

  bit rfnoc_chdr_clk;
  bit rfnoc_ctrl_clk;

  bit refclk;
  bit refclk_p;
  bit refclk_n;
  bit dclk;

  sim_clock_gen #(.PERIOD(CHDR_CLK_PER), .AUTOSTART(0))
    rfnoc_chdr_clk_gen (.clk(rfnoc_chdr_clk), .rst());
  sim_clock_gen #(.PERIOD(CTRL_CLK_PER), .AUTOSTART(0))
    rfnoc_ctrl_clk_gen (.clk(rfnoc_ctrl_clk), .rst());
  sim_clock_gen #(.PERIOD(REFCLK_PER), .AUTOSTART(0))
    refclk_gen (.clk(refclk), .rst());
  sim_clock_gen #(.PERIOD(DCLK_PER), .AUTOSTART(0))
    dclk_gen (.clk(dclk), .rst());


  //---------------------------------------------------------------------------
  // Bus Functional Models
  //---------------------------------------------------------------------------

  // Backend Interface
  RfnocBackendIf backend (rfnoc_chdr_clk, rfnoc_ctrl_clk);

  // AXIS-Ctrl Interface
  AxiStreamIf #(32) m_ctrl (rfnoc_ctrl_clk, 1'b0);
  AxiStreamIf #(32) s_ctrl (rfnoc_ctrl_clk, 1'b0);

  // AXIS-CHDR Interfaces
  AxiStreamIf #(CHDR_W) m_chdr [NUM_PORTS_I] (rfnoc_chdr_clk, 1'b0);
  AxiStreamIf #(CHDR_W) s_chdr [NUM_PORTS_O] (rfnoc_chdr_clk, 1'b0);

  // Block Controller BFM
  RfnocBlockCtrlBfm #(CHDR_W, ITEM_W) blk_ctrl = new(backend, m_ctrl, s_ctrl);

  // CHDR packet data types
  typedef ChdrPacket#(.CHDR_W(CHDR_W)) chdr_pkt_t;
  typedef chdr_pkt_t                   chdr_pkt_queue_t[$];

  // CHDR word and item/sample data types
  typedef ChdrData #(CHDR_W, ITEM_W)::chdr_word_t chdr_word_t;
  typedef ChdrData #(CHDR_W, ITEM_W)::item_t      item_t;

  typedef item_t item_queue_t[$];

  // Connect block controller to BFMs
  for (genvar i = 0; i < NUM_PORTS_I; i++) begin : gen_bfm_input_connections
    initial begin
      blk_ctrl.connect_master_data_port(i, m_chdr[i], DEFAULT_BPP);
      blk_ctrl.set_master_stall_prob(i, STALL_PROB);
    end
  end
  for (genvar i = 0; i < NUM_PORTS_O; i++) begin : gen_bfm_output_connections
    initial begin
      blk_ctrl.connect_slave_data_port(i, s_chdr[i]);
      blk_ctrl.set_slave_stall_prob(i, STALL_PROB);
    end
  end


  //---------------------------------------------------------------------------
  // Device Under Test (DUT)
  //---------------------------------------------------------------------------

  bit loopback_en = 1'b1;

  logic [3:0] tx_p;
  logic [3:0] tx_n;
  logic [3:0] rx_p;
  logic [3:0] rx_n;

  logic [127:0] port_info;
  logic [  3:0] link_up;
  logic [  3:0] activity;

  // DUT Slave (Input) Port Signals
  logic [NUM_PORTS_I-1:0][CHDR_W-1:0] s_rfnoc_chdr_tdata;
  logic [NUM_PORTS_I-1:0]             s_rfnoc_chdr_tlast;
  logic [NUM_PORTS_I-1:0]             s_rfnoc_chdr_tvalid;
  logic [NUM_PORTS_I-1:0]             s_rfnoc_chdr_tready;

  // DUT Master (Output) Port Signals
  logic [NUM_PORTS_O-1:0][CHDR_W-1:0] m_rfnoc_chdr_tdata;
  logic [NUM_PORTS_O-1:0]             m_rfnoc_chdr_tlast;
  logic [NUM_PORTS_O-1:0]             m_rfnoc_chdr_tvalid;
  logic [NUM_PORTS_O-1:0]             m_rfnoc_chdr_tready;

  // Map the array of BFMs to a flat vector for the DUT connections
  for (genvar i = 0; i < NUM_PORTS_I; i++) begin : gen_dut_input_connections
    // Connect BFM master to DUT slave port
    assign s_rfnoc_chdr_tdata[i]  = m_chdr[i].tdata;
    assign s_rfnoc_chdr_tlast[i]  = m_chdr[i].tlast;
    assign s_rfnoc_chdr_tvalid[i] = m_chdr[i].tvalid;
    assign m_chdr[i].tready       = s_rfnoc_chdr_tready[i];
  end
  for (genvar i = 0; i < NUM_PORTS_O; i++) begin : gen_dut_output_connections
    // Connect BFM slave to DUT master port
    assign s_chdr[i].tdata        = m_rfnoc_chdr_tdata[i];
    assign s_chdr[i].tlast        = m_rfnoc_chdr_tlast[i];
    assign s_chdr[i].tvalid       = m_rfnoc_chdr_tvalid[i];
    assign m_rfnoc_chdr_tready[i] = s_chdr[i].tready;
  end

  // Test with external loopback
  always_comb begin
    if (loopback_en) begin
      rx_p <= #(2.0 * CABLE_DELAY_NS * 1.0ns) tx_p;
      rx_n <= #(2.0 * CABLE_DELAY_NS * 1.0ns) tx_n;
    end else begin
      rx_p <= #(2.0 * CABLE_DELAY_NS * 1.0ns) 1'b0;
      rx_n <= #(2.0 * CABLE_DELAY_NS * 1.0ns) 1'b1;
    end
  end

  assign refclk_p = refclk;
  assign refclk_n = ~refclk;

  rfnoc_block_aurora #(
    .THIS_PORTID  (THIS_PORTID  ),
    .CHDR_W       (CHDR_W       ),
    .MTU          (CHDR_MTU     ),
    .NUM_PORTS    (NUM_PORTS    ),
    .QSFP_NUM     (QSFP_NUM     ),
    .EN_TX_CONTROL(EN_TX_CONTROL),
    .SIMULATION   (1            )
  ) dut (
    .rfnoc_chdr_clk     (rfnoc_chdr_clk     ),
    .rfnoc_ctrl_clk     (rfnoc_ctrl_clk     ),
    .rfnoc_core_config  (backend.cfg        ),
    .rfnoc_core_status  (backend.sts        ),
    .refclk_p           (refclk_p           ),
    .refclk_n           (refclk_n           ),
    .dclk               (dclk               ),
    .tx_p               (tx_p               ),
    .tx_n               (tx_n               ),
    .rx_p               (rx_p               ),
    .rx_n               (rx_n               ),
    .recovered_clk      (                   ),
    .device_id          ('X                 ),
    .rx_irq             (                   ),
    .tx_irq             (                   ),
    .port_info          (port_info          ),
    .link_up            (link_up            ),
    .activity           (activity           ),
    .axil_rst           ('X                 ),
    .axil_clk           ('X                 ),
    .axil_awaddr        ('X                 ),
    .axil_awvalid       ('X                 ),
    .axil_awready       (                   ),
    .axil_wdata         ('X                 ),
    .axil_wstrb         ('X                 ),
    .axil_wvalid        ('X                 ),
    .axil_wready        (                   ),
    .axil_bresp         (                   ),
    .axil_bvalid        (                   ),
    .axil_bready        ('X                 ),
    .axil_araddr        ('X                 ),
    .axil_arvalid       ('X                 ),
    .axil_arready       (                   ),
    .axil_rdata         (                   ),
    .axil_rresp         (                   ),
    .axil_rvalid        (                   ),
    .axil_rready        ('X                 ),
    .axi_rst            ('X                 ),
    .axi_clk            ('X                 ),
    .axi_araddr         (                   ),
    .axi_arburst        (                   ),
    .axi_arcache        (                   ),
    .axi_arlen          (                   ),
    .axi_arlock         (                   ),
    .axi_arprot         (                   ),
    .axi_arqos          (                   ),
    .axi_arready        ('X                 ),
    .axi_arsize         (                   ),
    .axi_arvalid        (                   ),
    .axi_awaddr         (                   ),
    .axi_awburst        (                   ),
    .axi_awcache        (                   ),
    .axi_awlen          (                   ),
    .axi_awlock         (                   ),
    .axi_awprot         (                   ),
    .axi_awqos          (                   ),
    .axi_awready        ('X                 ),
    .axi_awsize         (                   ),
    .axi_awvalid        (                   ),
    .axi_bready         (                   ),
    .axi_bresp          ('X                 ),
    .axi_bvalid         ('X                 ),
    .axi_rdata          ('X                 ),
    .axi_rlast          ('X                 ),
    .axi_rready         (                   ),
    .axi_rresp          ('X                 ),
    .axi_rvalid         ('X                 ),
    .axi_wdata          (                   ),
    .axi_wlast          (                   ),
    .axi_wready         ('X                 ),
    .axi_wstrb          (                   ),
    .axi_wvalid         (                   ),
    .s_rfnoc_chdr_tdata (s_rfnoc_chdr_tdata ),
    .s_rfnoc_chdr_tlast (s_rfnoc_chdr_tlast ),
    .s_rfnoc_chdr_tvalid(s_rfnoc_chdr_tvalid),
    .s_rfnoc_chdr_tready(s_rfnoc_chdr_tready),
    .m_rfnoc_chdr_tdata (m_rfnoc_chdr_tdata ),
    .m_rfnoc_chdr_tlast (m_rfnoc_chdr_tlast ),
    .m_rfnoc_chdr_tvalid(m_rfnoc_chdr_tvalid),
    .m_rfnoc_chdr_tready(m_rfnoc_chdr_tready),
    .s_rfnoc_ctrl_tdata (m_ctrl.tdata       ),
    .s_rfnoc_ctrl_tlast (m_ctrl.tlast       ),
    .s_rfnoc_ctrl_tvalid(m_ctrl.tvalid      ),
    .s_rfnoc_ctrl_tready(m_ctrl.tready      ),
    .m_rfnoc_ctrl_tdata (s_ctrl.tdata       ),
    .m_rfnoc_ctrl_tlast (s_ctrl.tlast       ),
    .m_rfnoc_ctrl_tvalid(s_ctrl.tvalid      ),
    .m_rfnoc_ctrl_tready(s_ctrl.tready      )
  );


  //---------------------------------------------------------------------------
  // Monitors
  //---------------------------------------------------------------------------

  // Any time port_info or its inputs change, make sure it's correct
  always @(port_info, activity, link_up) begin : monitor_port_info
    for (int idx = 0; idx < 4; idx++) begin
      logic [31:0] actual, expected;
      actual = port_info[idx*32+:32];
      expected = {
        8'h0,               // TA compat number
        6'h0,               // Unused
        activity[idx],      // Activity LEDs
        link_up[idx],       // Link status
        8'(`MGT_Disabled),  // Protocol
        8'(QSFP_NUM)        // Port number
      };
      `ASSERT_ERROR(actual == expected, $sformatf(
        "port_info doesn't match on lane %0d. Read 0x%X, Expected 0x%X",
        idx, actual, expected));
    end
  end


  int act_count [NUM_PORTS];

  // Count activity rising edges so we can verify that it toggles
  for (genvar lane = 0; lane < NUM_PORTS; lane++) begin
    always @(posedge activity[lane]) begin
      act_count[lane]++;
    end
  end


  // Create indicators for when packets leave the Aurora IP
  logic from_aurora_sop;
  logic from_aurora_eop;

  axis_monitor axis_monitor_aurora (
    .clk       (dut.aurora_clk          ),
    .rst       (dut.aurora_rst          ),
    .i_tlast   (dut.a_from_aurora_tlast ),
    .i_tvalid  (dut.a_from_aurora_tvalid),
    .i_tready  (1'b1                    ),
    .xfer      (                        ),
    .sop       (from_aurora_sop         ),
    .eop       (from_aurora_eop         ),
    .xfer_count(                        ),
    .pkt_count (                        )
  );


  for (genvar port = 0; port < NUM_PORTS; port++) begin : gen_chdr_monitors
    logic s_rfnoc_chdr_sop;
    chdr_header_t s_rfnoc_chdr_header;

    chdr_monitor #(
      .CHDR_W(CHDR_W)
    ) chdr_monitor_i (
      .clk        (rfnoc_chdr_clk           ),
      .rst        (1'b0                     ),
      .i_tdata    (s_rfnoc_chdr_tdata [port]),
      .i_tlast    (s_rfnoc_chdr_tlast [port]),
      .i_tvalid   (s_rfnoc_chdr_tvalid[port]),
      .i_tready   (s_rfnoc_chdr_tready[port]),
      .xfer       (                         ),
      .sop        (s_rfnoc_chdr_sop         ),
      .eop        (                         ),
      .sob        (                         ),
      .eob        (                         ),
      .xfer_count (                         ),
      .pkt_count  (                         ),
      .burst_count(                         ),
      .timestamp  (                         ),
      .chdr_header(s_rfnoc_chdr_header      )
    );

    // Make sure we don't accidentally input a packet that exceeds the MTU
    always_ff @(posedge rfnoc_chdr_clk) begin
      if (s_rfnoc_chdr_sop) begin
        `ASSERT_ERROR(s_rfnoc_chdr_header.length <= 2**BYTE_MTU,
          "Input packet exceeds MTU");
      end
    end
  end


  //---------------------------------------------------------------------------
  // Helper Tasks
  //---------------------------------------------------------------------------

  // We can have multiple threads accessing the register interface, so use a
  // semaphore to prevent multiple threads from colliding.
  semaphore reg_access = new(1);

  // Write to a register in the shared register space.
  task automatic write_core_reg (
    input logic [31:0] write_val,
    input int unsigned addr = 0,
    input int          core = 0
  );
    int base_addr = core * (2**AURORA_CORE_ADDR_W);
    `ASSERT_ERROR(addr < 2**AURORA_CHAN_ADDR_W, "Address out of range");
    `ASSERT_ERROR(core < NUM_CORES, "Specified core does not exist");
    reg_access.get();
    blk_ctrl.reg_write(base_addr+addr, write_val);
    reg_access.put();
  endtask


  // Read from a register in the shared register space.
  task automatic read_core_reg (
    output logic [31:0] read_val,
    input  int unsigned addr = 0,
    input  int          core = 0
  );
    int base_addr = core * (2**AURORA_CORE_ADDR_W);
    `ASSERT_ERROR(addr < 2**AURORA_CHAN_ADDR_W, "Address out of range");
    `ASSERT_ERROR(core < NUM_CORES, "Specified core does not exist");
    reg_access.get();
    blk_ctrl.reg_read(base_addr + addr, read_val);
    reg_access.put();
  endtask


  // Write to a register in one of the channels.
  task automatic write_chan_reg (
    input logic [31:0] write_val,
    input int unsigned addr,
    input int          chan = 0,
    input int          core = 0
  );
    int base_addr = core * (2**AURORA_CORE_ADDR_W) + (chan + 1) * (2**AURORA_CHAN_ADDR_W);
    `ASSERT_ERROR(addr < 2**AURORA_CHAN_ADDR_W, "Address out of range");
    `ASSERT_ERROR(chan < NUM_PORTS, "Specified channel does not exist");
    `ASSERT_ERROR(core < NUM_CORES, "Specified core does not exist");
    reg_access.get();
    blk_ctrl.reg_write(base_addr + addr, write_val);
    reg_access.put();
  endtask


  // Read from a register in one of the channels.
  task automatic read_chan_reg (
    output logic [31:0] read_val,
    input  int unsigned addr,
    input  int          chan = 0,
    input  int          core = 0
  );
  int base_addr = core * (2**AURORA_CORE_ADDR_W) + (chan + 1) * (2**AURORA_CHAN_ADDR_W);
    `ASSERT_ERROR(addr < 2**AURORA_CHAN_ADDR_W, "Address out of range");
    `ASSERT_ERROR(chan < NUM_PORTS, "Specified channel does not exist");
    `ASSERT_ERROR(core < NUM_CORES, "Specified core does not exist");
    reg_access.get();
    blk_ctrl.reg_read(base_addr + addr, read_val);
    reg_access.put();
  endtask


  // Creates and returns a CHDR test packet. If RANDOM=1 then the data will be
  // randomized. Otherwise the data will be of the form {burst, count}.
  function automatic chdr_pkt_t gen_chdr_packet(
    int max_pyld_bytes = 3*CHDR_BYTES,
    int max_mdata_words = 3,
    shortint pkt_count = 0,
    shortint burst_count = 0,
    logic [CHDR_PKT_TYPE_W-1:0] pkt_type = 'X, logic eob = 0);
    chdr_pkt_t pkt = new();
    int pyld_size;  // Payload size in bytes
    int num_words;  // Number of CHDR payload words
    int num_mdata;  // Number of metadata words

    // Create header for this random packet
    pkt.header = Rand#(CHDR_HEADER_W)::rand_bit();

    // Coerce the packet type if one was provided
    if (pkt_type !== 'X) begin
      pkt.header.pkt_type = chdr_pkt_type_t'(pkt_type);
    end

    // If timed, give it a random timestamp
    if (pkt.header.pkt_type == CHDR_PKT_TYPE_DATA_TS) begin
      pkt.timestamp = Rand#(CHDR_TIMESTAMP_W)::rand_bit();
    end

    // If this packet is the end of a burst, set the EOB bit
    if (eob) begin
      pkt.header.eob = 1;
    end

    // Choose a random metadata size, but make sure the amount of input
    // metadata isn't too much for the Aurora CHDR packet, which may have a
    // different metadata size.
    if (max_mdata_words * CHDR_W > CHDR_MAX_NUM_MDATA*AURORA_W) begin
      max_mdata_words = CHDR_MAX_NUM_MDATA*AURORA_W / CHDR_W;
    end
    num_mdata = $urandom_range(0, max_mdata_words);
    pkt.header.num_mdata = num_mdata;

    // Choose random payload size. For data packets, make it a multiple of the
    // item size.
    if (pkt.header.pkt_type == CHDR_PKT_TYPE_DATA ||
        pkt.header.pkt_type == CHDR_PKT_TYPE_DATA_TS) begin
      pyld_size = $urandom_range(1, max_pyld_bytes/ITEM_BYTES) * ITEM_BYTES;
    end else begin
      pyld_size = $urandom_range(1, max_pyld_bytes);
    end
    if (pkt.header.pkt_type == CHDR_MANAGEMENT) begin
      // Management packets are a bit special in that they only contain whole
      // CHDR words. Round the payload size up to a multiple of the CHDR size.
      pyld_size = $ceil(real'(pyld_size) / CHDR_BYTES) * CHDR_BYTES;
    end
    num_words = $ceil(real'(pyld_size) / CHDR_BYTES);
    pkt.header = chdr_update_length(CHDR_W, pkt.header, pyld_size);

    if (RANDOM) begin
      repeat (num_mdata) pkt.metadata.push_back(Rand#(CHDR_W)::rand_bit());
      if (pkt.header.pkt_type == CHDR_MANAGEMENT) begin
        // Only lower 64-bits of management packets are used
        repeat (num_words) pkt.data.push_back(Rand#(CHDR_HEADER_W)::rand_bit());
      end else begin
        repeat (num_words) pkt.data.push_back(Rand#(CHDR_W)::rand_bit());
      end
    end else begin
      int mcount = 0;
      int dcount = 0;
      repeat (num_mdata) pkt.metadata.push_back({burst_count, pkt_count, mcount++});
      repeat (num_words) pkt.data.push_back({burst_count, pkt_count, dcount++});
    end

    // Make sure the CHDRWidth field is correct for management packets. This is
    // needed because we may do CHDR width conversion between CHDR_W and
    // AURORA_W in the DUT.
    if (pkt.header.pkt_type == CHDR_MANAGEMENT) begin
      chdr_mgmt_header_t mgmt_hdr;
      mgmt_hdr = pkt.data[0];
      mgmt_hdr.chdr_width = translate_chdr_w(CHDR_W);
      pkt.data[0] = mgmt_hdr;
    end

    return pkt;
  endfunction


  // Creates the expected packet from the packet that was input based on the
  // the changes we expect the DUT to make.
  //
  //   pkt  : The packet that was input into the DUT. This function does not
  //          modify pkt.
  //   port : The port that the packet was input to.
  //
  //   Returns the expected packet in a newly created chdr_pkt_t object.
  //
  function automatic chdr_pkt_t gen_expected_pkt(chdr_pkt_t pkt, int port);
    chdr_pkt_t exp_pkt = pkt.copy();
    int num_mdata = pkt.metadata.size();

    // The DUT will update the VC based on the port that was used to send it.
    exp_pkt.header.vc = port;

    // The metadata will be resized if the Aurora CHDR metadata word size is
    // larger than the input CHDR metadata word size.
    if (exp_pkt.metadata.size() > 0 && AURORA_W > CHDR_W) begin
      // Round up to the Aurora CHDR size
      int num_aurora_words = $ceil(real'(num_mdata) * CHDR_W / AURORA_W);
      // Convert back to the block's RFNoC CHDR size
      int new_num_mdata = num_aurora_words * AURORA_W / CHDR_W;
      // How many words are we adding?
      int words_to_add = new_num_mdata - num_mdata;
      // Add the metadata and update the length fields
      repeat (words_to_add) exp_pkt.metadata.push_back(0);
      exp_pkt.header.num_mdata = new_num_mdata;
      exp_pkt.header.length += words_to_add * CHDR_BYTES;
    end
    return exp_pkt;
  endfunction


  // Test sending and receiving random packets on the indicated port.
  //
  //   port               : Port number to test
  //   block_timed        : When 1, configure the timestamp queue so that the
  //                        block adds timestamps.
  //   num_bursts         : Number of bursts to send
  //   max_pkts_per_burst : The number of packet in each burst will be in the
  //                        range 1 to this value.
  //   max_pyld_bytes     : The maximum packet payload size in bytes
  //   max_mdata_words    : The maximum metadata size in CHDR words
  //   total_packets      : Total number of packets sent/received
  //
  task automatic test_random_packets(
    int port = 0,
    bit block_timed = 0,
    int num_bursts = 3,
    int max_pkts_per_burst = 3,
    int max_pyld_bytes = 3*`MAX(CHDR_W, AURORA_W)/8,
    int max_mdata_words = 3,
    output int total_packets
  );
    int num_pkts_sent;

    // Mailbox to communicate the expected packets to the reader
    mailbox #(chdr_pkt_t) exp_pkts_mb = new();

    // Mailbox to communicate the expected timestamps
    mailbox #(chdr_timestamp_t) exp_ts_mb = new();

    if (block_timed && !EN_TX_CONTROL) begin
      `ASSERT_WARNING(0,
        "Block-timed mode requires EN_TX_CONTROL to be enabled; test skipped");
      return;
    end

    if (block_timed) begin
      logic [31:0] val;

      `ASSERT_FATAL(num_bursts <= TS_QUEUE_DEPTH,
        "num_bursts is too large for the timestamp queue");

      // Queue up the timestamps we want to use for each burst
      for (int burst_count = 0; burst_count < num_bursts; burst_count++) begin
        chdr_timestamp_t ts;
        if (RANDOM) ts = Rand#(CHDR_TIMESTAMP_W)::rand_bit();
        else ts = {burst_count, 32'b0};
        exp_ts_mb.put(ts);

        if (VERBOSE) begin
          $display("Writing 0x%X to the TS queue for burst %0d",
            ts, burst_count);
        end
        write_chan_reg(ts[31: 0], REG_CHAN_TS_LOW_ADDR,  port);
        write_chan_reg(ts[63:32], REG_CHAN_TS_HIGH_ADDR, port);
      end

      // Verify the fullness is what we expect
      read_chan_reg(val, REG_CHAN_TS_QUEUE_STS_ADDR, port);
      `ASSERT_ERROR(val == (
        (TS_QUEUE_DEPTH << REG_TS_SIZE_POS) |
        (num_bursts << REG_TS_FULLNESS_POS)),
        "Timestamp queue fullness is not what we expect");
    end

    // Enable transfers through the block
    if (EN_TX_CONTROL) begin
      write_chan_reg(1 << REG_CHAN_TX_START_POS, REG_CHAN_TX_CTRL_ADDR, port);
    end

    fork
      begin : writer
        chdr_pkt_t pkt;
        int num_pkts;

        for (int burst_count = 0; burst_count < num_bursts; burst_count++) begin
          num_pkts = $urandom_range(1, max_pkts_per_burst);
          for (int pkt_count = 0; pkt_count < num_pkts; pkt_count++) begin
            // If the block is handling timestamps for us, then we need to set
            // the packet type appropriately. If the block is not doing it for
            // us, then we leave everything randomized except EOB and expect it
            // to go through unchanged.
            if (block_timed) begin
              // Generate a timed data packet
              pkt = gen_chdr_packet(max_pyld_bytes, max_mdata_words, pkt_count,
                burst_count, CHDR_DATA_WITH_TS);

              // We do a timed packet for the start of burst but leave the
              // others randomly timed/untimed.
              // FIXME: The DUT currently requires that all subsequent packets
              //        have the same type.
              // if (pkt_count > 0 && $urandom_range(1)) begin
              if (pkt_count > 0) begin // Modified to work around the above
                int pyld_bytes;
                pyld_bytes = pkt.data_bytes();
                pkt.header.pkt_type = CHDR_DATA_NO_TS;
                pkt.timestamp = 0;
                pkt.update_lengths(pyld_bytes);
              end
            end else begin
              // Totally random packet of any type
              pkt = gen_chdr_packet(max_pyld_bytes, max_mdata_words, pkt_count,
                burst_count);
            end
            pkt.header.eob = (pkt_count == num_pkts-1);

            exp_pkts_mb.put(gen_expected_pkt(pkt, port));
            blk_ctrl.put_chdr(port, pkt);
            if (VERBOSE) begin
              if (pkt.header.pkt_type == CHDR_DATA_WITH_TS) begin
                $display(
                  "Sent burst %0d, packet %0d, on port %0d (Samps: %0d, TS: 0x%X)",
                  burst_count, pkt_count, port, pkt.data_bytes()/ITEM_BYTES,
                  pkt.timestamp);
              end else begin
                $display(
                  "Sent burst %0d, packet %0d, on port %0d (Samps: %0d, No TS)",
                  burst_count, pkt_count, port, pkt.data_bytes()/ITEM_BYTES);
              end
            end
          end
          num_pkts_sent += num_pkts;
        end

        // Let the reader thread know we're done by giving it a a null packet.
        exp_pkts_mb.put(null);
      end : writer

      begin : reader
        chdr_pkt_t act_pkt, exp_pkt;  // Actual and expected packets
        int pkt_count = 0;
        int burst_count = 0;
        bit sob = 1;  // Start of burst
        int pyld_bytes_prev;
        chdr_timestamp_t timestamp;

        forever begin
          // Grab the next packet we expect the DUT to send us
          exp_pkts_mb.get(exp_pkt);

          // If it's null, that means there are no more packets and we're done
          if (exp_pkt == null) break;

          // Wait for the packet from the DUT
          blk_ctrl.get_chdr(port, act_pkt);
          if (VERBOSE) begin
            if (act_pkt.header.pkt_type == CHDR_DATA_WITH_TS) begin
              $display(
                "Received burst %0d, packet %0d, on port %0d (Samps: %0d, TS: 0x%X)",
                burst_count, pkt_count, port, act_pkt.data_bytes()/ITEM_BYTES,
                act_pkt.timestamp);
            end else begin
              $display(
                "Received burst %0d, packet %0d, on port %0d (Samps: %0d, No TS)",
                burst_count, pkt_count, port, act_pkt.data_bytes()/ITEM_BYTES);
            end
          end

          // If the block is handling timestamps for us, then we expect the
          // timestamps to match what was put in the queue.
          if (block_timed) begin
            if (sob) begin
              // Each new burst pulls a timestamp from the queue
              sob = 0;
              exp_ts_mb.get(timestamp);
            end else begin
              // In the middle of the burst, we expect the timestamp to
              // increment based on the number of items in the payload.
              timestamp += pyld_bytes_prev / ITEM_BYTES;
            end
            pyld_bytes_prev = act_pkt.data_bytes();

            // Update the timestamp with the one we expect
            if (exp_pkt.header.pkt_type == CHDR_DATA_WITH_TS) begin
              exp_pkt.timestamp = timestamp;
            end
          end

          if (!act_pkt.equal(exp_pkt)) begin
            $display("Expected Packet:");
            exp_pkt.print();
            $display("Actual Packet:");
            act_pkt.print();
            `ASSERT_ERROR(0, $sformatf(
              "Output packet %0d of burst %0d, on port %0d does not match expected",
              pkt_count, burst_count, port));
          end
          sob = act_pkt.header.eob;
          burst_count += act_pkt.header.eob;
          pkt_count = act_pkt.header.eob ? 0 : pkt_count + 1;
        end
      end : reader
    join

    // Stop transfers through the block
    write_chan_reg(1 << REG_CHAN_TX_STOP_POS, REG_CHAN_TX_CTRL_ADDR, port);

    total_packets = num_pkts_sent;
  endtask : test_random_packets


  // Test sending and receiving random packets on all ports.
  //
  //   block_timed        : When 1, configure the timestamp queue so that the
  //                        block adds timestamps.
  //   num_bursts         : Number of bursts to send
  //   max_pkts_per_burst : The number of packet in each burst will be in the
  //                        range 1 to this value.
  //   max_pyld_bytes     : The maximum packet payload size in bytes
  //   max_mdata_words    : The maximum metadata size in CHDR words
  //
  task automatic test_random_packets_multi_port(
    bit block_timed = 0,
    int num_bursts = 3,
    int max_pkts_per_burst = 3,
    int max_pyld_bytes = 3*CHDR_BYTES,
    int max_mdata_words = 3
  );
    int num_pkts [NUM_PORTS];
    int total_packets;
    int begin_tx_count, begin_rx_count;
    int end_tx_count, end_rx_count;
    semaphore port_sm = new(0);

    // Get the beginning packet counters
    read_core_reg(begin_tx_count, REG_CORE_TX_PKT_CTR_ADDR);
    read_core_reg(begin_rx_count, REG_CORE_RX_PKT_CTR_ADDR);

    // Kick off multiple threads, and test each port in parallel
    for (int port_count = 0; port_count < NUM_PORTS; port_count++) begin
      fork : port_thread
        // The line below ensures that each thread knows which port it's for
        automatic int port = port_count;
        begin
          test_random_packets(
            .port(port),
            .block_timed(block_timed),
            .num_bursts(num_bursts),
            .max_pkts_per_burst(max_pkts_per_burst),
            .max_pyld_bytes(max_pyld_bytes),
            .max_mdata_words(max_mdata_words),
            .total_packets(num_pkts[port])
          );
          port_sm.put();
        end
      join_none : port_thread
    end

    // Wait until all ports are done
    port_sm.get(NUM_PORTS);

    // Get the ending packet counters
    read_core_reg(end_tx_count, REG_CORE_TX_PKT_CTR_ADDR);
    read_core_reg(end_rx_count, REG_CORE_RX_PKT_CTR_ADDR);

    // Add up the number of packets that were actually sent/received
    foreach (num_pkts[port]) begin
      total_packets += num_pkts[port];
    end

    // Make sure the counters match up
    `ASSERT_ERROR(end_tx_count == begin_tx_count + total_packets, $sformatf(
      "TX packet counter mismatch. Actual %0d, expected %0d",
      end_tx_count, begin_tx_count + total_packets));
    `ASSERT_ERROR(end_rx_count == begin_rx_count + total_packets, $sformatf(
      "RX packet counter mismatch. Actual %0d, expected %0d",
      end_rx_count, begin_rx_count + total_packets));
  endtask : test_random_packets_multi_port


  // Test read-only core register by checking against the expected value.
  //
  //   name     : Name of the register being tested (for logging errors)
  //   addr     : Address of the register to test
  //   expected : The value we expect in the register
  //   core     : Core to test
  //
  task automatic test_ro_core_reg(
    string       name,
    int          addr,
    logic [31:0] expected,
    int          core = 0
  );
    logic [31:0] val;
    read_core_reg(val, addr, core);
    `ASSERT_ERROR(val == expected, $sformatf(
      "Read of %s (Addr %0d, Core %0d) failed. Read 0x%X, expected 0x%X",
      name, addr, core, val, expected));
  endtask


  // Test read/write core register by inverting it and making sure it updates
  // correctly.
  //
  //   name : Name of the register being tested (for logging errors)
  //   addr : Address of the register to test
  //   mask : Bit mask of which bits to test
  //   core : Core to test
  //
  task automatic test_rw_core_reg(
    string       name,
    int          addr,
    logic [31:0] mask,
    int          core = 0
  );
    logic [31:0] val, original, inverted;

    read_core_reg(original, addr, core);
    inverted = (~original) & mask;

    // Disable assertions in the dut to prevent false failures when writing
    // potentially invalid register values.
    $assertoff(0, dut.aurora_flow_control_i);

    write_core_reg(inverted, addr, core);
    read_core_reg(val, addr, core);

    `ASSERT_ERROR(val == inverted, $sformatf(
      "Write of %s (Addr %0d, Core %0d) failed. Read 0x%X, expected 0x%X",
      name, addr, core, val, inverted));

    write_core_reg(original, addr, core);
    read_core_reg(val, addr, core);

    // Re-enable assertions in the dut
    $asserton(0, dut.aurora_flow_control_i);

    `ASSERT_ERROR(val == original, $sformatf(
      "Restore of %s (Addr %0d, Core %0d) failed. Read 0x%X, expected 0x%X",
      name, addr, core, val, original));
  endtask


  // Test read-only channel register by checking against the expected value.
  //
  //   name     : Name of the register being tested (for logging errors)
  //   addr     : Address of the register to test
  //   expected : The value we expect in the register
  //   chan     : Channel on which to test the register
  //   core     : Core to test
  //
  task automatic test_ro_chan_reg(
    string       name,
    int          addr,
    logic [31:0] expected,
    int          chan = 0,
    int          core = 0
  );
    logic [31:0] val;
    read_chan_reg(val, addr, chan, core);
    `ASSERT_ERROR(val == expected, $sformatf(
      "Read of %s (Addr %0d, Chan %0d, Core %0d) failed. Read 0x%X, expected 0x%X",
      name, addr, chan, core, val, expected));
  endtask


  // Test read/write channel register by inverting it and making sure it
  // updates correctly.
  //
  //   name : Name of the register being tested (for logging errors)
  //   addr : Address of the register to test
  //   mask : Bit mask of which bits to test
  //   chan : Channel on which to test the register
  //   core : Core to test
  //
  task automatic test_rw_chan_reg(
    string       name,
    int          addr,
    logic [31:0] mask,
    int          chan = 0,
    int          core = 0
  );
    logic [31:0] val, original, inverted;

    read_chan_reg(original, addr, chan, core);
    inverted = (~original) & mask;

    write_chan_reg(inverted, addr, chan, core);
    read_chan_reg(val, addr, chan, core);

    `ASSERT_ERROR(val == inverted, $sformatf(
      "Write of %s (Addr %0d, Chan %0d, Core %0d) failed. Read 0x%X, expected 0x%X",
      name, addr, chan, core, val, inverted));

    write_chan_reg(original, addr, chan, core);
    read_chan_reg(val, addr, chan, core);

    `ASSERT_ERROR(val == original, $sformatf(
      "Restore of %s (Addr %0d, Chan %0d, Core %0d) failed. Read 0x%X, expected 0x%X",
      name, addr, chan, core, val, original));
  endtask


  //---------------------------------------------------------------------------
  // Tests
  //---------------------------------------------------------------------------

  // Verify the registers are working as expected and match the register
  // definitions. This test assumes that the block was reset so that registers
  // have their default values.
  task automatic test_registers(int core = 0);
    logic [31:0] val;
    test.start_test("Test registers", 100us);

    test_ro_core_reg("REG_COMPAT_ADDR", REG_COMPAT_ADDR,
      dut.COMPAT_NUM, core);

    test_ro_core_reg("REG_CORE_CONFIG_ADDR", REG_CORE_CONFIG_ADDR,
      {16'(NUM_PORTS), 16'(NUM_CORES)}, core);

    test_ro_core_reg("REG_CORE_STATUS_ADDR", REG_CORE_STATUS_ADDR, {
      1'b1,    //    13 REG_PLL_LOCK
      1'b1,    //    12 REG_MMCM_LOCK
      2'b00,   // 11:10 Unused
      1'b0,    //     9 REG_SOFT_ERR
      1'b0,    //     8 REG_HARD_ERR
      3'b000,  //   7:5 Unused
      1'b1,    //     4 REG_LINK_STATUS
      4'b1111  //   3:0 REG_LANE_STATUS
    }, core);

    test_rw_core_reg("REG_CORE_FC_PAUSE_ADDR",
      REG_CORE_FC_PAUSE_ADDR, REG_CORE_FC_PAUSE_RW_MASK, core);

    test_rw_core_reg("REG_CORE_FC_THRESHOLD_ADDR",
      REG_CORE_FC_THRESHOLD_ADDR, REG_CORE_FC_THRESHOLD_RW_MASK, core);

    test_ro_core_reg("REG_CORE_TX_PKT_CTR_ADDR",
      REG_CORE_TX_PKT_CTR_ADDR, 0, core);

    test_ro_core_reg("REG_CORE_RX_PKT_CTR_ADDR",
      REG_CORE_RX_PKT_CTR_ADDR, 0, core);

    test_ro_core_reg("REG_CORE_OVERFLOW_CTR_ADDR",
      REG_CORE_OVERFLOW_CTR_ADDR, 0, core);

    test_ro_core_reg("REG_CORE_CRC_ERR_CTR_ADDR",
      REG_CORE_CRC_ERR_CTR_ADDR, 0, core);

    if (EN_TX_CONTROL) begin
      for (int chan = 0; chan < NUM_PORTS; chan++) begin
        test_rw_chan_reg("REG_CHAN_STOP_POLICY_ADDR",
          REG_CHAN_STOP_POLICY_ADDR, REG_CHAN_STOP_POLICY_RW_MASK, chan, core);

        test_ro_chan_reg("REG_CHAN_TS_QUEUE_STS_ADDR",
          REG_CHAN_TS_QUEUE_STS_ADDR, {16'(TS_QUEUE_DEPTH), 16'd0}, chan, core);

        // Push a timestamp and make sure the status updates
        write_chan_reg(0, REG_CHAN_TS_LOW_ADDR, chan, core);
        write_chan_reg(0, REG_CHAN_TS_HIGH_ADDR, chan, core);
        test_ro_chan_reg("REG_CHAN_TS_QUEUE_STS_ADDR",
          REG_CHAN_TS_QUEUE_STS_ADDR, {16'(TS_QUEUE_DEPTH), 16'd1}, chan, core);

        // Clear the queue and make sure it updates
        write_chan_reg(1 << REG_TS_QUEUE_CTRL_CLR_POS,
          REG_CHAN_TS_QUEUE_CTRL_ADDR, chan, core);
        test_ro_chan_reg("REG_CHAN_TS_QUEUE_STS_ADDR",
          REG_CHAN_TS_QUEUE_STS_ADDR, {16'(TS_QUEUE_DEPTH), 16'd0}, chan, core);
      end
    end

    test.end_test();
  endtask


  // Test resetting the Aurora core and confirm the status registers and
  // link_up update as expected. Note that the monitor_port_info process
  // continuously monitors port_info as well during reset.
  task automatic test_aurora_core_reset();
    logic [31:0] val;

    test.start_test("Aurora core reset", 1ms);

    // Make sure the core is up when we start this test
    read_core_reg(val, REG_CORE_STATUS_ADDR);
    `ASSERT_ERROR(
      val[REG_MMCM_LOCK_POS] == 1 &&
      val[REG_PLL_LOCK_POS] == 1 &&
      val[REG_LINK_STATUS_POS] == 1 &&
      val[REG_LANE_STATUS_POS+:REG_LANE_STATUS_LEN] == {NUM_LANES{1'b1}} &&
      link_up == 1,
      "Core is not fully up before reset test");

    // Reset
    write_core_reg(1 << REG_AURORA_RESET_POS, REG_CORE_RESET_ADDR);

    // Wait for things to go down
    do begin
      read_core_reg(val, REG_CORE_STATUS_ADDR);
    end while (
      val[REG_MMCM_LOCK_POS] != 0 ||
      val[REG_PLL_LOCK_POS] != 0 ||
      val[REG_LINK_STATUS_POS] != 0 ||
      val[REG_LANE_STATUS_POS+:REG_LANE_STATUS_LEN] != 0 ||
      link_up != 0);

    // Wait for things to come back
    do begin
      read_core_reg(val, REG_CORE_STATUS_ADDR);
    end while (
      val[REG_MMCM_LOCK_POS] != 1 ||
      val[REG_PLL_LOCK_POS] != 1 ||
      val[REG_LINK_STATUS_POS] != 1 ||
      val[REG_LANE_STATUS_POS+:REG_LANE_STATUS_LEN] != {NUM_LANES{1'b1}} ||
      link_up != 1);

    test.end_test();
  endtask


  // Test passing packets through unmodified (no timestamp handling). This
  // tests all ports simultaneously using randomly generated packets. It
  // iterates through different levels of back-pressure.
  //
  //   num_bursts : Number of bursts to simulate
  //
  task automatic test_packet_pass_through(int num_bursts = NUM_BURSTS);
    foreach (stall_probs[idx]) begin
      // Set the stall probability of the BFM
      for (int ch = 0; ch < NUM_PORTS; ch++) begin
        blk_ctrl.set_master_stall_prob(ch, stall_probs[idx].master);
        blk_ctrl.set_slave_stall_prob(ch, stall_probs[idx].slave);
      end

      test.start_test($sformatf(
        "Test random packets (pass through, %0d, %0d)",
        stall_probs[idx].master, stall_probs[idx].slave), 1ms);
      test_random_packets_multi_port(.block_timed(0), .num_bursts(num_bursts));
      test.end_test();
    end
  endtask


  // Test using the Aurora TX Control module to handle timestamp generation.
  // This tests all ports simultaneously using randomly generated packets. It
  // iterates through different levels of back-pressure.
  //
  //   num_bursts : Number of bursts to simulate
  //
  task automatic test_packets_block_timed(int num_bursts = NUM_BURSTS);
    int bursts_left;
    int bursts_this_iter;

    foreach (stall_probs[idx]) begin
      bursts_left = num_bursts;

      // Set the stall probability of the BFM
      for (int ch = 0; ch < NUM_PORTS; ch++) begin
        blk_ctrl.set_master_stall_prob(ch, stall_probs[idx].master);
        blk_ctrl.set_slave_stall_prob(ch, stall_probs[idx].slave);
      end

      test.start_test($sformatf(
        "Test random packets (block-timed, %0d, %0d)",
        stall_probs[idx].master, stall_probs[idx].slave), 1ms);
      while (bursts_left > 0) begin
        bursts_this_iter = `MIN(TS_QUEUE_DEPTH, bursts_left);
        test_random_packets_multi_port(.block_timed(1), .num_bursts(bursts_this_iter));
        bursts_left -= bursts_this_iter;
      end
      test.end_test();
    end
  endtask


  // Test that the activity indicator toggles when data flows through.
  //
  //   port       : Port on which to send the packets
  //   core       : Core to use
  //
  task automatic test_activity_led(int port = 0, int core = 0);
    chdr_pkt_t sent_pkt, rcvd_pkt, exp_pkt;
    int begin_count, end_count;

    test.start_test("Test activity LED", 1ms);

    if (EN_TX_CONTROL) begin
      // Enable transfers
      write_chan_reg(1 << REG_CHAN_TX_START_POS, REG_CHAN_TX_CTRL_ADDR, port, core);
    end

    // It's hard to know in general, which LED will toggle, so we'll just take
    // the sum of all of them. If one toggles, then the sum should go up.
    foreach (act_count[core]) begin_count += act_count[core];

    sent_pkt = gen_chdr_packet();
    sent_pkt.header.eob = 1'b1;
    exp_pkt = gen_expected_pkt(sent_pkt, port);
    blk_ctrl.put_chdr(port, sent_pkt);
    blk_ctrl.get_chdr(port, rcvd_pkt);
    if (!exp_pkt.equal(rcvd_pkt)) begin
      $display("Expected Packet:");
      exp_pkt.print();
      $display("Received Packet:");
      rcvd_pkt.print();
      `ASSERT_ERROR(0, "Received packet doesn't match expected");
    end

    foreach (act_count[core]) end_count += act_count[core];

    // Did the LED toggle?
    `ASSERT_ERROR(end_count > begin_count, "Activity LED did not toggle");

    // Stop transfers through the block
    write_chan_reg(1 << REG_CHAN_TX_STOP_POS, REG_CHAN_TX_CTRL_ADDR, port, core);

    test.end_test();
  endtask


  // Test that the link indicator updates when the link goes down and comes
  // back up. This also confirms that the link goes down when the cable is
  // disconnected and automatically comes back when the cable is reconnected.
  //
  //   port       : Port on which to send the packets
  //   core       : Core to use
  //
  task automatic test_link_status(int port = 0, int core = 0);
    chdr_pkt_t sent_pkt, rcvd_pkt;
    int begin_count, end_count;

    test.start_test("Test link status", 1ms);

    `ASSERT_ERROR(link_up != 0, "Link is not up at start of link test");

    // Disable the loopback
    loopback_en = 1'b0;

    // Wait for the link to drop
    wait (link_up == 0);

    // Reconnect the loopback
    loopback_en = 1'b1;

    // Wait for the link to come back
    wait (link_up !== 0);

    test.end_test();
  endtask


  // Test that packets with CRC errors are correctly dropped.
  //
  //   num_pkts   : Number of packets to send through
  //   error_rate : probability with which to induce errors
  //   port       : Port on which to send the packets
  //   core       : Core to use
  //
  task automatic test_crc_errors(
    int  num_pkts = 100,
    real error_rate = 0.5,
    int  port = NUM_PORTS-1,
    int  core = 0
  );
    chdr_pkt_t sent_pkt, rcvd_pkt, exp_pkt;
    int begin_err_count, end_err_count;
    int num_good_pkts = num_pkts;
    mailbox #(chdr_pkt_t) exp_pkts_mb = new();

    // Track whether each packet will have a CRC error. 0 means it's a good
    // packet and 1 means it will be a bad packet.
    bit pkt_error [] = new [num_pkts];

    test.start_test("Test CRC errors", 1ms);

    if (EN_TX_CONTROL) begin
      // Enable transfers
      write_chan_reg(1 << REG_CHAN_TX_START_POS, REG_CHAN_TX_CTRL_ADDR, port, core);
    end
    read_core_reg(begin_err_count, REG_CORE_CRC_ERR_CTR_ADDR, core);

    // Queue up the packets
    foreach (pkt_error[idx]) begin
      // Randomly decide if this packet will have a CRC error
      pkt_error[idx] = $urandom_range(999)/1000.0 < error_rate;
      num_good_pkts -= pkt_error[idx];
      sent_pkt = gen_chdr_packet();
      exp_pkts_mb.put(gen_expected_pkt(sent_pkt, port));
      blk_ctrl.put_chdr(port, sent_pkt);
    end

    // Randomly induce CRC errors
    foreach (pkt_error[idx]) begin
      if (pkt_error[idx]) begin
        // Wait for the packet to start
        forever begin
          @(posedge dut.aurora_clk);
          if (from_aurora_sop) break;
        end
        // Make the CRC fail
        dut.a_sim_crc_pass <= 1'b0;
      end
      // Wait for the packet to end
      forever begin
        @(posedge dut.aurora_clk);
        if (from_aurora_eop) break;
      end
      dut.a_sim_crc_pass <= 1'b1;
    end

    // Fetch and verify the output packets
    foreach (pkt_error[idx]) begin
      exp_pkts_mb.get(exp_pkt);

      // We only expect to receive the packet back if it did not have a CRC
      // error.
      if (!pkt_error[idx]) begin
        blk_ctrl.get_chdr(port, rcvd_pkt);
        if (!exp_pkt.equal(rcvd_pkt)) begin
          $display("Expected Packet:");
          exp_pkt.print();
          $display("Received Packet:");
          rcvd_pkt.print();
          `ASSERT_ERROR(0, $sformatf(
            "Received packet %0d does not match expected", idx));
        end
      end
    end

    read_core_reg(end_err_count, REG_CORE_CRC_ERR_CTR_ADDR, core);
    `ASSERT_ERROR(end_err_count > begin_err_count,
      "CRC error counter did not increase");
    `ASSERT_ERROR(end_err_count == begin_err_count + (num_pkts - num_good_pkts),
      "CRC error count doesn't match expected value");

    // Reset the TX datapath logic to put it back in a good state
    write_core_reg(1 << REG_TX_DATAPATH_RESET_POS, REG_CORE_RESET_ADDR, core);

    test.end_test();
  endtask


  // Run a test that creates enough back-pressure to cause the flow-control
  // system to engage. This works by blocking data flow then sending packets
  // until the input stalls. Then we send through an additional num_pkts.
  //
  //   num_pkts : Number of packets to send through after the data pipe is full
  //   port     : Port on which to send the packets
  //   core     : Core to use
  //
  task automatic test_flow_control(
    int  num_pkts = 100,
    int  pause_count = 0,
    int  port = NUM_PORTS-1,
    int  core = 0
  );
    int send_count, recv_count;
    int stall_count;
    chdr_pkt_t sent_pkt, rcvd_pkt, exp_pkt;
    localparam int STALL_CYCLES = 100;
    mailbox #(chdr_pkt_t) exp_pkts_mb = new();

    test.start_test("Test flow control", 1ms);

    // Make the input fast
    blk_ctrl.set_master_stall_prob(port, 0);

    // Disable packet flow and buffer all input packets. If EN_TX_CONTROL is
    // available, use that to stall traffic. If not, use the BFM.
    if (EN_TX_CONTROL) begin
      write_chan_reg(TX_POLICY_BUFFER, REG_CHAN_STOP_POLICY_ADDR, port, core);
      write_chan_reg(1 << REG_CHAN_TX_STOP_POS, REG_CHAN_TX_CTRL_ADDR, port, core);
    end else begin
      blk_ctrl.set_slave_stall_prob(port, 100);
    end
    write_core_reg(pause_count, REG_CORE_FC_PAUSE_ADDR);

    // Queue enough packets to cause the input to stall
    while (stall_count < STALL_CYCLES) begin
      sent_pkt = gen_chdr_packet(.pkt_count(send_count));
      exp_pkts_mb.put(gen_expected_pkt(sent_pkt, port));
      blk_ctrl.put_chdr(port, sent_pkt);
      send_count++;

      // Wait until the input stalls or the packet is fully sent
      forever begin
        @(posedge rfnoc_chdr_clk);
        if ((s_rfnoc_chdr_tvalid[port] && s_rfnoc_chdr_tready[port] &&
          s_rfnoc_chdr_tlast[port]) ||
          !s_rfnoc_chdr_tready[port])
          break;
      end

      // If we've stalled, then wait to see if the stall lasts longer than
      // STALL_CYCLES. If so, we assume the input is really stalled.
      stall_count = 0;
      while (s_rfnoc_chdr_tready[port] == 1'b0) begin
        @(posedge rfnoc_chdr_clk);
        stall_count++;
        if (stall_count >= STALL_CYCLES) break;
      end
    end

    if (VERBOSE) $display("Sent %0d packets before stalling", send_count);

    // Queue up num_pkts in addition to what was already sent
    for (int pkt_cnt = 0; pkt_cnt < num_pkts; pkt_cnt++) begin
      if (pkt_cnt == num_pkts - 1) begin
        // Last packet should be EOB
        sent_pkt = gen_chdr_packet(.pkt_count(send_count), .eob(1));
      end else begin
        sent_pkt = gen_chdr_packet(.pkt_count(send_count));
      end
      exp_pkts_mb.put(gen_expected_pkt(sent_pkt, port));
      blk_ctrl.put_chdr(port, sent_pkt);
      send_count++;
    end

    // Let data flow through slowly
    blk_ctrl.set_slave_stall_prob(port, 5);
    if (EN_TX_CONTROL) begin
      write_chan_reg(1 << REG_CHAN_TX_START_POS, REG_CHAN_TX_CTRL_ADDR, port, core);
    end

    // Fetch and verify the output packets
    repeat (send_count) begin
      exp_pkts_mb.get(exp_pkt);
      blk_ctrl.get_chdr(port, rcvd_pkt);
      `ASSERT_ERROR(exp_pkt.equal(rcvd_pkt),
        "Received packet doesn't match expected");
      if (VERBOSE) begin
        $display("Received packet %0d out of %0d", recv_count++, send_count);
      end
    end

    // Restore stall rates
    blk_ctrl.set_master_stall_prob(port, STALL_PROB);
    blk_ctrl.set_slave_stall_prob(port, STALL_PROB);

    test.end_test();
  endtask


  //---------------------------------------------------------------------------
  // Main Test Process
  //---------------------------------------------------------------------------

  initial begin : tb_main
    string tb_name;

    // Generate a string for the name of this instance of the testbench
    tb_name = $sformatf({
      "rfnoc_block_aurora_tb\n",
      "\tCHDR_W    = %0d\n",
      "\tNUM_PORTS = %0d"},
      CHDR_W,
      NUM_PORTS
    );

    // Initialize the test exec object for this testbench
    test.start_tb(tb_name);

    // Start the clocks
    rfnoc_chdr_clk_gen.start();
    rfnoc_ctrl_clk_gen.start();
    refclk_gen.start();
    dclk_gen.start();

    // Start the BFMs running
    blk_ctrl.run();

    //--------------------------------
    // Block Reset
    //--------------------------------

    test.start_test("Flush block then reset it", 100us);
    blk_ctrl.flush_and_reset();

    // Make sure the link comes up
    wait (link_up == 1);
    test.end_test();

    //--------------------------------
    // Verify Block Info
    //--------------------------------

    test.start_test("Verify Block Info", 1us);
    `ASSERT_ERROR(blk_ctrl.get_noc_id()     == 32'hA404A000, "Incorrect NOC_ID Value");
    `ASSERT_ERROR(blk_ctrl.get_num_data_i() == NUM_PORTS_I,  "Incorrect NUM_DATA_I Value");
    `ASSERT_ERROR(blk_ctrl.get_num_data_o() == NUM_PORTS_O,  "Incorrect NUM_DATA_O Value");
    `ASSERT_ERROR(blk_ctrl.get_mtu()        == CHDR_MTU,     "Incorrect MTU Value");
    test.end_test();

    //--------------------------------
    // Test Sequences
    //--------------------------------

    test_registers();
    test_activity_led();
    test_link_status();
    test_crc_errors();
    test_flow_control();
    test_flow_control(.pause_count(100));
    test_packet_pass_through();
    if (EN_TX_CONTROL) test_packets_block_timed();
    test_aurora_core_reset();
    test_packet_pass_through(1);  // Run a simple test after reset

    //--------------------------------
    // Finish Up
    //--------------------------------

    // Display final statistics and results
    test.end_tb(0);

    // Stop new clock events
    rfnoc_chdr_clk_gen.kill();
    rfnoc_ctrl_clk_gen.kill();
    refclk_gen.kill();
    dclk_gen.kill();

  end

endmodule : rfnoc_block_aurora_tb


`default_nettype wire
