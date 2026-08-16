// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Fixed-latency TFLite-style per-output-channel requantization. The MAC tile
// keeps its INT32 accumulators local; this unit consumes one completed vector,
// applies the Q31 multiplier and rounding rule used by LiteRT, then fuses the
// output zero point and optional ReLU clamp before the result reaches SRAM.
`timescale 1ns/1ps
module gestureflow_requant_relu #(
  parameter int LANES = 16
) (
  input  logic clk,
  input  logic rst_n,

  input  logic in_valid,
  output logic in_ready,
  input  logic signed [LANES-1:0][31:0] in_psum,
  input  logic [LANES-1:0] in_lane_enable,

  input  logic enable,
  input  logic relu_enable,
  input  logic signed [7:0] output_zero_point,
  input  logic signed [LANES-1:0][31:0] multiplier,
  // This first baseline supports the common convolution case where the
  // post-accumulator real multiplier is below one: Q31 high-multiply followed
  // by an explicit right shift in [0,31]. The descriptor rejects larger
  // shifts rather than silently producing a different numerical result.
  input  logic [LANES-1:0][5:0] right_shift,

  output logic out_valid,
  input  logic out_ready,
  output logic signed [LANES-1:0][7:0] out_data,
  output logic [LANES-1:0] out_lane_enable,
  output logic config_error
);

  logic signed [LANES-1:0][7:0] quantized_data_comb;

  function automatic logic signed [31:0] trunc_shift31(
    input logic signed [63:0] value
  );
    logic signed [63:0] magnitude;
    begin
      // SystemVerilog >>> rounds negative values down; TFLite's reference
      // integer division truncates toward zero, so handle the sign directly.
      if (value < 0) begin
        magnitude = -value;
        trunc_shift31 = -$signed(magnitude[62:31]);
      end else begin
        trunc_shift31 = $signed(value[62:31]);
      end
    end
  endfunction

  function automatic logic signed [31:0] saturating_rounding_doubling_high_mul(
    input logic signed [31:0] left,
    input logic signed [31:0] right
  );
    logic signed [63:0] product;
    logic signed [63:0] nudge;
    begin
      if ((left == 32'sh8000_0000) && (right == 32'sh8000_0000)) begin
        saturating_rounding_doubling_high_mul = 32'sh7fff_ffff;
      end else begin
        product = left * right;
        nudge = (product >= 0) ? 64'sh0000_0000_4000_0000
                               : -64'sh0000_0000_3fff_ffff;
        saturating_rounding_doubling_high_mul = trunc_shift31(product + nudge);
      end
    end
  endfunction

  function automatic logic signed [31:0] rounding_divide_by_pot(
    input logic signed [31:0] value,
    input logic [5:0] shift
  );
    logic [31:0] mask;
    logic [31:0] remainder;
    logic [31:0] threshold;
    logic signed [31:0] shifted_base;
    begin
      if (shift == 0) begin
        rounding_divide_by_pot = value;
      end else begin
        mask = (32'h1 << shift) - 1'b1;
        remainder = value & mask;
        threshold = (mask >> 1) + ((value < 0) ? 1 : 0);
        shifted_base = $signed(value) >>> shift;
        rounding_divide_by_pot = shifted_base;
        if (remainder > threshold) rounding_divide_by_pot = shifted_base + 32'sd1;
      end
    end
  endfunction

  function automatic logic signed [7:0] requantize_lane(
    input logic signed [31:0] accumulator,
    input logic signed [31:0] lane_multiplier,
    input logic [5:0] lane_right_shift,
    input logic signed [7:0] zero_point,
    input logic apply_relu
  );
    logic signed [31:0] scaled;
    logic signed [31:0] shifted;
    logic signed [31:0] with_zero_point;
    logic signed [31:0] zero_extended;
    begin
      scaled = saturating_rounding_doubling_high_mul(accumulator, lane_multiplier);
      shifted = rounding_divide_by_pot(scaled, lane_right_shift);
      zero_extended = {{24{zero_point[7]}}, zero_point};
      with_zero_point = shifted + zero_extended;
      if (apply_relu && (with_zero_point < zero_extended)) begin
        requantize_lane = zero_point;
      end else if (with_zero_point > 127) begin
        requantize_lane = 8'sh7f;
      end else if (with_zero_point < -128) begin
        requantize_lane = -8'sh80;
      end else begin
        requantize_lane = with_zero_point[7:0];
      end
    end
  endfunction

  assign in_ready = !out_valid || out_ready;

  always_comb begin
    quantized_data_comb = '0;
    for (int lane = 0; lane < LANES; lane++) begin
      if (right_shift[lane] > 31) begin
        quantized_data_comb[lane] = '0;
      end else if (!in_lane_enable[lane]) begin
        quantized_data_comb[lane] = '0;
      end else if (enable) begin
        quantized_data_comb[lane] = requantize_lane(
          in_psum[lane], multiplier[lane], right_shift[lane],
          output_zero_point, relu_enable
        );
      end else begin
        if (in_psum[lane] > 127) quantized_data_comb[lane] = 8'sh7f;
        else if (in_psum[lane] < -128) quantized_data_comb[lane] = -8'sh80;
        else quantized_data_comb[lane] = in_psum[lane][7:0];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_data <= '0;
      out_lane_enable <= '0;
      config_error <= 1'b0;
    end else begin
      if (out_valid && out_ready) begin
        out_valid <= 1'b0;
      end
      if (in_valid && in_ready) begin
        out_valid <= 1'b1;
        out_lane_enable <= in_lane_enable;
        out_data <= quantized_data_comb;
        for (int lane = 0; lane < LANES; lane++) begin
          if (right_shift[lane] > 31) config_error <= 1'b1;
        end
      end
    end
  end
endmodule
