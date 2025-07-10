//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: aurora_tx_control_all_tb
//
// Description:
//
//   This is the testbench for Aurora block aurora_tx_control_tb that
//   instantiates several variations of the testbench to test different
//   configurations.
//

`default_nettype none

module aurora_tx_control_all_tb;
  import PkgTestExec::*;

  //---------------------------------------------------------------------------
  // Test Configurations
  //---------------------------------------------------------------------------

  for (genvar tb = 64; tb <= 512; tb *= 2) begin : gen_chdr_w
    aurora_tx_control_tb #(.CHDR_W(tb)) tb_i ();
  end

endmodule : aurora_tx_control_all_tb

`default_nettype wire
