//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: aurora_flow_control_tb.sv
//
// Description:
//
// This module is a testbench for the aurora_flow_control module.
//

`default_nettype none

module aurora_flow_control_tb;

  // Include macros and time declarations for use with PkgTestExec
  `include "test_exec.svh"

  import PkgTestExec::*;
  import PkgAxiStreamBfm::*;
  import PkgComplex::*;
  import PkgMath::*;
  import PkgRandom::*;


  //---------------------------------------------------------------------------
  // Local parameters
  //---------------------------------------------------------------------------
  localparam int DATA_WIDTH = 32;
  localparam int MAX_PKT_SIZE_WORDS = 1024;
  localparam int CLK_PERIOD = 10;
  localparam int BURST_LEN = 10;

  localparam int NFC_DELAY = 64;
  localparam int NFC_PAUSE_COUNT = 100;
  localparam int NFC_PAUSE_THRESHOLD = 128;
  localparam int NFC_RESUME_THRESHOLD = 192;


  //---------------------------------------------------------------------------
  // Local typedefs
  //---------------------------------------------------------------------------
  // Packet type for AXI-Stream interface: 256-bit data, no user data,
  typedef AxiStreamPacket#(
    .DATA_WIDTH(DATA_WIDTH),
    .USER_WIDTH(1)
  ) axis_pkt_t;
  typedef axis_pkt_t axis_pkt_queue_t[$];


  //---------------------------------------------------------------------------
  // Local signals
  //---------------------------------------------------------------------------
  logic        clk;
  logic        rst;

  // Flow control interface to Aurora
  logic        m_axi_nfc_tvalid;
  logic [15:0] m_axi_nfc_tdata;
  logic        m_axi_nfc_tready;
  logic        stall_transmission;
  logic        fc_buffer_overflow;
  int          current_stall_prob = 0;

  // CRC signals
  logic        i_crc_pass = '1;
  logic        crc_valid_enable = '1;
  logic        i_crc_valid;
  logic        crc_error_indicator;
  // Assign the crc_valid signal to the tlast signal. As per PG074, the CRC
  // valid signal of the Aurora IP should always coincide with tlast.
  assign i_crc_valid = crc_valid_enable & to_dut.tlast;

  // NFC configuration signals
  logic       nfc_sim_enable = '1;
  logic [7:0] nfc_pause_count;
  logic       latch_buffer_overflow = '0;

  //---------------------------------------------------------------------------
  // Clocking and Reset
  //---------------------------------------------------------------------------
  sim_clock_gen #(CLK_PERIOD) clk_gen (
    clk,
    rst
  );

  //---------------------------------------------------------------------------
  // AXI-Stream BFM
  //---------------------------------------------------------------------------

  // AXI-Stream interfaces to/from DUT
  AxiStreamIf #(
    .DATA_WIDTH(DATA_WIDTH)
  ) to_dut (
    .clk(clk),
    .rst(rst)
  );
  AxiStreamIf #(
    .DATA_WIDTH(DATA_WIDTH)
  ) from_dut (
    .clk(clk),
    .rst(rst)
  );

  // BFM for the AXI-Stream interface to DUT
  AxiStreamBfm #(.DATA_WIDTH(DATA_WIDTH)) axis_bfm = new(to_dut, from_dut);


  //---------------------------------------------------------------------------
  // Instantiate the aurora_flow_control module
  //---------------------------------------------------------------------------
  aurora_flow_control #(
    .DATA_WIDTH(DATA_WIDTH),
    .MAX_PKT_SIZE_WORDS(MAX_PKT_SIZE_WORDS)
  ) aurora_flow_control_inst (
    .clk(clk),
    .rst(rst),
    .nfc_pause_count(nfc_pause_count),
    .nfc_pause_thresh(8'(NFC_PAUSE_THRESHOLD)),
    .nfc_resume_thresh(8'(NFC_RESUME_THRESHOLD)),
    .i_tdata(to_dut.tdata),
    .i_tkeep(to_dut.tkeep),
    .i_tvalid(to_dut.tvalid),
    .i_tlast(to_dut.tlast),
    .i_crc_pass(~(to_dut.tuser[0])),
    .i_crc_valid(i_crc_valid),
    .o_tdata(from_dut.tdata),
    .o_tkeep(from_dut.tkeep),
    .o_tvalid(from_dut.tvalid),
    .o_tlast(from_dut.tlast),
    .o_tready(from_dut.tready),
    .m_axi_nfc_tvalid(m_axi_nfc_tvalid),
    .m_axi_nfc_tdata(m_axi_nfc_tdata),
    .m_axi_nfc_tready(m_axi_nfc_tready),
    .fc_overflow_stb(fc_buffer_overflow),
    .crc_error_stb(crc_error_indicator)
  );

  // Instantiate helper modules for simulation
  nfc_sim_fsm #(
    .NFC_DELAY(NFC_DELAY)
  ) nfc_sim_fsm_i (
    .clk(clk),
    .rst(rst),
    .s_axi_nfc_tvalid(m_axi_nfc_tvalid),
    .s_axi_nfc_tdata(m_axi_nfc_tdata),
    .s_axi_nfc_tready(m_axi_nfc_tready),
    .stall_transmission(stall_transmission)
  );

  //---------------------------------------------------------------------------
  // Helper functions/tasks
  //---------------------------------------------------------------------------
  //  Assert the DUT reset asynchronously and deassert it synchronously after 4
  //  clock cycles to ensure that the DUT is in a known state before starting
  //  the test. The DUT is assumed to be fully reset and ready for input when
  //  the reset signal is deasserted.
  task automatic reset_dut();
    clk_gen.reset(4);
    @(negedge clk_gen.rst);
  endtask

  //  Generate a random AXI-Stream packet consisting of a number of words of 
  //  width pkt_len. The packet is generated with completely random data.
  //  If pkt_len is less than or equal to 0, a random number of words is
  //  generated between 1 and MAX_PKT_SIZE_WORDS.
  //  if crc_fail is set, the user field of the packet is set to 1 for all of 
  //  the corresponding words in the packet. Otherwise, the user field is set to 0.
  //  The user field is used to indicate whether the packet has a CRC failure
  //  or not for CRC miss simulation purposes.
  //  The function returns the generated packet.
  function automatic axis_pkt_t gen_rand_data_axi_pkt(int pkt_len,
                                                      bit crc_fail = 0);
    axis_pkt_t packet;
    int num_words = 0;
    // Generate a packet with random data of length pkt_len
    packet = new();
    num_words = pkt_len;
    if (pkt_len <= 0) begin
      num_words = $urandom_range(1, MAX_PKT_SIZE_WORDS);
    end
    //generate random data blocks and add to packet
    repeat (num_words) begin
      packet.data.push_back(Rand#(DATA_WIDTH)::rand_logic());
      packet.keep.push_back(Rand#(DATA_WIDTH / 8)::rand_logic());
      if (crc_fail) begin
        packet.user.push_back('1);
      end else begin
        packet.user.push_back('0);
      end
    end
    return packet;
  endfunction

  //  Generate a burst of packets with random data of length pkt_len. The
  //  number of packets in the burst is specified by num_pkts. If crc_fails
  //  is set, a random number of packets in the burst will have CRC failures.
  //  The function returns the generated burst of packets.
  function automatic axis_pkt_queue_t gen_rand_pkt_burst(
    int num_pkts, int pkt_len, bit crc_fails = 0);
    axis_pkt_queue_t pkt_burst;
    // Generate a burst of packets with random data of length pkt_len
    repeat (num_pkts) begin
      // If crc_fails is set, inject CRC failures into a random number of packets.
      if (crc_fails) begin
        pkt_burst.push_back(gen_rand_data_axi_pkt(pkt_len, $urandom_range(1)));
      end else begin
        pkt_burst.push_back(gen_rand_data_axi_pkt(pkt_len));
      end
    end
    return pkt_burst;
  endfunction

  //  Generate the expected burst of packets, based on the given input burst.
  //  The function takes the input burst and adds them to the expected burst
  //  while removing the packets with CRC failures.
  //  The function returns the expected burst of packets.
  function automatic axis_pkt_queue_t gen_expected_pkt_burst(
    axis_pkt_queue_t pkt_burst);
    axis_pkt_queue_t expected_pkt_burst;
    // Generate the expected burst of packets, which should be the same as the input burst
    foreach (pkt_burst[idx]) begin
      if (pkt_burst[idx].user[0] == 0) begin
        axis_pkt_t pkt = pkt_burst[idx].copy();
        pkt.user = {};
        expected_pkt_burst.push_back(pkt);
      end
    end
    return expected_pkt_burst;
  endfunction

  //  The task takes the input burst and generates the expected burst using
  //  gen_expected_pkt_burst(). The task waits for the DUT to finish 
  //  processing the input burst and then verifies the output of the DUT against
  //  the expected burst.
  task automatic verify_dut_output(axis_pkt_queue_t input_pkt_burst);
    axis_pkt_queue_t expected_pkt_burst = gen_expected_pkt_burst(
      input_pkt_burst
    );
    axis_pkt_queue_t dut_outputs;
    axis_pkt_t dut_pkt;
    int timeout = 0;
    // Wait for the DUT to finish processing the burst
    // DUT is assumed to be finished when the output queue is empty for the
    // duration of three full packets( to wait during testcases with high stall prob).
    while (timeout < 3 * MAX_PKT_SIZE_WORDS) begin
      // See if still packets in the output queue, if so, reset the timeout.
      if (axis_bfm.try_get(dut_pkt)) begin
        dut_outputs.push_back(dut_pkt);
        timeout = 0;
      end else if (from_dut.tvalid && from_dut.tready) begin
        // If the dut is still active, reset timeout
        timeout = 0;
      end else begin
        timeout++;
      end
      clk_gen.clk_wait_r();
    end
    // Check if the number of packets received matches the number of packets sent,
    // then verify the packets.
    `ASSERT_ERROR(dut_outputs.size() == expected_pkt_burst.size(),
                  $sformatf("Expected %0d packets but received %0d packets",
                            expected_pkt_burst.size(), dut_outputs.size()))
    $display("\nReceived %0d packets", dut_outputs.size());
    // Verify that the packet burst matches the expected packet burst
    foreach (expected_pkt_burst[idx]) begin
      // Get the received packet from the DUT and compare it with the expected packet
      axis_pkt_t received_pkt = dut_outputs.pop_front();
      received_pkt.user = {};
      `ASSERT_ERROR(expected_pkt_burst[idx].equal(received_pkt), $sformatf(
                    "\nExpected Packet: %s\nReceived Packet: %s \nPacket mismatch detected",
                    expected_pkt_burst[idx].sprint(),
                    received_pkt.sprint(),
                    idx
                    ));
    end

  endtask

  //  This task generates a burst of packets with random data of length pkt_len
  //  and sends them to the DUT by queueing up the packets to the BFM. The
  //  task internally generates the burst using gen_rand_pkt_burst() to generate
  //  the input burst.
  task automatic send_burst_to_dut(int num_pkts, int pkt_len,
                                   bit crc_fails = 0,
                                   output axis_pkt_queue_t input_burst);
    input_burst = gen_rand_pkt_burst(num_pkts, pkt_len, crc_fails);
    // Send the packets in burst to the DUT
    foreach (input_burst[idx]) begin
      axis_bfm.put(input_burst[idx]);
    end
  endtask

  //---------------------------------------------------------------------------
  // Testbench logic
  //---------------------------------------------------------------------------

  // Test for flow control
  // This test is used to check if the DUT correctly handles flow control
  // signals and to verify that the DUT correctly processes packets with
  // different flow control settings. The test sends a burst of packets with
  // random data and verifies that the DUT correctly processes the packets
  // under different stall conditions for both input and output stalls.
  // For high output stall probabilities, the test also checks the two different
  // modes of the NFC module: Xoff/StartStop and Pause. The test also checks for buffer
  task automatic test_flow_control(int burst_len = BURST_LEN, int pkt_len = -1,
                                   bit crc_fails = 0);
    //Setup test conditions:
    // Iterate over different flow control settings to exercise different
    // scenarios.
    axis_pkt_queue_t input_burst;
    nfc_pause_count = 8'(NFC_PAUSE_COUNT);
    for (int bfm_config = 0; bfm_config < 6; bfm_config++) begin
      case (bfm_config)
        0: begin
          // No stalls: on input or output to DUT
          axis_bfm.set_master_stall_prob(0);
          axis_bfm.set_slave_stall_prob(0);
          $display("\nTestcase: No stalls");
        end
        1: begin
          // Overflow: Input to DUT faster than output
          axis_bfm.set_master_stall_prob(10);
          axis_bfm.set_slave_stall_prob(30);
          $display(
            "\nTestcase: DUT input faster than output=> Stall prob. 10:30");
        end
        2: begin
          // Underflow: Input to DUT slower than output
          axis_bfm.set_master_stall_prob(30);
          axis_bfm.set_slave_stall_prob(10);
          $display(
            "\nTestcase: DUT output faster than input=> Stall prob. 30:10");
        end
        3: begin
          // Lots of stalls: Input and output stall frequently
          axis_bfm.set_master_stall_prob(40);
          axis_bfm.set_slave_stall_prob(40);
          $display("\nTestcase: Lots of stalls=> Stall prob. 40:40");
        end
        4: begin
          // Random stalls: Random stalls on output
          axis_bfm.set_master_stall_prob(0);
          axis_bfm.set_slave_stall_prob(90);
          $display("\nTestcase: No Stalls on input=> Stall prob. 0:90");
        end
        5: begin
          // Random stalls: Random stalls on input
          axis_bfm.set_master_stall_prob(0);
          axis_bfm.set_slave_stall_prob(90);
          nfc_pause_count = '0;
          $display("\nTestcase: No Stalls on input=> Stall prob. 90:0");
          $display("\n Use NFC Xoff Stop mode.");
        end
      endcase
      // Send a burst of packets to the DUT
      send_burst_to_dut(BURST_LEN, -1, crc_fails, input_burst);
      // Wait for the DUT to finish processing the burst
      axis_bfm.wait_complete();
      // Verify the output of the DUT
      verify_dut_output(input_burst);
      if (nfc_sim_enable) begin
        `ASSERT_ERROR(latch_buffer_overflow == '0, "Buffer overflow detected");
      end
      $display("\nTestcase passed - No errors detected");
      clk_gen.clk_wait_r(10);
    end
  endtask

  // Test for CRC mismatch
  // This test is used to check if the DUT correctly drops packets with CRC
  // mismatches. The test sends a burst of packets with random data and sets the
  // user field of some packets to 1 to indicate a CRC failure. The test then
  // verifies that the DUT drops the packets with CRC failures and only
  // processes the packets with valid CRCs.
  task automatic test_crc_missmatch();
    test_flow_control(.crc_fails(1));
  endtask

  // Test for maximum packet length
  // This test is used to check if the a burst of packets of maximum packet
  // length is handled correctly by the DUT.
  task automatic test_max_packet_len();
    test_flow_control(.pkt_len(MAX_PKT_SIZE_WORDS));
  endtask

  // Test for buffer overflow
  // This test is used to check the buffer overflow detection logic and to
  // make sure that the corrupted packets are dropped correctly.
  // For this test, we turn off flow control simulation, and send a single 
  // packet that is larger than the buffer size. The test checks if the buffer
  // overflow detection logic is triggered and the packet is dropped.
  task automatic test_buffer_overflow();
    axis_pkt_queue_t input_burst;
    axis_pkt_t pkt;
    int timeout = 0;
    // Disable the NFC simulation to induce buffer overflow.
    nfc_sim_enable  = '0;
    // Disable buffer overflow detection in the DUT for this test.
    aurora_flow_control_inst.disable_buffer_overflow_assertion = '1;
    // Set up the stall probability to 100% to simulate the NFC module pausing
    // transmission of packets to the DUT.
    nfc_pause_count = 8'(NFC_PAUSE_COUNT);
    axis_bfm.set_master_stall_prob(0);
    axis_bfm.set_slave_stall_prob(100);

    // Send a a single-packet burst to the DUT
    send_burst_to_dut(1, 10 * MAX_PKT_SIZE_WORDS, 0, input_burst);

    // Wait for the DUT to finish processing the burst
    axis_bfm.wait_complete();
    `ASSERT_ERROR(latch_buffer_overflow == '1,
                  "Buffer overflow not detected, but expected!");

    // Wait for the DUT to finish processing the burst
    // We are expecting a timeout here as the as the overflowed corrupted packet
    // should be dropped.
    while (timeout < 3 * MAX_PKT_SIZE_WORDS) begin
      // See if still packets in the output queue, if so, reset the timeout.
      if (from_dut.tvalid && from_dut.tready) begin
        // If the dut is still active, reset timeout
        timeout = 0;
      end else begin
        timeout++;
      end
      clk_gen.clk_wait_r();
    end

    // Check if the packet was correctly dropped.
    `ASSERT_ERROR(axis_bfm.try_get(pkt) == 0,
                  "Expected packet to be dropped, but received a packet!");
    // Reset dut to clear buffers.
    reset_dut();

    // Re-enable buffer overflow detection in the DUT and testbench.
    aurora_flow_control_inst.disable_buffer_overflow_assertion = '0;
    nfc_sim_enable = '1;
  endtask

  initial begin

    // Initialize the test exec object for this testbench
    test.start_tb("aurora_flow_control_tb");

    // Reset
    reset_dut();

    // Start the BFM
    axis_bfm.run();

    test.start_test("Run Aurora Flow Control TB");
    // Run the test
    test_flow_control();

    test.end_test();

    // Test the CRC mismatch case
    test.start_test("Run Aurora Flow Control TB with CRC mismatch");

    test_crc_missmatch();

    test.end_test();

    // Test the max packet length case
    test.start_test("Run Aurora Flow Control TB with max packet length");

    test_max_packet_len();

    test.end_test();

    // Test the buffer overflow case
    test.start_test("Run Aurora Flow Control TB with buffer overflow");
    test_buffer_overflow();
    test.end_test();

    // End the test
    test.end_tb();
  end

  //---------------------------------------------------------------------------
  // Simulate Aurora Native Flow Control(NFC) logic
  //---------------------------------------------------------------------------
  // After some delay(NFC_DELAY), the NFC module pauses the transmission of
  // packets to the DUT. I am simulating this by setting the stall probability 
  // to 100 for nfc_idle_cycles cycles.

  always @(posedge stall_transmission) begin
    // Set the stall probability to 100% to simulate the NFC module pausing
    // transmission of packets to the DUT.
    current_stall_prob = axis_bfm.get_master_stall_prob();
    // Disable, to induce buffer overflow.
    if (nfc_sim_enable) begin
      axis_bfm.set_master_stall_prob(100);
    end
  end

  always @(negedge stall_transmission) begin
    axis_bfm.set_master_stall_prob(current_stall_prob);
  end

  // Check for buffer overflow
  always_latch begin : buffer_overflow_check
    if (!rst && fc_buffer_overflow) begin
      latch_buffer_overflow <= '1;
    end
  end

endmodule

`default_nettype wire
