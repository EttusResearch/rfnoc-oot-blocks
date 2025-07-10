//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: aurora_tx_control_tb
//
// Description:
//
//   This is the testbench for Aurora block aurora_tx_control module.
//
//   It primarily tests the FSM states of the module, and covers all possible
//   state transitions.
//

`default_nettype none


module aurora_tx_control_tb #(
  parameter int CHDR_W = 512,
  parameter int ITEM_W = 32
);

  `include "usrp_utils.svh"
  `include "test_exec.svh"

  import PkgTestExec::*;
  import rfnoc_chdr_utils_pkg::*;
  import PkgChdrBfm::*;
  import PkgRandom::*;
  import ctrlport_pkg::*;
  import ctrlport_bfm_pkg::*;

  import aurora_regs_pkg::*;


  //---------------------------------------------------------------------------
  // Test Parameters
  //---------------------------------------------------------------------------

  localparam real CHDR_CLK_PER = 5.0;  // 200 MHz
  localparam int MIN_PYLD_SIZE = 1;
  localparam int MAX_PYLD_SIZE = CHDR_W / 8 * 16;
  localparam int MIN_MDATA_SIZE = 0;
  localparam int MAX_MDATA_SIZE = 3;
  localparam int MIN_BURST_SIZE = 1;
  localparam int MAX_BURST_SIZE = 32;
  localparam int MIN_NUM_BURSTS = 5;
  localparam int MAX_NUM_BURSTS = 16;

  localparam int STALL_PROB_DEF = 38;
  localparam int STALL_PROB_HIGH = 90;
  localparam int STALL_PROB_LOW = 10;
  localparam int TIMEOUT_MAX = 100;  // Based on max possible stall prob = 99

  localparam int TS_QUEUE_DEPTH = 5;


  //---------------------------------------------------------------------------
  // Type Definitions
  //---------------------------------------------------------------------------

  typedef ChdrPacket#(.CHDR_W(CHDR_W)) chdr_pkt_t;
  typedef chdr_pkt_t chdr_pkt_queue_t[$];
  typedef chdr_pkt_queue_t chdr_burst_queue_t[$];
  typedef mailbox#(chdr_pkt_t) chdr_pkt_mb_t;

  typedef chdr_timestamp_t chdr_ts_queue_t[$];
  typedef chdr_ts_queue_t chdr_ts_burst_queue_t[$];
  typedef mailbox#(chdr_timestamp_t) chdr_ts_mb_t;


  //---------------------------------------------------------------------------
  // Local Signals
  //---------------------------------------------------------------------------

  // Clock and Reset
  logic rfnoc_chdr_clk;
  logic rfnoc_chdr_rst;


  //---------------------------------------------------------------------------
  // Clocking and Reset
  //---------------------------------------------------------------------------

  sim_clock_gen #(
    .PERIOD   (CHDR_CLK_PER),
    .AUTOSTART(0)
  ) clk_gen (
    .clk(rfnoc_chdr_clk),
    .rst(rfnoc_chdr_rst)
  );


  //---------------------------------------------------------------------------
  // Bus Functional Models
  //---------------------------------------------------------------------------

  // AXI Stream interface for the DUT inputs
  AxiStreamIf #(
    .DATA_WIDTH(CHDR_W)
  ) to_dut (
    .clk(rfnoc_chdr_clk),
    .rst(rfnoc_chdr_rst)
  );

  // AXI Stream interface for the DUT output
  AxiStreamIf #(
    .DATA_WIDTH(CHDR_W)
  ) from_dut (
    .clk(rfnoc_chdr_clk),
    .rst(rfnoc_chdr_rst)
  );

  // Control Port interface
  ctrlport_if ctrlport_if (
    .clk(rfnoc_chdr_clk),
    .rst(rfnoc_chdr_rst)
  );

  // CHDR BFM
  ChdrBfm #(.CHDR_W(CHDR_W)) chdr_bfm = new(to_dut, from_dut);

  // Control Port BFM
  ctrlport_bfm reg_bfm = new(ctrlport_if);

  // Optional control port signal
  assign ctrlport_if.resp.status = STS_OKAY;


  //---------------------------------------------------------------------------
  // DUT Instantiation
  //---------------------------------------------------------------------------

  aurora_tx_control #(
    .CHDR_W(CHDR_W),
    .TS_QUEUE_DEPTH(TS_QUEUE_DEPTH)
  ) dut (
    .rfnoc_chdr_clk(rfnoc_chdr_clk),
    .rfnoc_chdr_rst(rfnoc_chdr_rst),
    // CHDR Input Port
    .s_axis_chdr_tdata(to_dut.tdata),
    .s_axis_chdr_tlast(to_dut.tlast),
    .s_axis_chdr_tvalid(to_dut.tvalid),
    .s_axis_chdr_tready(to_dut.tready),
    .m_axis_chdr_tdata(from_dut.tdata),
    .m_axis_chdr_tlast(from_dut.tlast),
    .m_axis_chdr_tvalid(from_dut.tvalid),
    .m_axis_chdr_tready(from_dut.tready),
    .ctrlport_req_wr(ctrlport_if.req.wr),
    .ctrlport_req_rd(ctrlport_if.req.rd),
    .ctrlport_req_addr(ctrlport_if.req.addr),
    .ctrlport_req_data(ctrlport_if.req.data),
    .ctrlport_resp_ack(ctrlport_if.resp.ack),
    .ctrlport_resp_data(ctrlport_if.resp.data)
  );


  //---------------------------------------------------------------------------
  // Helper Tasks and Functions
  //---------------------------------------------------------------------------

  //---------------------------------------------------------------------------
  // Reset the DUT
  //---------------------------------------------------------------------------
  // Reset the DUT asynchronously and reset it synchronously after 4 clock
  // cycles to ensure that the DUT is in a known state before starting the test.
  //
  // The DUT is assumed to be fully reset and ready for input when the reset
  // signal is deasserted.
  //---------------------------------------------------------------------------
  task automatic reset_dut();
    clk_gen.reset();
    @(negedge rfnoc_chdr_rst);
  endtask

  //---------------------------------------------------------------------------
  // Creates and returns a randomly generated CHDR data packet
  //---------------------------------------------------------------------------
  // include_ts: 1 if the CHDR packets type should be DATA_TS, 0 for DATA.
  //---------------------------------------------------------------------------
  function automatic chdr_pkt_t random_chdr_data_packet(bit include_ts = 0);
    chdr_pkt_t pkt = new();
    int pyld_size;
    int num_mdata;
    int num_words;

    // Choose random metadata and payload lengths
    pyld_size  = $urandom_range(MIN_PYLD_SIZE, MAX_PYLD_SIZE);
    num_mdata  = $urandom_range(MIN_MDATA_SIZE, MAX_MDATA_SIZE);
    num_words  = $ceil(real'(pyld_size) / (CHDR_W / 8));

    // Create header for this packet.
    pkt.header = Rand#(CHDR_HEADER_W)::rand_bit();
    if (include_ts) begin
      pkt.header.pkt_type = chdr_pkt_type_t'(CHDR_PKT_TYPE_DATA_TS);
      pkt.timestamp       = Rand#(CHDR_TIMESTAMP_W)::rand_bit();
    end else begin
      pkt.header.pkt_type = chdr_pkt_type_t'(CHDR_PKT_TYPE_DATA);
    end
    pkt.header.eob       = 0;  // do not randomize end of burst.
    pkt.header.num_mdata = num_mdata;
    pkt.header           = chdr_update_length(CHDR_W, pkt.header, pyld_size);

    repeat (num_mdata) pkt.metadata.push_back(Rand#(CHDR_W)::rand_bit());
    repeat (num_words) pkt.data.push_back(Rand#(CHDR_W)::rand_bit());

    return pkt;
  endfunction

  //---------------------------------------------------------------------------
  // Creates and returns a randomly generated CHDR data burst
  //---------------------------------------------------------------------------
  // - include_ts: 1 if the CHDR packets type should be DATA_TS, 0 for DATA.
  // - num_pkts:   Number of packets in the burst. If -1, a random number
  //               between MIN_BURST_SIZE and MAX_BURST_SIZE is chosen.
  //---------------------------------------------------------------------------
  function automatic chdr_pkt_queue_t random_chdr_data_burst(
    bit include_ts = 0, int num_pkts = -1);
    chdr_pkt_queue_t pkt_queue;
    chdr_pkt_t pkt;

    if (num_pkts == -1) begin
      num_pkts = $urandom_range(MAX_BURST_SIZE, MIN_BURST_SIZE);
    end
    for (int i = 0; i < num_pkts; i++) begin
      pkt = random_chdr_data_packet(include_ts);
      pkt_queue.push_back(pkt);
    end
    // Set the last packet's last eob field to indicate the end of the burst.
    pkt_queue[$].header.eob = 1;
    return pkt_queue;
  endfunction

  //---------------------------------------------------------------------------
  // Creates and returns a number of generated CHDR data bursts.
  //---------------------------------------------------------------------------
  // - include_ts: 1 if the CHDR packets type should be DATA_TS, 0 for DATA.
  // - num_pkts:   Number of packets in each burst. If -1, a random number
  //               between MIN_BURST_SIZE and MAX_BURST_SIZE is chosen.
  // - num_bursts: Number of bursts to generate. If -1, a random number
  //               between MIN_NUM_BURSTS and MAX_NUM_BURSTS is chosen.
  //---------------------------------------------------------------------------
  function automatic chdr_burst_queue_t random_data_burst_stream(
    bit include_ts = 0, int num_pkts = -1, int num_bursts = -1);
    chdr_burst_queue_t burst_queue;
    chdr_pkt_queue_t pkt_queue;

    if (num_bursts == -1) begin
      num_bursts = $urandom_range(MIN_NUM_BURSTS, MAX_NUM_BURSTS);
    end
    for (int i = 0; i < num_bursts; i++) begin
      pkt_queue = random_chdr_data_burst(include_ts, num_pkts);
      burst_queue.push_back(pkt_queue);
    end
    return burst_queue;
  endfunction

  //---------------------------------------------------------------------------
  // Extract or derive the timestamps for all packets in the given burst queue.
  //---------------------------------------------------------------------------
  // The first packet in the burst queue is expected to have a valid timestamp.
  // All other timestamps for the other packets of the burst are derived from
  // the first packet's timestamp.
  //
  // The derived timestamps are added to the timestamp mailbox if it is
  // provided, for subsequent validation.
  //
  // This function does not modify the data packets in the burst queue.
  //
  // - burst_queue:    The burst queue to extract the SoB timestamps from.
  // - exp_ts_mb:      The mailbox to add the extracted/derived timestamps to.
  //                   If null, no timestamps are added to the mailbox.
  // - ts_burst_queue: The burst queue to add the derived timestamps to.
  //---------------------------------------------------------------------------
  task automatic derive_ts_burst(chdr_burst_queue_t burst_queue,
                                 chdr_ts_mb_t exp_ts_mb = null,
                                 output chdr_ts_burst_queue_t ts_burst_queue);
    chdr_timestamp_t ts, next_ts;
    int pkt_len, pyld_samp_len;

    foreach (burst_queue[burst]) begin
      chdr_ts_queue_t ts_burst;
      // Extract the random timestamp from the first packet in the burst and
      // then derive the timestamps for the rest of the packets in the burst.
      for (int pkt = 0; pkt < burst_queue[burst].size(); pkt++) begin
        if (pkt == 0) begin
          ts = burst_queue[burst][pkt].timestamp;
        end else begin
          ts = next_ts;
        end
        ts_burst.push_back(ts);
        // Add TS to the timestamp mailbox if available.
        if (exp_ts_mb != null) begin
          exp_ts_mb.put(ts);
        end
        pkt_len = burst_queue[burst][pkt].header.length;
        pyld_samp_len = (pkt_len - CHDR_W/8 -
          burst_queue[burst][pkt].header.num_mdata*(CHDR_W/8)) / (ITEM_W / 8);
        if (CHDR_W == 64) begin
          pyld_samp_len = pyld_samp_len - CHDR_W / ITEM_W;
        end
        next_ts = ts + pyld_samp_len;
      end
      ts_burst_queue.push_back(ts_burst);
    end
  endtask

  // Sends a burst of CHDR data packets to the CHDR BFM.
  task automatic send_chdr_data_bursts(
    chdr_burst_queue_t burst_queue, bit data_with_ts,
    chdr_pkt_mb_t exp_pkts_mb, chdr_ts_mb_t exp_ts_mb);
    chdr_timestamp_t ts;
    chdr_pkt_t exp_pkt;
    foreach (burst_queue[burst, pkt]) begin
      chdr_bfm.put_chdr(burst_queue[burst][pkt].copy());
      if (exp_pkts_mb != null) begin
        exp_pkt = burst_queue[burst][pkt].copy();
        // If the packet has a timestamp, add the expected derived timestamp to
        // the expected packet before adding it to the mailbox.
        if (data_with_ts) begin
          exp_ts_mb.get(ts);
          exp_pkt.timestamp = ts;
        end
        exp_pkts_mb.put(exp_pkt);
      end
    end
  endtask

  //---------------------------------------------------------------------------
  // Testcase Logic
  //---------------------------------------------------------------------------
  // Testcase: Drop Policy Active
  //---------------------------------------------------------------------------
  // This test case generates a random number of bursts of random CHDR data
  // packets without timestamps.
  //
  // Before the start trigger is sent, the stop policy is set to drop. The DUT
  // is expected to drop all packets until the start trigger is sent.
  //---------------------------------------------------------------------------
  task automatic test_drop_policy_active();
    chdr_pkt_mb_t exp_pkts_mb = new();
    chdr_ts_mb_t exp_ts_mb = new();

    // Generate a random number of bursts of random chdr data packets
    // without timestamps.
    chdr_burst_queue_t burst_queue = random_data_burst_stream();

    // Set the stop policy to drop
    reg_bfm.write(REG_CHAN_STOP_POLICY_ADDR, TX_POLICY_DROP);

    send_chdr_data_bursts(burst_queue, 0, exp_pkts_mb, exp_ts_mb);

    // Check if the BFM is actively forwarding packets.
    // This should indicate that the packets are dropped. If it doesn't
    // then the tb will fail at this point with a timeout.
    chdr_bfm.wait_complete();

    // Set the start trigger after all data has already been queued
    reg_bfm.write(REG_CHAN_TX_CTRL_ADDR, 1 << REG_CHAN_TX_START_POS);

    `ASSERT_ERROR(chdr_bfm.num_received() == 0, $sformatf(
                  {
                    "Output packet mismatch: expected all packets dropped, got %0p"
                  },
                  chdr_bfm.num_received()));

    // Send stop trigger to DUT
    reg_bfm.write(REG_CHAN_TX_CTRL_ADDR, 1 << REG_CHAN_TX_STOP_POS);

  endtask

  //---------------------------------------------------------------------------
  // Testcase: Stop Policy Buffer
  //---------------------------------------------------------------------------
  // This test case generates a random number of bursts of random CHDR data
  // packets without timestamps.
  //
  // Before the start trigger is sent, the stop policy is set to buffer. The
  // DUT is expected to buffer all packets until the start trigger is sent.
  //
  // We expect all buffered packets to be processed after the start trigger is
  // sent.
  //---------------------------------------------------------------------------
  task automatic test_buffer_policy_active();
    chdr_pkt_mb_t exp_pkts_mb = new();
    chdr_ts_mb_t  exp_ts_mb = new();
    chdr_pkt_t out_pkt, exp_pkt;

    // Generate a random number of bursts of random chdr data packets
    // without timestamps.
    chdr_burst_queue_t burst_queue = random_data_burst_stream();

    // Set the stop policy to buffer
    reg_bfm.write(REG_CHAN_STOP_POLICY_ADDR, TX_POLICY_BUFFER);

    // Queue up the data bursts to the CHDR BFM
    send_chdr_data_bursts(burst_queue, 0, exp_pkts_mb, exp_ts_mb);

    chdr_bfm.wait_send(1);

    // Send start trigger to DUT
    // This will start the DUT processing the data bursts
    reg_bfm.write(REG_CHAN_TX_CTRL_ADDR, 1 << REG_CHAN_TX_START_POS);

    chdr_bfm.wait_complete();

    // Validate DUT output packets by checking against expected packets.
    do begin
      exp_pkts_mb.get(exp_pkt);
      chdr_bfm.get_chdr(out_pkt);
      `ASSERT_ERROR(
        out_pkt.equal(exp_pkt), $sformatf(
        {"Output packet mismatch: expected %0p, got %0p"}, exp_pkt, out_pkt));
    end while (exp_pkts_mb.num() > 0);

    // Send stop trigger to DUT
    reg_bfm.write(REG_CHAN_TX_CTRL_ADDR, 1 << REG_CHAN_TX_STOP_POS);

  endtask

  //---------------------------------------------------------------------------
  // Testcase: Random Burst Continuous Data
  //---------------------------------------------------------------------------
  // This test case generates a random number of bursts of random CHDR data
  // packets either all with or all without timestamps.
  //
  // The start trigger is sent, and then the data bursts are queued up to the
  // CHDR BFM. The DUT is expected to process the data bursts and send them to
  // the output.
  //
  // After validation of the output packets, the stop trigger is sent to the DUT.
  //
  // - include_ts: 1 if the CHDR packets type should be DATA_TS, 0 for DATA.
  //---------------------------------------------------------------------------
  task automatic test_random_burst_continuous_data(bit include_ts = 0);
    chdr_pkt_mb_t exp_pkts_mb = new();
    chdr_ts_mb_t  exp_ts_mb = new();

    fork
      begin : dut_input_thread

        chdr_timestamp_t ts;
        chdr_ts_burst_queue_t ts_burst_queue;

        // Generate a random number of bursts of random chdr data packets
        // without timestamps.
        chdr_burst_queue_t burst_queue = random_data_burst_stream(include_ts);

        if (include_ts) begin
          derive_ts_burst(burst_queue, exp_ts_mb, ts_burst_queue);
          // Add the timestamps to the module timestamp queue
          foreach (ts_burst_queue[burst]) begin
            ts = ts_burst_queue[burst][0];
            reg_bfm.write(REG_CHAN_TS_LOW_ADDR, ts[REG_CHAN_TS_LOW_LEN-1:0]);
            reg_bfm.write(REG_CHAN_TS_HIGH_ADDR,
                          ts[REG_CHAN_TS_LOW_LEN+:REG_CHAN_TS_HIGH_LEN]);
          end
        end

        // Set the stop policy to buffer
        reg_bfm.write(REG_CHAN_STOP_POLICY_ADDR, TX_POLICY_BUFFER);

        // Send start trigger to DUT
        // This will start the DUT processing the data bursts
        reg_bfm.write(REG_CHAN_TX_CTRL_ADDR, 1 << REG_CHAN_TX_START_POS);

        // Queue up the data bursts to the CHDR BFM
        send_chdr_data_bursts(burst_queue, include_ts, exp_pkts_mb, exp_ts_mb);
        chdr_bfm.wait_complete();

        // Send stop trigger to DUT once all packets have been received.
        reg_bfm.write(REG_CHAN_TX_CTRL_ADDR, 1 << REG_CHAN_TX_STOP_POS);

        // Clear any remaining timestamps from the TS queue.
        reg_bfm.write(REG_CHAN_TS_QUEUE_CTRL_ADDR,
                      1 << REG_TS_QUEUE_CTRL_CLR_POS);
      end

      begin : dut_output_validation_thread
        chdr_pkt_t out_pkt, exp_pkt;

        // Validate
        do begin
          exp_pkts_mb.get(exp_pkt);
          chdr_bfm.get_chdr(out_pkt);
          `ASSERT_ERROR(
            out_pkt.equal(exp_pkt), $sformatf(
            {"Output packet mismatch: expected %0p, got %0p"}, exp_pkt, out_pkt
            ));
        end while (exp_pkts_mb.num() > 0);
      end
    join

  endtask

  //---------------------------------------------------------------------------
  // Testcase: Stop During Transmission
  //---------------------------------------------------------------------------
  // This test case generates a random number of bursts of random CHDR data
  // packets with timestamps.
  //
  // The start trigger is sent, and then the data bursts are queued up to the
  // CHDR BFM. Once a specified number of packets have been sent, the stop
  // trigger is sent to the DUT.
  //
  // The DUT is expected to set the EOB flag in the next packet received by the
  // dut after the stop trigger is sent, unless the current packet is already
  // the last packet of a burst.
  //
  // After forwarding the packet containing the EOB flag, the DUT is expected to
  // go back into idle state and drop all remaining incoming packets.
  //---------------------------------------------------------------------------
  task automatic test_stop_during_transmission();

    event done, stop;
    int total_num_pkts = 0, pkts_to_send;

    chdr_pkt_mb_t exp_pkts_mb = new();
    chdr_ts_mb_t  exp_ts_mb = new();

    fork
      begin : dut_input_thread

        chdr_timestamp_t ts;
        chdr_ts_burst_queue_t ts_burst_queue;

        // Generate a random number of bursts of random chdr data packets
        // with timestamps.
        chdr_burst_queue_t burst_queue = random_data_burst_stream(1);

        derive_ts_burst(burst_queue, exp_ts_mb, ts_burst_queue);

        // Set the stop policy to buffer
        reg_bfm.write(REG_CHAN_STOP_POLICY_ADDR, TX_POLICY_DROP);

        // Add the timestamps to the module timestamp queue
        foreach (ts_burst_queue[burst]) begin
          ts = ts_burst_queue[burst][0];
          reg_bfm.write(REG_CHAN_TS_LOW_ADDR, ts[REG_CHAN_TS_LOW_LEN-1:0]);
          reg_bfm.write(REG_CHAN_TS_HIGH_ADDR,
                        ts[REG_CHAN_TS_LOW_LEN+:REG_CHAN_TS_HIGH_LEN]);
        end

        // Send start trigger to DUT
        // This will start the DUT processing the data bursts
        reg_bfm.write(REG_CHAN_TX_CTRL_ADDR, 1 << REG_CHAN_TX_START_POS);

        foreach (burst_queue[burst]) begin
          total_num_pkts += burst_queue[burst].size();
        end
        // Set the number of packets to send to a random number between 5 and
        // total_num_pkts - 5. This is to ensure that we have enough packets
        // to send before the stop trigger is sent.
        pkts_to_send = $urandom_range(5, total_num_pkts - 5);

        // Queue up the data bursts to the CHDR BFM
        send_chdr_data_bursts(burst_queue, 1, exp_pkts_mb, exp_ts_mb);

        chdr_bfm.wait_send(pkts_to_send);

        // Send stop trigger to DUT
        reg_bfm.write(REG_CHAN_TX_CTRL_ADDR, 1 << REG_CHAN_TX_STOP_POS);
        ->stop;

        // Wait for the DUT to process the stop trigger and set the EOB flag
        wait (done.triggered());

        // Set the stop policy to drop to clear buffer
        reg_bfm.write(REG_CHAN_STOP_POLICY_ADDR, TX_POLICY_DROP);

        chdr_bfm.wait_complete();

        // Clear the remaining timestamps
        reg_bfm.write(REG_CHAN_TS_QUEUE_CTRL_ADDR,
                      1 << REG_TS_QUEUE_CTRL_CLR_POS);
      end

      begin : dut_output_validation_thread
        chdr_pkt_t out_pkt, exp_pkt, try_pkt;
        // Wait for the DUT to stop processing the data bursts

        wait (stop.triggered());
        repeat (exp_pkts_mb.num()) begin
          int timeout = 0;
          exp_pkts_mb.get(exp_pkt);

          for (timeout = 0; timeout < TIMEOUT_MAX; timeout++) begin
            // Wait for the output packet to be received
            if (chdr_bfm.try_get_chdr(try_pkt)) begin
              out_pkt = try_pkt;
              break;
            end else if (from_dut.tvalid && from_dut.tready) begin
              // If the dut is still active, reset timeout
              clk_gen.clk_wait_r(1);
              timeout = 0;
            end else begin
              // Wait for the output packet to be received
              clk_gen.clk_wait_r(1);
            end
          end
          if (out_pkt.equal(exp_pkt) && timeout < TIMEOUT_MAX) begin
            continue;
          end else begin
            // Check if the the output packet only differs from the expected
            // packet in the EOB field. If so, then this is expected to be the
            // last packet of the streaming session, after the stop trigger
            // was sent.
            if (out_pkt.header.eob == 1) begin
              break;
            end else begin
              // This will always assert once the code reaches this point.
              `ASSERT_ERROR(out_pkt.equal(exp_pkt), $sformatf(
                            {
                              "Output packet mismatch: expected %0p, got %0p"
                            },
                            exp_pkt,
                            out_pkt
                            ));
            end
          end
        end

        // Check if packets arrived after stop trigger was sent
        `ASSERT_ERROR(chdr_bfm.try_get_chdr(out_pkt) == 0, $sformatf(
                      {
                        "Stop error: Additional packet received after stop. Got %0p"
                      },
                      out_pkt
                      ));

        ->done;

      end
    join
  endtask

  //---------------------------------------------------------------------------
  // Testcase: Timestamp Queue Full
  //---------------------------------------------------------------------------
  // This adds new timestamp queue up to its maximum capacity.
  //
  // Adding additional timestamps to the queue should not have an effect on the
  // queue fullness.
  //
  // Afterwards, the queue is cleared and the fullness is checked again to ensure
  // that the queue is empty.
  //---------------------------------------------------------------------------
  task automatic test_ts_queue_full();
    chdr_timestamp_t ts = 0;
    logic [CTRLPORT_DATA_W-1:0] ts_status_data;

    // Fill the timestamp queue
    repeat (2 ** TS_QUEUE_DEPTH) begin
      reg_bfm.write(REG_CHAN_TS_LOW_ADDR, ts[REG_CHAN_TS_LOW_LEN-1:0]);
      reg_bfm.write(REG_CHAN_TS_HIGH_ADDR,
                    ts[REG_CHAN_TS_LOW_LEN+:REG_CHAN_TS_HIGH_LEN]);

      ts++;
      reg_bfm.read(REG_CHAN_TS_QUEUE_STS_ADDR, ts_status_data);
      assert (ts_status_data[REG_TS_FULLNESS_POS+:REG_TS_FULLNESS_LEN] == ts)
      else begin
        $error("Timestamp queue fullness mismatch: expected %0d, got %0d",
               ts[REG_TS_FULLNESS_LEN-1:0],
               ts_status_data[REG_TS_FULLNESS_POS+:REG_TS_FULLNESS_LEN]);
      end
    end

    // Check that additional timestamps added to the queue are dropped
    reg_bfm.write(REG_CHAN_TS_LOW_ADDR, ts[REG_CHAN_TS_LOW_LEN-1:0]);
    reg_bfm.write(REG_CHAN_TS_HIGH_ADDR,
                  ts[REG_CHAN_TS_LOW_LEN+:REG_CHAN_TS_HIGH_LEN]);
    reg_bfm.read(REG_CHAN_TS_QUEUE_STS_ADDR, ts_status_data);
    assert (ts_status_data[REG_TS_FULLNESS_POS+:REG_TS_FULLNESS_LEN] ==
      2 ** TS_QUEUE_DEPTH)
    else begin
      $error("Timestamp queue fullness mismatch: expected %0d, got %0d",
             ts[REG_TS_FULLNESS_LEN-1:0],
             ts_status_data[REG_TS_FULLNESS_POS+:REG_TS_FULLNESS_LEN]);
    end

    // Clear the remaining timestamps
    reg_bfm.write(CTRLPORT_ADDR_W'(REG_CHAN_TS_QUEUE_CTRL_ADDR),
                  CTRLPORT_DATA_W'(1 << REG_TS_QUEUE_CTRL_CLR_POS));
    clk_gen.clk_wait_r(2);

    // Check that the queue is empty after clearing
    reg_bfm.read(CTRLPORT_ADDR_W'(REG_CHAN_TS_QUEUE_STS_ADDR), ts_status_data);
    assert (ts_status_data[REG_TS_FULLNESS_POS+:REG_TS_FULLNESS_LEN] == 0)
    else begin
      $error("TS queue expected to be empty after clear but got: %0d",
             ts_status_data[REG_TS_FULLNESS_POS+:REG_TS_FULLNESS_LEN]);
    end
  endtask


  //---------------------------------------------------------------------------
  // Testbench Logic
  //---------------------------------------------------------------------------

  int stall_probs[3][2] = '{
    '{STALL_PROB_DEF, STALL_PROB_DEF},
    '{STALL_PROB_HIGH, STALL_PROB_LOW},
    '{STALL_PROB_LOW, STALL_PROB_HIGH}
  };

  initial begin

    test.start_tb("aurora_tx_control_tb");

    // Initialize clock.
    clk_gen.start();
    chdr_bfm.run();
    reg_bfm.run();

    // Reset dut.
    reset_dut();

    // Test drop policy active
    test.start_test("Drop Policy Active");
    test_drop_policy_active();
    test.end_test();

    // Test buffer policy active
    test.start_test("Buffer Policy Active");
    test_buffer_policy_active();
    test.end_test();

    // Test timestamp queue full
    test.start_test("Timestamp Queue Full");
    test_ts_queue_full();
    test.end_test();

    foreach (stall_probs[i]) begin
      // Set the stall probability to the current value
      chdr_bfm.set_master_stall_prob(stall_probs[i][0]);
      chdr_bfm.set_slave_stall_prob(stall_probs[i][1]);

      repeat (10) begin
        // Test random burst continuous data
        test.start_test("Random Burst Continuous Data");
        test_random_burst_continuous_data(0);
        test.end_test();

        // Test random burst timed data
        test.start_test("Random Burst Timed Data");
        test_random_burst_continuous_data(1);
        test.end_test();

        // Test stop during transmission
        test.start_test("Stop During Transmission");
        test_stop_during_transmission();
        test.end_test();

        clk_gen.clk_wait_r(20);
        reset_dut();
      end
    end

    test.end_tb(0);
    clk_gen.kill();

  end

endmodule : aurora_tx_control_tb


`default_nettype wire
