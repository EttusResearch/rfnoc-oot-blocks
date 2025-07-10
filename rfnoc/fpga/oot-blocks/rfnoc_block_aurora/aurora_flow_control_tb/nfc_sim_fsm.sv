//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: nfc_sim_fsm.sv
//
// Description:
//
// This module implements a simple FSM to simulate the behavior of the NFC
// flow control logic in the Aurora block. The FSM has five states:
//
// 1. WAIT_FOR_REQUEST: The FSM is waiting for a valid request to be received.
// 2. SIMULATE_NFC_DELAY_PAUSE: The FSM is simulating the NFC delay. The FSM
//    will generally stall the transmission for the duration of the NFC delay,
//    unless a new request is received during the delay.
// 3. NFC_PAUSE: The FSM is in the pause state. The FSM will stall the
//    transmission for the duration of the pause. The FSM will also check
//    for new requests received during the pause and potentially extend the pause.
// 4. NFC_STOP: The FSM is in the stop state. The FSM will stall the
//    transmission until a resume request is received.
//
// Parameters:
// NFC_DELAY: The duration of the NFC delay in clock cycles. This parameter
//            is used to simulate the delay between when the nfc request is
//            sent out by the DUT and when the requested transmission stall is
//            actually applied to the DUT inputs.
//
// NOTE: For Simplicity this module does not implement the delay for resuming
// the transmission. This should not be a problem, as resuming earlier will
// result in more stress for the DUT, as it will have to send another stop
// request to the DUT earlier than if the resume request was delayed.
//

`default_nettype none

module nfc_sim_fsm #(
  parameter int NFC_DELAY = 16
) (
  input wire clk,
  input wire rst,

  input  wire         s_axi_nfc_tvalid,
  input  wire  [15:0] s_axi_nfc_tdata,
  output logic        s_axi_nfc_tready,

  output logic stall_transmission
);

  // Define the states of the FSM
  typedef enum logic [2:0] {
    WAIT_FOR_REQUEST,
    SIMULATE_NFC_DELAY_PAUSE,
    SIMULATE_NFC_DELAY_STOP,
    NFC_PAUSE,
    NFC_STOP
  } aurora_fc_sim_state_t;

  // Define NFC request structure
  typedef struct packed {
    logic [6:0] reserved;
    logic       XOFF;
    logic [7:0] pause_duration;
  } nfc_request_t;

  nfc_request_t nfc_request;

  assign nfc_request = s_axi_nfc_tdata;

  // Define the state variables
  aurora_fc_sim_state_t current_state = WAIT_FOR_REQUEST;
  aurora_fc_sim_state_t next_state    = WAIT_FOR_REQUEST;

  // Local variables
  int reg_sim_nfc_delay_counter;
  int reg_pause_counter;

  // Define the FSM
  always_ff @(posedge clk) begin : UpdateState
    if (rst) begin
      current_state <= WAIT_FOR_REQUEST;
    end else begin
      current_state <= next_state;
    end
  end


  always_comb begin : NextState
    next_state = current_state;
    case (current_state)
      WAIT_FOR_REQUEST: begin
        next_state = WAIT_FOR_REQUEST;
        // if valid request is received, prepare to stall
        if (s_axi_nfc_tvalid) begin
          if (nfc_request.XOFF) begin
            next_state = SIMULATE_NFC_DELAY_STOP;
          end else if (nfc_request.pause_duration != '0) begin
            next_state = SIMULATE_NFC_DELAY_PAUSE;
          end
        end
      end

      SIMULATE_NFC_DELAY_PAUSE: begin
        next_state = SIMULATE_NFC_DELAY_PAUSE;
        // Wait until the delay is over to start the pause/stop
        if (reg_sim_nfc_delay_counter <= 0) begin
          next_state = NFC_PAUSE;
        end
      end

      SIMULATE_NFC_DELAY_STOP: begin
        next_state = SIMULATE_NFC_DELAY_STOP;
        // Wait until the delay is over to start the pause/stop
        if (reg_sim_nfc_delay_counter <= 0) begin
          next_state = NFC_STOP;
        end
      end

      NFC_PAUSE: begin
        next_state = NFC_PAUSE;
        // Wait until the pause is over to restart
        if (reg_pause_counter <= 0 && !s_axi_nfc_tvalid) begin
          next_state = WAIT_FOR_REQUEST;
        end else if (s_axi_nfc_tvalid && nfc_request.XOFF) begin
          next_state = NFC_STOP;
        end else if (s_axi_nfc_tvalid && nfc_request == '0) begin
          next_state = WAIT_FOR_REQUEST;
        end else if (s_axi_nfc_tvalid && nfc_request.pause_duration != '0) begin
          next_state = NFC_PAUSE;
        end
      end

      NFC_STOP: begin
        next_state = NFC_STOP;
        // Wait until the stop is over to restart
        if (s_axi_nfc_tvalid && nfc_request == '0) begin
          next_state = WAIT_FOR_REQUEST;
        end
      end

      default: begin
        next_state = current_state;
      end
    endcase
  end

  always_ff @(posedge clk) begin : EnableOutputs
    stall_transmission <= 0;
    // keep tready deasserted for 1 cycle after each valid request.
    if (!s_axi_nfc_tready) begin
      s_axi_nfc_tready <= 1;
    end else begin
      if (s_axi_nfc_tvalid) begin
        s_axi_nfc_tready <= 0;
      end
    end

    case (next_state)
      WAIT_FOR_REQUEST: begin
        reg_sim_nfc_delay_counter <= NFC_DELAY;
        reg_pause_counter <= 0;
      end

      SIMULATE_NFC_DELAY_PAUSE: begin
        reg_pause_counter <= nfc_request.pause_duration;
        reg_sim_nfc_delay_counter <= reg_sim_nfc_delay_counter - 1;
      end

      SIMULATE_NFC_DELAY_STOP: begin
        reg_sim_nfc_delay_counter <= reg_sim_nfc_delay_counter - 1;
      end

      NFC_PAUSE: begin
        stall_transmission <= 1;
        if (s_axi_nfc_tvalid && !nfc_request.XOFF) begin
          reg_pause_counter <= nfc_request.pause_duration;
        end else begin
          reg_pause_counter <= reg_pause_counter - 1;
        end
      end

      NFC_STOP: begin
        stall_transmission <= 1;
      end

      default: begin
        stall_transmission <= 0;
      end
    endcase

    if (rst) begin
      stall_transmission <= 0;
      s_axi_nfc_tready <= 1;
      reg_pause_counter <= 0;
      reg_sim_nfc_delay_counter <= NFC_DELAY;
    end
  end


endmodule
`default_nettype wire
