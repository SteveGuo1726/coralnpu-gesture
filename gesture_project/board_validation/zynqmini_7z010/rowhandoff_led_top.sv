module ZynqMiniRowhandoffLedTop (
  input  wire       clk,
  input  wire       rst_n,
  output wire [3:0] led
);
  reg [23:0] heartbeat;
  reg [7:0]  step;
  reg [5:0]  row_y;

  wire reset = ~rst_n;

  wire layer_start = (step == 8'd1);
  wire row_write   = (step[2:0] == 3'd2);
  wire produce     = (step[2:0] == 3'd3);
  wire hit         = (step[2:0] == 3'd4);
  wire tail_hit    = (step[5:0] == 6'd31);
  wire miss        = (step[5:0] == 6'd47);
  wire invalidate  = (step[5:0] == 6'd55);
  wire interior    = (step[2:0] == 3'd1);
  wire right_edge  = (step[5:0] == 6'd63);

  wire [15:0] hit_count;
  wire [15:0] miss_count;
  wire [15:0] invalidate_count;
  wire [15:0] produce_count;
  wire [15:0] tail_hit_count;
  wire [15:0] interior_count;
  wire [15:0] right_edge_count;
  wire [5:0]  row_last;
  wire [31:0] state_trace_word;
  wire        row_gate_active;
  wire [5:0]  current_row;
  wire        valid_state;
  wire        consume_valid;
  wire        consume_hit;
  wire        tail_seen;
  wire [5:0]  last_produced_row;
  wire [5:0]  last_invalidated_row;
  wire        row_enter_pulse;
  wire        row_terminal_done_pulse;
  wire        row_advance_done_pulse;

  always @(posedge clk) begin
    if (reset) begin
      heartbeat <= 24'd0;
      step <= 8'd0;
      row_y <= 6'd0;
    end else begin
      heartbeat <= heartbeat + 24'd1;
      step <= step + 8'd1;
      if (row_write) begin
        row_y <= row_y + 6'd1;
      end
    end
  end

  RowhandoffCounterBank rowhandoff_counter_bank (
    .clock(clk),
    .reset(reset),
    .io_layerStart(layer_start),
    .io_rowhandoffRowOutYIn(row_y),
    .io_rowhandoffRowOutYWritePulse(row_write),
    .io_rowhandoffHitPulse(hit),
    .io_rowhandoffTailHitPulse(tail_hit),
    .io_rowhandoffMissPulse(miss),
    .io_rowhandoffInvalidatePulse(invalidate),
    .io_rowhandoffProducePulse(produce),
    .io_interiorRowEnterPulse(interior),
    .io_rightEdgeDonePulse(right_edge),
    .io_csr_rowhandoff_hit_count(hit_count),
    .io_csr_rowhandoff_miss_count(miss_count),
    .io_csr_rowhandoff_invalidate_count(invalidate_count),
    .io_csr_rowhandoff_produce_count(produce_count),
    .io_csr_rowhandoff_tail_hit_count(tail_hit_count),
    .io_csr_interior_row_enter_count(interior_count),
    .io_csr_right_edge_done_count(right_edge_count),
    .io_csr_rowhandoff_row_out_y_last(row_last),
    .io_csr_rowhandoff_state_trace_word(state_trace_word),
    .io_trace_rowGateActive(row_gate_active),
    .io_trace_currentRowIndex(current_row),
    .io_trace_rowhandoffValidState(valid_state),
    .io_trace_consumeDecisionValid(consume_valid),
    .io_trace_consumeDecisionHit(consume_hit),
    .io_trace_tailHitSeen(tail_seen),
    .io_trace_lastProducedRow(last_produced_row),
    .io_trace_lastInvalidatedRow(last_invalidated_row),
    .io_trace_rowEnterPulse(row_enter_pulse),
    .io_trace_rowTerminalDonePulse(row_terminal_done_pulse),
    .io_trace_rowAdvanceDonePulse(row_advance_done_pulse)
  );

  assign led[0] = heartbeat[23];
  assign led[1] = hit_count[3];
  assign led[2] = row_gate_active ^ valid_state ^ consume_valid ^ consume_hit;
  assign led[3] = row_terminal_done_pulse ^ row_advance_done_pulse ^ tail_seen ^ state_trace_word[0];
endmodule
