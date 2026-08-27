// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Fixed-latency TFLite-style per-output-channel requantization. The original
// 16-lane fully parallel version spent one 32x32 requant multiplier per lane
// even though the upstream engines produce a completed vector only every many
// MAC cycles, so this version time-multiplexes a smaller lane group.
//
// The requantize arithmetic is split into two pipeline stages: stage one
// registers the saturating_rounding_doubling_high_mul (DSP48 cascade) and
// stage two performs rounding_divide_by_pot plus zero-point/saturation. This
// removes the 32-bit ripple-carry chain from the DSP48 cascade and takes the
// requantizer off the top routed setup path on 7020.
`timescale 1ns/1ps
module gestureflow_requant_relu #(
  parameter int LANES = 16,
  parameter int PARALLEL_LANES = 4
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
  input  logic [LANES-1:0][5:0] right_shift,

  output logic out_valid,
  input  logic out_ready,
  output logic signed [LANES-1:0][7:0] out_data,
  output logic [LANES-1:0] out_lane_enable,
  output logic config_error
);

  localparam int CHUNK_COUNT = (LANES + PARALLEL_LANES - 1) / PARALLEL_LANES;
  localparam int CHUNK_W = (CHUNK_COUNT <= 1) ? 1 : $clog2(CHUNK_COUNT);

  logic processing;
  logic [CHUNK_W-1:0] lane_chunk_index;
  logic signed [31:0] pending_psum [0:LANES-1];
  logic pending_lane_enable [0:LANES-1];
  logic signed [31:0] pending_multiplier [0:LANES-1];
  logic [5:0] pending_right_shift [0:LANES-1];
  logic pending_enable;
  logic pending_relu_enable;
  logic signed [7:0] pending_output_zero_point;
  // Stage-one output: registered high_mul for the chunk currently rounded.
  logic signed [PARALLEL_LANES-1:0][31:0] chunk_mul_result;
  // Stage-one combinational result for the NEXT chunk to prime the pipeline.
  logic signed [PARALLEL_LANES-1:0][31:0] chunk_mul_comb;
  logic signed [PARALLEL_LANES-1:0][7:0] chunk_data_comb;
  logic chunk_config_error_comb;

  initial begin
    if ((PARALLEL_LANES <= 0) || (PARALLEL_LANES > LANES)) begin
      $error("gestureflow_requant_relu PARALLEL_LANES must be in [1, LANES]");
    end
  end

  function automatic logic signed [31:0] trunc_shift31(
    input logic signed [63:0] value
  );
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

  // Stage two: consume the registered high_mul result and finish the
  // rounding/zero-point/saturation. It does not recompute the multiply, so the
  // DSP48 cascade is not on this path.
  function automatic logic signed [7:0] round_saturate(
    input logic signed [31:0] mul_result,
    input logic [5:0] lane_right_shift,
    input logic signed [7:0] zero_point,
    input logic apply_relu
  );
    logic signed [31:0] shifted;
    logic signed [31:0] with_zero_point;
    logic signed [31:0] zero_extended;
    begin
      shifted = rounding_divide_by_pot(mul_result, lane_right_shift);
      zero_extended = {{24{zero_point[7]}}, zero_point};
      with_zero_point = shifted + zero_extended;
      if (apply_relu && (with_zero_point < zero_extended)) begin
        round_saturate = zero_point;
      end else if (with_zero_point > 127) begin
        round_saturate = 8'sh7f;
      end else if (with_zero_point < -128) begin
        round_saturate = -8'sh80;
      end else begin
        round_saturate = with_zero_point[7:0];
      end
    end
  endfunction

  function automatic logic signed [7:0] passthrough_lane(
    input logic signed [31:0] accumulator
  );
    begin
      if (accumulator > 127) passthrough_lane = 8'sh7f;
      else if (accumulator < -128) passthrough_lane = -8'sh80;
      else passthrough_lane = accumulator[7:0];
    end
  endfunction

  assign in_ready = !processing && !out_valid;

  // Stage one: high_mul for the chunk to prime next. In the capture cycle it
  // reads the live inputs for chunk zero; during processing it reads the
  // captured inputs for lane_chunk_index + 1. Keeping the multiply in a
  // combinational block instead of inside the sequential priming keeps the
  // 64-bit high-mul out of the always_ff path.
  always_comb begin
    logic [CHUNK_W:0] mul_index;
    logic signed [31:0] mul_psum_arr [0:LANES-1];
    logic signed [31:0] mul_multiplier_arr [0:LANES-1];
    logic mul_lane_enable_arr [0:LANES-1];
    logic mul_enable;

    mul_index = processing ? (CHUNK_W + 1)'(lane_chunk_index) + 1'b1 : {CHUNK_W + 1{1'b0}};
    if (!processing) begin
      for (int lane = 0; lane < LANES; lane++) begin
        mul_psum_arr[lane] = in_psum[lane];
        mul_multiplier_arr[lane] = multiplier[lane];
        mul_lane_enable_arr[lane] = in_lane_enable[lane];
      end
      mul_enable = enable;
    end else begin
      for (int lane = 0; lane < LANES; lane++) begin
        mul_psum_arr[lane] = pending_psum[lane];
        mul_multiplier_arr[lane] = pending_multiplier[lane];
        mul_lane_enable_arr[lane] = pending_lane_enable[lane];
      end
      mul_enable = pending_enable;
    end

    chunk_mul_comb = '0;
    for (int lane_off = 0; lane_off < PARALLEL_LANES; lane_off++) begin
      int lane_index = int'(mul_index) * PARALLEL_LANES + lane_off;
      if ((lane_index < LANES) && mul_enable && mul_lane_enable_arr[lane_index]) begin
        chunk_mul_comb[lane_off] = saturating_rounding_doubling_high_mul(
          mul_psum_arr[lane_index], mul_multiplier_arr[lane_index]
        );
      end
    end
  end

  // Stage two: round/saturate the chunk selected by lane_chunk_index using
  // the registered stage-one result.
  always_comb begin
    chunk_data_comb = '0;
    chunk_config_error_comb = 1'b0;
    for (int lane_off = 0; lane_off < PARALLEL_LANES; lane_off++) begin
      int lane_index = int'(lane_chunk_index) * PARALLEL_LANES + lane_off;
      if (lane_index < LANES) begin
        if (pending_right_shift[lane_index] > 31) begin
          chunk_data_comb[lane_off] = '0;
          chunk_config_error_comb = 1'b1;
        end else if (!pending_lane_enable[lane_index]) begin
          chunk_data_comb[lane_off] = '0;
        end else if (pending_enable) begin
          chunk_data_comb[lane_off] = round_saturate(
            chunk_mul_result[lane_off], pending_right_shift[lane_index],
            pending_output_zero_point, pending_relu_enable
          );
        end else begin
          chunk_data_comb[lane_off] = passthrough_lane(pending_psum[lane_index]);
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      processing <= 1'b0;
      lane_chunk_index <= '0;
      chunk_mul_result <= '0;
      for (int lane = 0; lane < LANES; lane++) begin
        pending_psum[lane] <= '0;
        pending_lane_enable[lane] <= 1'b0;
        pending_multiplier[lane] <= '0;
        pending_right_shift[lane] <= '0;
      end
      pending_enable <= 1'b0;
      pending_relu_enable <= 1'b0;
      pending_output_zero_point <= '0;
      out_valid <= 1'b0;
      out_data <= '0;
      out_lane_enable <= '0;
      config_error <= 1'b0;
    end else begin
      if (out_valid && out_ready) begin
        out_valid <= 1'b0;
      end

      if (in_valid && in_ready) begin
        for (int lane = 0; lane < LANES; lane++) begin
          pending_psum[lane] <= in_psum[lane];
          pending_lane_enable[lane] <= in_lane_enable[lane];
          pending_multiplier[lane] <= multiplier[lane];
          pending_right_shift[lane] <= right_shift[lane];
        end
        pending_enable <= enable;
        pending_relu_enable <= relu_enable;
        pending_output_zero_point <= output_zero_point;
        lane_chunk_index <= '0;
        processing <= 1'b1;
        out_data <= '0;
        out_lane_enable <= in_lane_enable;
        // Prime stage one for chunk zero. chunk_mul_comb reads the live
        // inputs in this (not yet processing) cycle.
        chunk_mul_result <= chunk_mul_comb;
      end else if (processing) begin
        for (int lane = 0; lane < LANES; lane++) begin
          if ((lane / PARALLEL_LANES) == int'(lane_chunk_index)) begin
            out_data[lane] <= chunk_data_comb[lane % PARALLEL_LANES];
          end
        end
        if (chunk_config_error_comb) config_error <= 1'b1;
        // Prime stage one for the following chunk from the captured inputs.
        chunk_mul_result <= chunk_mul_comb;

        if (lane_chunk_index == CHUNK_W'(CHUNK_COUNT - 1)) begin
          processing <= 1'b0;
          out_valid <= 1'b1;
        end else begin
          lane_chunk_index <= lane_chunk_index + 1'b1;
        end
      end
    end
  end
endmodule
