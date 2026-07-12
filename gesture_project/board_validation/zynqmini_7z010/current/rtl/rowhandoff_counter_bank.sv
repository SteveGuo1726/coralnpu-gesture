module RowhandoffCounterBankProject (
  input  wire        clock,
  input  wire        reset,
  input  wire        io_layerStart,
  input  wire [5:0]  io_rowhandoffRowOutYIn,
  input  wire        io_rowhandoffRowOutYWritePulse,
  input  wire        io_rowhandoffHitPulse,
  input  wire        io_rowhandoffTailHitPulse,
  input  wire        io_rowhandoffMissPulse,
  input  wire        io_rowhandoffInvalidatePulse,
  input  wire        io_rowhandoffProducePulse,
  input  wire        io_interiorRowEnterPulse,
  input  wire        io_rightEdgeDonePulse,
  output wire [15:0] io_csr_rowhandoff_hit_count,
  output wire [15:0] io_csr_rowhandoff_miss_count,
  output wire [15:0] io_csr_rowhandoff_invalidate_count,
  output wire [15:0] io_csr_rowhandoff_produce_count,
  output wire [15:0] io_csr_rowhandoff_tail_hit_count,
  output wire [15:0] io_csr_interior_row_enter_count,
  output wire [15:0] io_csr_right_edge_done_count,
  output wire [5:0]  io_csr_rowhandoff_row_out_y_last,
  output wire [31:0] io_csr_rowhandoff_state_trace_word,
  output wire        io_trace_rowGateActive,
  output wire [5:0]  io_trace_currentRowIndex,
  output wire        io_trace_rowhandoffValidState,
  output wire        io_trace_consumeDecisionValid,
  output wire        io_trace_consumeDecisionHit,
  output wire        io_trace_tailHitSeen,
  output wire [5:0]  io_trace_lastProducedRow,
  output wire [5:0]  io_trace_lastInvalidatedRow,
  output wire        io_trace_rowEnterPulse,
  output wire        io_trace_rowTerminalDonePulse,
  output wire        io_trace_rowAdvanceDonePulse
);
  reg [15:0] hit_count;
  reg [15:0] miss_count;
  reg [15:0] invalidate_count;
  reg [15:0] produce_count;
  reg [15:0] tail_hit_count;
  reg [15:0] interior_count;
  reg [15:0] right_edge_count;
  reg [5:0]  row_last;
  reg [5:0]  current_row;
  reg [5:0]  last_produced_row;
  reg [5:0]  last_invalidated_row;
  reg        row_gate_active;
  reg        valid_state;
  reg        consume_valid;
  reg        consume_hit;
  reg        tail_seen;
  reg        row_enter_pulse;
  reg        row_terminal_done_pulse;
  reg        row_advance_done_pulse;

  always @(posedge clock or posedge reset) begin
    if (reset) begin
      hit_count <= 16'd0;
      miss_count <= 16'd0;
      invalidate_count <= 16'd0;
      produce_count <= 16'd0;
      tail_hit_count <= 16'd0;
      interior_count <= 16'd0;
      right_edge_count <= 16'd0;
      row_last <= 6'd0;
      current_row <= 6'd0;
      last_produced_row <= 6'd0;
      last_invalidated_row <= 6'd0;
      row_gate_active <= 1'b0;
      valid_state <= 1'b0;
      consume_valid <= 1'b0;
      consume_hit <= 1'b0;
      tail_seen <= 1'b0;
      row_enter_pulse <= 1'b0;
      row_terminal_done_pulse <= 1'b0;
      row_advance_done_pulse <= 1'b0;
    end else begin
      row_enter_pulse <= 1'b0;
      row_terminal_done_pulse <= 1'b0;
      row_advance_done_pulse <= 1'b0;
      consume_valid <= io_rowhandoffHitPulse | io_rowhandoffTailHitPulse | io_rowhandoffMissPulse;
      consume_hit <= io_rowhandoffHitPulse | io_rowhandoffTailHitPulse;

      if (io_layerStart) begin
        hit_count <= 16'd0;
        miss_count <= 16'd0;
        invalidate_count <= 16'd0;
        produce_count <= 16'd0;
        tail_hit_count <= 16'd0;
        interior_count <= 16'd0;
        right_edge_count <= 16'd0;
        row_last <= 6'd0;
        current_row <= 6'd0;
        last_produced_row <= 6'd0;
        last_invalidated_row <= 6'd0;
        row_gate_active <= 1'b1;
        valid_state <= 1'b1;
        tail_seen <= 1'b0;
      end

      if (io_rowhandoffRowOutYWritePulse) begin
        row_last <= io_rowhandoffRowOutYIn;
        current_row <= io_rowhandoffRowOutYIn;
        row_enter_pulse <= 1'b1;
        valid_state <= 1'b1;
      end

      if (io_rowhandoffHitPulse)
        hit_count <= hit_count + 16'd1;
      if (io_rowhandoffMissPulse)
        miss_count <= miss_count + 16'd1;
      if (io_rowhandoffInvalidatePulse) begin
        invalidate_count <= invalidate_count + 16'd1;
        last_invalidated_row <= io_rowhandoffRowOutYIn;
      end
      if (io_rowhandoffProducePulse) begin
        produce_count <= produce_count + 16'd1;
        last_produced_row <= io_rowhandoffRowOutYIn;
        row_advance_done_pulse <= 1'b1;
      end
      if (io_rowhandoffTailHitPulse) begin
        tail_hit_count <= tail_hit_count + 16'd1;
        tail_seen <= 1'b1;
      end
      if (io_interiorRowEnterPulse)
        interior_count <= interior_count + 16'd1;
      if (io_rightEdgeDonePulse) begin
        right_edge_count <= right_edge_count + 16'd1;
        row_terminal_done_pulse <= 1'b1;
      end
    end
  end

  assign io_csr_rowhandoff_hit_count = hit_count;
  assign io_csr_rowhandoff_miss_count = miss_count;
  assign io_csr_rowhandoff_invalidate_count = invalidate_count;
  assign io_csr_rowhandoff_produce_count = produce_count;
  assign io_csr_rowhandoff_tail_hit_count = tail_hit_count;
  assign io_csr_interior_row_enter_count = interior_count;
  assign io_csr_right_edge_done_count = right_edge_count;
  assign io_csr_rowhandoff_row_out_y_last = row_last;
  assign io_csr_rowhandoff_state_trace_word =
    {last_invalidated_row, last_produced_row, row_last, current_row,
     tail_seen, consume_hit, consume_valid, valid_state, row_gate_active, 3'd0};
  assign io_trace_rowGateActive = row_gate_active;
  assign io_trace_currentRowIndex = current_row;
  assign io_trace_rowhandoffValidState = valid_state;
  assign io_trace_consumeDecisionValid = consume_valid;
  assign io_trace_consumeDecisionHit = consume_hit;
  assign io_trace_tailHitSeen = tail_seen;
  assign io_trace_lastProducedRow = last_produced_row;
  assign io_trace_lastInvalidatedRow = last_invalidated_row;
  assign io_trace_rowEnterPulse = row_enter_pulse;
  assign io_trace_rowTerminalDonePulse = row_terminal_done_pulse;
  assign io_trace_rowAdvanceDonePulse = row_advance_done_pulse;
endmodule
