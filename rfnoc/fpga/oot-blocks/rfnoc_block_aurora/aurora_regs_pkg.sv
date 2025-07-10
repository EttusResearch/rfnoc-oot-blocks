//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: aurora_regs_pkg
//
// Description:
//
//   Package file describing the Aurora RFNoC block's registers.
//
//   The registers are partitioned into 2**AURORA_CHAN_ADDR_W regions. The
//   first one is for the Aurora core registers. This space is then followed by
//   NUM_CHAN regions of the same size, one for each RFNoC channel.
//
//   The core and channel regions are then repeated for each Aurora core that
//   is instantiated.
//
//               Core 0 –→  ┌─  ┌─────────────────────────────────────────────
//                          │   │
//                          │   │
//    2^AURORA_CHAN_ADDR_W ─┤   │ Aurora Core 0 Registers
//                          │   │
//                          │   │
//                          └─  ├─────────────────────────────────────────────
//                              │
//                              │
//                              │ RFNoC Channel 0
//                              │
//                              │
//                              ├─────────────────────────────────────────────
//
//                              ⋮
//
//                          ┌─  ├─────────────────────────────────────────────
//                          │   │
//                          │   │
//    2^AURORA_CHAN_ADDR_W ─┤   │ RFNoC Channel N-1
//                          │   │
//                          │   │
//                          └─  └─────────────────────────────────────────────
//
//                              ⋮
//
//               Core 1 –→  ┌─  ┌─────────────────────────────────────────────
//                          │   │
//                          │   │
//    2^AURORA_CHAN_ADDR_W ─┤   │ Aurora Core 1 Registers
//                          │   │
//                          │   │
//                          └─  ├─────────────────────────────────────────────
//                              │
//                              │
//                              │ RFNoC Channel N
//                              │
//                              │
//                              ├─────────────────────────────────────────────
//
//                              ⋮
//
//                          ┌─  ├─────────────────────────────────────────────
//                          │   │
//                          │   │
//    2^AURORA_CHAN_ADDR_W ─┤   │ RFNoC Channel 2*N-1
//                          │   │
//                          │   │
//                          └─  └─────────────────────────────────────────────
//
//                              ⋮
//


package aurora_regs_pkg;

  // Address space allocated to to each register region.
  localparam int AURORA_CHAN_ADDR_W = 6;

  // Allocate space allocated to each core.
  localparam int AURORA_CORE_ADDR_W = 11;


  //---------------------------------------------------------------------------
  // Aurora Core Registers
  //---------------------------------------------------------------------------
  //
  // These address space for these registers occurs at the start of each core's
  // address space, one per core.
  //
  //---------------------------------------------------------------------------

  // REG_COMPAT (R)
  //
  // Compatibility version. This read-only register is used by software to
  // determine if this block's version is compatible with the running software.
  // A major version change indicates the software for the previous major
  // version is no longer compatible. A minor version change means the previous
  // version is compatible, but some new features may be unavailable.
  //
  // [31:16] Major version
  // [15: 0] Minor version
  //
  localparam int REG_COMPAT_ADDR = 'h0;


  // REG_CORE_CONFIG (R)
  //
  // Reports the number of Aurora cores and channels per core in this RFNoC
  // block. This register is read-only.
  //
  // [15:8] Number of Aurora cores.
  // [ 7:0] Number of of RFNoC channels per Aurora core.
  //
  localparam int REG_CORE_CONFIG_ADDR = 'h4;
  //
  localparam int REG_NUM_CORES_POS = 0;
  localparam int REG_NUM_CORES_LEN = 8;
  localparam int REG_NUM_CHAN_POS = 16;
  localparam int REG_NUM_CHAN_LEN = 8;


  // REG_CORE_STATUS (R)
  //
  // Provides the status of the aurora IP module. This register is read-only.
  //
  // [   13] Aurora Core GT PLL lock (1 = locked, 0 = not locked)
  // [   12] Aurora Core MMCM lock (1 = locked, 0 = not locked)
  // [11:10] (Reserved)
  // [    9] Aurora soft error status (1 = error, 0 = no error). Once set, this
  //         bit remains set until the core is reset.
  // [    8] Aurora hard error status (1 = error, 0 = no error). Once set, this
  //         bit remains set until the core is reset.
  // [  7:5] (Reserved)
  // [    4] Aurora link status (1 = up, 0 = down)
  // [  3:0] Lane 3, 2, 1, and 0 status (1 = up, 0 = down)
  //
  localparam int REG_CORE_STATUS_ADDR = 'h8;
  //
  localparam int REG_LANE_STATUS_POS = 0;
  localparam int REG_LANE_STATUS_LEN = 4;
  localparam int REG_LINK_STATUS_POS = 4;
  localparam int REG_HARD_ERR_POS = 8;
  localparam int REG_SOFT_ERR_POS = 9;
  localparam int REG_MMCM_LOCK_POS = 12;
  localparam int REG_PLL_LOCK_POS = 13;


  // REG_CORE_RESET (W)
  //
  // Controls the internal resets of the block. Writing a 1 to a reset bit will
  // initiate a reset of the corresponding logic. This register is
  // self-clearing and write-only.
  //
  // [2] RX datapath reset (1 = reset, 0 = no effect)
  // [1] TX datapath reset (1 = reset, 0 = no effect)
  // [0] Aurora core reset (1 = reset, 0 = no effect)
  //
  localparam int REG_CORE_RESET_ADDR = 'hC;
  //
  localparam int REG_AURORA_RESET_POS      = 0;
  localparam int REG_TX_DATAPATH_RESET_POS = 1;
  localparam int REG_RX_DATAPATH_RESET_POS = 2;


  // REG_CORE_FC_PAUSE (R/W)
  //
  // Sets the Aurora native flow control (NFC) parameters.
  //
  // [7:0] NFC pause count in cycles. This is the pause count to provide to the
  //       NFC interface when flow control is triggered.
  localparam int REG_CORE_FC_PAUSE_ADDR = 'h10;
  //
  localparam int REG_PAUSE_COUNT_LEN = 8;
  //
  localparam bit [31:0] REG_CORE_FC_PAUSE_RW_MASK = 32'h000000FF;


  // REG_CORE_FC_THRESHOLD (R/W)
  //
  // Sets the Aurora native flow control (NFC) parameters.
  //
  // [ 23:16] NFC resume threshold. We send the XON message when the number of
  //          clock cycles of remaining buffer falls below this number.
  // [   7:0] NFC pause threshold. We send the XOFF message when the number of
  //          clock cycles of remaining buffer falls below this number.
  localparam int REG_CORE_FC_THRESHOLD_ADDR = 'h14;
  //
  localparam int REG_PAUSE_THRESH_POS  = 0;
  localparam int REG_PAUSE_THRESH_LEN  = 8;
  localparam int REG_RESUME_THRESH_POS = 16;
  localparam int REG_RESUME_THRESH_LEN = 8;
  //
  localparam bit [31:0] REG_CORE_FC_THRESHOLD_RW_MASK = 32'h00FF00FF;


  // REG_CORE_TX_PKT_CTR (R)
  //
  // Reports the number of Aurora packets transmitted (RFNoC to Aurora). This
  // register is read-only.
  //
  localparam int REG_CORE_TX_PKT_CTR_ADDR = 'h18;


  // REG_CORE_RX_PKT_CTR (R)
  //
  // Reports the number of Aurora packets received (Aurora to RFNoC). This
  // register is read-only.
  //
  localparam int REG_CORE_RX_PKT_CTR_ADDR = 'h1C;


  // REG_CORE_OVERFLOW_CTR (R)
  //
  // Reports the number of packets received from the Aurora link that were
  // dropped because there was not sufficient room in the buffer to receive
  // them. With flow control enabled, this register should always be 0. This
  // register is read-only.
  //
  localparam int REG_CORE_OVERFLOW_CTR_ADDR = 'h20;


  // REG_CORE_CRC_ERR_CTR (R)
  //
  // Reports the count of the CRC errors detected by the Aurora IP, which is
  // also the number of packets dropped due to CRC errors. This register is
  // read-only.
  //
  localparam int REG_CORE_CRC_ERR_CTR_ADDR = 'h24;


  //---------------------------------------------------------------------------
  // RFNoC Channel Registers
  //---------------------------------------------------------------------------
  //
  // These address space for these registers occurs immediately following the
  // core register address space. There is one set of these registers for each
  // RFNoC channel.
  //
  //---------------------------------------------------------------------------

  // REG_CHAN_TX_CTRL (W)
  //
  // Controls the start and stop of the "TX" datapath (i.e., the path from the
  // Aurora link to RFNoC). These are self-clearing strobe bits. This register
  // is write-only.
  //
  // [1] TX stop trigger  (1 = enabled, 0 = disabled)
  // [0] TX start trigger (1 = enabled, 0 = disabled)
  //
  localparam int REG_CHAN_TX_CTRL_ADDR = 'h0;
  localparam int REG_CHAN_TX_CTRL_LEN = 2;
  //
  localparam int REG_CHAN_TX_START_POS = 0;
  localparam int REG_CHAN_TX_STOP_POS = 1;


  // REG_CHAN_TS_LOW (W)
  //
  // Sets the lower 32 bits of the start timestamp. This register is write-only.
  //
  localparam int REG_CHAN_TS_LOW_ADDR = 'h4;
  localparam int REG_CHAN_TS_LOW_LEN = 32;


  // REG_CHAN_TS_HIGH (W)
  //
  // Sets the upper 32 bits of the start timestamp. Writing to this register
  // puts the 64-bit timestamp (both low and high 32-bit words) into the
  // timestamp queue. This register is write-only.
  //
  localparam int REG_CHAN_TS_HIGH_ADDR = 'h8;
  localparam int REG_CHAN_TS_HIGH_LEN = 32;


  // REG_CHAN_STOP_POLICY (R/W)
  //
  // This register is used to set stop policy, which controls what the TX
  // datapath does when it is stopped.
  //
  // [0] TX stop policy. The following values are supported:
  //     0: "Drop" - Drop all packets from Aurora until we start.
  //     1: "Buffer" - Packets are held back until we start.
  //
  localparam int REG_CHAN_STOP_POLICY_ADDR = 'hC;
  localparam int REG_CHAN_STOP_POLICY_LEN = 1;
  //
  localparam int TX_POLICY_DROP = 0;
  localparam int TX_POLICY_BUFFER = 1;
  //
  localparam bit [31:0] REG_CHAN_STOP_POLICY_RW_MASK = 32'h00000001;


  // REG_CHAN_TS_QUEUE_STS (R)
  //
  // Provides the status of the timestamp queue.
  //
  // [31:16] Size
  // [15:0] Fullness
  //
  localparam int REG_CHAN_TS_QUEUE_STS_ADDR = 'h10;
  localparam int REG_CHAN_TS_QUEUE_STS_LEN = 32;
  //
  localparam int REG_TS_FULLNESS_POS = 0;
  localparam int REG_TS_FULLNESS_LEN = 16;
  localparam int REG_TS_SIZE_POS = 16;
  localparam int REG_TS_SIZE_LEN = 16;

  // REG_CHAN_TS_QUEUE_CTRL (W)
  //
  // Provides the controls of the timestamp queue. These are self-clearing
  // strobe bits. This register is write-only.
  //
  // [0] Clear TS queue (1 = clear, 0 = no effect)
  //
  localparam int REG_CHAN_TS_QUEUE_CTRL_ADDR = 'h14;
  localparam int REG_CHAN_TS_QUEUE_CTRL_LEN = 1;
  //
  localparam int REG_TS_QUEUE_CTRL_CLR_POS = 0;
  localparam int REG_TS_QUEUE_CTRL_CLR_LEN = 1;

endpackage : aurora_regs_pkg
