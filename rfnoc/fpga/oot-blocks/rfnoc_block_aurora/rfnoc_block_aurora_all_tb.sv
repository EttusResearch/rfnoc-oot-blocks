//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: rfnoc_block_aurora_all_tb
//
// Description:
//
//   This is the testbench for rfnoc_block_aurora that instantiates several
//   variations of the testbench to test different configurations.
//


module rfnoc_block_aurora_all_tb;

  import PkgTestExec::*;


  //---------------------------------------------------------------------------
  // Test Configurations
  //---------------------------------------------------------------------------

  rfnoc_block_aurora_tb #(.CHDR_W( 64), .NUM_PORTS(4), .EN_TX_CONTROL(1)) tb_0 ();
  rfnoc_block_aurora_tb #(.CHDR_W(256), .NUM_PORTS(2), .EN_TX_CONTROL(1)) tb_1 ();
  rfnoc_block_aurora_tb #(.CHDR_W(512), .NUM_PORTS(1), .EN_TX_CONTROL(1)) tb_2 ();
  rfnoc_block_aurora_tb #(.CHDR_W(256), .NUM_PORTS(1), .EN_TX_CONTROL(0)) tb_3 ();


  //---------------------------------------------------------------------------
  // Finish When Done
  //---------------------------------------------------------------------------
  //
  // The GTY models have a forever loop that never exists, so we have to call
  // finish after all the tests are done.
  //
  //---------------------------------------------------------------------------

  initial begin
    test.wait_all_tb();
    $display("========================================================");
    $info("Finished %0d testbenches", test.end_tb_count);
    $display("========================================================");
    $finish();
  end

endmodule : rfnoc_block_aurora_all_tb
