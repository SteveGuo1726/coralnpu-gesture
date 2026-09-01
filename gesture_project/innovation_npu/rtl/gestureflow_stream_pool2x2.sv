// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Streaming 2x2 max-pool for the GestureFlow DMP store path.  It removes the
// full-frame output BRAM by keeping only one ping-pong row line plus two
// previous-vector registers.  Signed INT8 lanes are compared with TFLite
// semantics (two's-complement signed max), matching the legacy bank writer.
`timescale 1ns/1ps
module gestureflow_stream_pool2x2 #(
  parameter int VECTOR_BYTES = 32,
  parameter int MAX_WIDTH = 96
) (
  input  logic clk,
  input  logic rst_n,
  input  logic frame_start,
  input  logic vector_valid,
  output logic vector_ready,
  input  logic [VECTOR_BYTES*8-1:0] vector_data,
  input  logic [15:0] image_width,
  input  logic [15:0] image_height,
  output logic pooled_valid,
  input  logic pooled_ready,
  output logic [VECTOR_BYTES*8-1:0] pooled_data,
  output logic pooled_last
);
  (* ram_style = "distributed" *) logic [VECTOR_BYTES*8-1:0] line0 [0:MAX_WIDTH-1];

  logic [15:0] row, col;
  logic row_parity;
  logic emit_pending;
  logic [VECTOR_BYTES*8-1:0] cur_prev, prev_line0;
  logic [VECTOR_BYTES*8-1:0] pooled_reg;
  logic last_reg;

  function automatic logic [VECTOR_BYTES*8-1:0] max4(
    input logic [VECTOR_BYTES*8-1:0] a,
    input logic [VECTOR_BYTES*8-1:0] b,
    input logic [VECTOR_BYTES*8-1:0] c,
    input logic [VECTOR_BYTES*8-1:0] d);
    logic signed [7:0] maximum;
    begin
      for (int lane = 0; lane < VECTOR_BYTES; lane++) begin
        maximum = $signed(a[lane*8 +: 8]);
        if ($signed(b[lane*8 +: 8]) > maximum) maximum = $signed(b[lane*8 +: 8]);
        if ($signed(c[lane*8 +: 8]) > maximum) maximum = $signed(c[lane*8 +: 8]);
        if ($signed(d[lane*8 +: 8]) > maximum) maximum = $signed(d[lane*8 +: 8]);
        max4[lane*8 +: 8] = maximum;
      end
    end
  endfunction

  // One-vector buffer between the pool and the downstream writer.  A pending
  // pooled result stalls the input only until the downstream consumes it.
  assign vector_ready = !emit_pending || pooled_ready;
  assign pooled_valid = emit_pending;
  assign pooled_data = pooled_reg;
  assign pooled_last = emit_pending && last_reg;

  /* verilator lint_off WIDTHTRUNC */
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      row <= '0;
      col <= '0;
      row_parity <= 1'b0;
      emit_pending <= 1'b0;
      cur_prev <= '0;
      prev_line0 <= '0;
      pooled_reg <= '0;
      last_reg <= 1'b0;
    end else begin
      if (frame_start) begin
        row <= '0;
        col <= '0;
        row_parity <= 1'b0;
        emit_pending <= 1'b0;
        last_reg <= 1'b0;
      end
      if (emit_pending && pooled_ready) emit_pending <= 1'b0;

      if (vector_valid && vector_ready) begin
        cur_prev <= vector_data;
        prev_line0 <= line0[col];

        if (!row_parity) line0[col] <= vector_data;

        if (row_parity && col[0]) begin
          pooled_reg <= max4(prev_line0, line0[col], cur_prev, vector_data);
          last_reg <= (row == image_height - 1'b1) &&
                      (col == image_width - 1'b1);
          emit_pending <= 1'b1;
        end

        if (col == image_width - 1'b1) begin
          col <= '0;
          row <= row + 1'b1;
          row_parity <= ~row_parity;
        end else begin
          col <= col + 1'b1;
        end
      end
    end
  end
  /* verilator lint_on WIDTHTRUNC */
endmodule
