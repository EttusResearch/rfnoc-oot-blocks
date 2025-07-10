//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: aurora_core_reset_fsm
//
// Description:
//
//  Handle Reset and initialization sequence
//
//  See PG074 v12.0 for more details on the reset sequence.
//
//  1. Assert reset_pb. Wait for a minimum time equal to 128*user_clk's time-period.
//  2. Assert pma_init. Keep pma_init and reset asserted for at least one
//     second to prevent the transmission of CC characters and ensure that the
//     remote agent detects a hot plug event.
//  3. Deassert pma_init.
//  4. Deassert reset_pb. (full stop) Internally the logic waits for user_clk
//     to get stable and deasserts sys_reset_out after which reset_pb can be
//     deasserted.
//
// Parameters:
//
//   SIMULATION        : Set to 1 to shorten the reset time for simulation. For
//                       synthesis, set to 0.
//   INIT_CLK_FREQ_MHZ : Frequency of the init_clk on the Aurora block
//   USER_CLK_FREQ_MHZ : Frequency of the user_clk on the Aurora block

`default_nettype none


module aurora_core_reset_fsm #(
  parameter bit  SIMULATION        = 0,
  parameter real INIT_CLK_FREQ_MHZ = 100.0,
  parameter real USER_CLK_FREQ_MHZ = 156.25
) (
  input   wire       init_clk,
  input   wire       sw_reset,
  input   wire       sys_reset_out,
  output logic       reset_pb,
  output logic       pma_init
);

  // reset_pb must assert for at least 128 user clock cycles
  localparam int RESET_PB_CYCLES = 130;

  // pma_init must assert for at least 1 second
  localparam real PMA_INIT_TIME_S = SIMULATION ?
    250e-9 : // Use a short delay for simulation
    1.05;

  // FSM related variables
  typedef enum logic [2:0] {
    ST_POWER_UP,
    ST_PMA_INIT_DEASSERT,
    ST_WAIT_FOR_USER_ASSERT,
    ST_DELAY_BEFORE_PMA_INIT_ASSERT,
    ST_HOLD_RESET_ASSERT,
    ST_XXX
  } state_t;

  state_t reset_state;
  state_t next_state;

  // Calculate number of clock cycles for PMA_INIT_TIME_S
  localparam longint COUNTER_MAX =
    $ceil(PMA_INIT_TIME_S * 1.0e6 * INIT_CLK_FREQ_MHZ);

  // Delay must be at least 128 cycles of user_clk
  localparam int DELAY_CYCLES =
    $ceil(real'(RESET_PB_CYCLES) * INIT_CLK_FREQ_MHZ / USER_CLK_FREQ_MHZ);

  // Width of counter needed to count up to DELAY_CYCLES
  localparam int DELAY_CTR_W = $clog2(DELAY_CYCLES+1);

  // Width of counter needed to count up to COUNTER_MAX
  localparam int PMA_INIT_CTR_W = $clog2(COUNTER_MAX+1);

  // Counter to delay before asserting pma_init by DELAY_CYCLES.
  logic [DELAY_CTR_W-1 : 0] delay_counter;

  // Counter to keep pma_init asserted for PMA_INIT_TIME_S.
  logic [PMA_INIT_CTR_W-1 : 0] pma_init_counter;


  // FSM to handle reset sequence
  always_ff @(posedge init_clk) begin
    reset_state <= next_state;
  end

  always_comb begin
    next_state = ST_XXX;

    case (reset_state)

      ST_POWER_UP: begin
        if (~sw_reset) begin
          next_state = ST_PMA_INIT_DEASSERT;
        end else begin
          next_state = ST_POWER_UP;
        end

      end

      ST_PMA_INIT_DEASSERT: begin
        if (sw_reset) begin
          next_state = ST_POWER_UP;
        end else if (delay_counter >= DELAY_CYCLES) begin
          next_state = ST_WAIT_FOR_USER_ASSERT;
        end else begin
          next_state = ST_PMA_INIT_DEASSERT;
        end
      end

      ST_WAIT_FOR_USER_ASSERT: begin
        if (sw_reset) begin
          next_state = ST_DELAY_BEFORE_PMA_INIT_ASSERT;
        end else begin
          next_state = ST_WAIT_FOR_USER_ASSERT;
        end
      end

      ST_DELAY_BEFORE_PMA_INIT_ASSERT: begin
        if (delay_counter >= DELAY_CYCLES) begin
          next_state = ST_HOLD_RESET_ASSERT;
        end else begin
          next_state = ST_DELAY_BEFORE_PMA_INIT_ASSERT;
        end
      end

      ST_HOLD_RESET_ASSERT: begin
        if (pma_init_counter >= COUNTER_MAX) begin
          next_state = ST_POWER_UP;
        end else begin
          next_state = ST_HOLD_RESET_ASSERT;
        end

      end

      default: begin
        next_state = ST_POWER_UP;
      end
    endcase
  end

  always_ff @(posedge init_clk) begin
    pma_init          <= 0;
    reset_pb          <= 0;
    delay_counter     <= 0;
    pma_init_counter  <= 0;

    case (next_state)

      ST_POWER_UP : begin
        pma_init <= 1;
        reset_pb <= 1;
      end

      ST_PMA_INIT_DEASSERT : begin
        reset_pb <= 1;
        if (delay_counter < DELAY_CYCLES) begin
          delay_counter <= delay_counter + 1;
        end
      end

      ST_WAIT_FOR_USER_ASSERT : begin
        reset_pb <= 0;
        pma_init <= 0;
      end

      ST_DELAY_BEFORE_PMA_INIT_ASSERT : begin
        reset_pb <= 1;
        if (delay_counter < DELAY_CYCLES) begin
          delay_counter <= delay_counter + 1;
        end
      end

      ST_HOLD_RESET_ASSERT : begin
        pma_init <= 1;
        reset_pb <= 1;
        if (pma_init_counter < COUNTER_MAX) begin
          pma_init_counter <= pma_init_counter + 1;
        end
      end
      default : begin
        pma_init <= 1;  // Using the outputs of ST_POWER_UP state to keep in line
                        // with the state loop that uses.
        reset_pb <= 1;  // The ST_POWER_UP state as the default state.
      end
    endcase
  end
endmodule


`default_nettype wire
