// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Tile-local GAP accumulator for head_1x1 outputs.
//
// The module consumes one 16-lane quantized tile stream, accumulates the
// spatial sum locally, applies LiteRT-style requantization, and emits the
// tile's 16 GAP results without requiring the intermediate tile tensor to be
// written back to DDR.
`timescale 1ns/1ps
module gestureflow_head_tile_gap_accumulator #(
  parameter int LANES = 16,
  parameter int PIXEL_COUNT_W = 14
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic clear,
  input  logic [PIXEL_COUNT_W-1:0] pixel_count,
  input  logic signed [31:0] gap_multiplier,
  input  logic [5:0] gap_right_shift,
  input  logic signed [7:0] gap_input_zero_point,
  input  logic signed [7:0] gap_output_zero_point,
  input  logic signed [LANES-1:0][7:0] pixel_data,
  input  logic pixel_valid,
  output logic pixel_ready,
  output logic gap_valid,
  output logic signed [LANES-1:0][7:0] gap_data,
  output logic [PIXEL_COUNT_W-1:0] pixels_seen,
  output logic busy,
  output logic done,
  output logic fault
);
  localparam logic signed [31:0] GAP_ELEMENTS = 32'sd144;

  typedef enum logic [1:0] {IDLE, ACCUM, QUANT, EMIT} state_t;
  state_t state;
  logic signed [LANES-1:0][31:0] gap_sum;
  logic [PIXEL_COUNT_W-1:0] pixel_index;
  logic signed [LANES-1:0][7:0] gap_emit_data;
  logic signed [31:0] gap_bias_correction;

  function automatic logic signed [31:0] trunc_shift31(input logic signed [63:0] value);
    logic signed [63:0] magnitude;
    begin
      if (value < 0) begin
        magnitude = -value;
        trunc_shift31 = -$signed(magnitude[62:31]);
      end else begin
        trunc_shift31 = $signed(value[62:31]);
      end
    end
  endfunction

  function automatic logic signed [31:0] high_mul(
    input logic signed [31:0] left,
    input logic signed [31:0] right
  );
    logic signed [63:0] product, nudge;
    begin
      if ((left == 32'sh80000000) && (right == 32'sh80000000)) high_mul = 32'sh7fffffff;
      else begin
        product = left * right;
        nudge = product >= 0 ? 64'sh0000000040000000 : -64'sh000000003fffffff;
        high_mul = trunc_shift31(product + nudge);
      end
    end
  endfunction

  function automatic logic signed [31:0] round_div_pot(
    input logic signed [31:0] value,
    input logic [5:0] shift
  );
    logic [31:0] mask, remainder, threshold;
    logic signed [31:0] base;
    begin
      if (shift == 0) round_div_pot = value;
      else begin
        mask = (32'h1 << shift) - 1'b1;
        remainder = value & mask;
        threshold = (mask >> 1) + (value < 0 ? 1 : 0);
        base = value >>> shift;
        round_div_pot = remainder > threshold ? base + 1 : base;
      end
    end
  endfunction

  function automatic logic signed [7:0] requantize(
    input logic signed [31:0] accumulator,
    input logic signed [31:0] multiplier,
    input logic [5:0] right_shift,
    input logic signed [7:0] zero_point
  );
    logic signed [31:0] result, with_zero_point;
    begin
      result = round_div_pot(high_mul(accumulator, multiplier), right_shift);
      with_zero_point = result + {{24{zero_point[7]}}, zero_point};
      if (with_zero_point > 127) requantize = 8'sh7f;
      else if (with_zero_point < -128) requantize = -8'sh80;
      else requantize = with_zero_point[7:0];
    end
  endfunction

  assign busy = (state != IDLE);
  assign pixel_ready = (state == ACCUM);
  assign pixels_seen = pixel_index;

  always_comb begin
    gap_bias_correction = sign_extend_int8(gap_input_zero_point) * GAP_ELEMENTS;
  end

  function automatic logic signed [31:0] sign_extend_int8(input logic signed [7:0] value);
    sign_extend_int8 = {{24{value[7]}}, value};
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      gap_sum <= '0;
      pixel_index <= '0;
      gap_emit_data <= '0;
      gap_valid <= 1'b0;
      gap_data <= '0;
      done <= 1'b0;
      fault <= 1'b0;
    end else if (clear) begin
      state <= IDLE;
      gap_sum <= '0;
      pixel_index <= '0;
      gap_emit_data <= '0;
      gap_valid <= 1'b0;
      gap_data <= '0;
      done <= 1'b0;
      fault <= 1'b0;
    end else begin
      done <= 1'b0;

      case (state)
        IDLE: begin
          if (start) begin
            if (pixel_count == 0) begin
              fault <= 1'b1;
            end else begin
              gap_sum <= '0;
              pixel_index <= '0;
              gap_emit_data <= '0;
              fault <= 1'b0;
              state <= ACCUM;
            end
          end
        end
        ACCUM: begin
          if (pixel_valid && pixel_ready) begin
            for (int lane = 0; lane < LANES; lane++) begin
              gap_sum[lane] <= gap_sum[lane] + {{24{pixel_data[lane][7]}}, pixel_data[lane]};
            end
            if (pixel_index + 1'b1 >= pixel_count) begin
              pixel_index <= '0;
              state <= QUANT;
            end else begin
              pixel_index <= pixel_index + 1'b1;
            end
          end
        end
        QUANT: begin
          for (int lane = 0; lane < LANES; lane++) begin
            gap_emit_data[lane] <= requantize(
              gap_sum[lane] - gap_bias_correction,
              gap_multiplier, gap_right_shift, gap_output_zero_point
            );
          end
          state <= EMIT;
        end
        EMIT: begin
          gap_valid <= 1'b1;
          gap_data <= gap_emit_data;
          done <= 1'b1;
          state <= IDLE;
        end
        default: begin
          fault <= 1'b1;
          state <= IDLE;
        end
      endcase
    end
  end
endmodule
