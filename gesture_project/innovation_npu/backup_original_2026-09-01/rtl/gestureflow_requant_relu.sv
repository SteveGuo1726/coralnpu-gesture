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
  // A vector is processed as fixed-size blocks. The first stage registers the
  // full 64-bit product, allowing Vivado to use the DSP48 P register; the
  // second stage performs high-word rounding from that registered product.
  // This cuts the product-to-result carry chain without adding another DSP.
  logic signed [PARALLEL_LANES-1:0][63:0] product_pipe;
  logic [PARALLEL_LANES-1:0] product_special_case;
  logic product_valid;
  logic product_last;
  logic signed [PARALLEL_LANES-1:0][31:0] product_psum_chunk;
  logic [PARALLEL_LANES-1:0] product_lane_enable_chunk;
  logic [PARALLEL_LANES-1:0][5:0] product_right_shift_chunk;
  logic signed [PARALLEL_LANES-1:0][31:0] prefetched_psum_chunk;
  logic signed [PARALLEL_LANES-1:0][31:0] prefetched_multiplier_chunk;
  logic [PARALLEL_LANES-1:0] prefetched_lane_enable_chunk;
  logic [PARALLEL_LANES-1:0][5:0] prefetched_right_shift_chunk;
  logic signed [PARALLEL_LANES-1:0][63:0] product_comb;
  logic [PARALLEL_LANES-1:0] product_special_comb;
  logic signed [PARALLEL_LANES-1:0][31:0] chunk_mul_result;
  logic result_valid;
  logic result_last;
  logic signed [PARALLEL_LANES-1:0][31:0] result_psum_chunk;
  logic [PARALLEL_LANES-1:0] result_lane_enable_chunk;
  logic [PARALLEL_LANES-1:0][5:0] result_right_shift_chunk;
  logic [CHUNK_W-1:0] result_chunk_index;
  logic signed [PARALLEL_LANES-1:0][31:0] chunk_mul_comb;
  logic signed [PARALLEL_LANES-1:0][7:0] chunk_data_comb;
  // Stage-3a registers: split the long rounding_divide_by_pot + zero-point +
  // saturate path into a registered rounded value followed by a short
  // add-and-saturate. This shortens the routed critical path on 7020.
  logic signed [PARALLEL_LANES-1:0][31:0] shifted_comb;
  logic shift_config_error_comb;
  logic signed [PARALLEL_LANES-1:0][31:0] shifted_value;
  logic [PARALLEL_LANES-1:0] shifted_requant;
  logic [PARALLEL_LANES-1:0] shifted_lane_enable;
  logic shift_valid;
  logic shift_last;
  logic [CHUNK_W-1:0] shift_chunk_index;
  logic shift_config_error;

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

  function automatic logic signed [31:0] high_mul_from_product(
    input logic signed [63:0] product,
    input logic special_case
  );
    logic signed [63:0] nudge;
    logic signed [63:0] adjusted;
    begin
      if (special_case) begin
        high_mul_from_product = 32'sh7fff_ffff;
      end else begin
        nudge = (product >= 0) ? 64'sh0000_0000_4000_0000
                               : -64'sh0000_0000_3fff_ffff;
        adjusted = product + nudge;
        high_mul_from_product = trunc_shift31(adjusted);
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
      // A runtime `value >>> shift` became a long barrel-shifter path in the
      // 32-lane OOC netlist. This explicit decode preserves the exact TFLite
      // rounding contract while giving synthesis a bounded 32-to-1 choice,
      // rather than an unconstrained arithmetic-shift implementation.
      mask = 32'h0;
      shifted_base = value;
      case (shift)
        6'd0:  begin mask = 32'h00000000; shifted_base = value >>> 0;  end
        6'd1:  begin mask = 32'h00000001; shifted_base = value >>> 1;  end
        6'd2:  begin mask = 32'h00000003; shifted_base = value >>> 2;  end
        6'd3:  begin mask = 32'h00000007; shifted_base = value >>> 3;  end
        6'd4:  begin mask = 32'h0000000f; shifted_base = value >>> 4;  end
        6'd5:  begin mask = 32'h0000001f; shifted_base = value >>> 5;  end
        6'd6:  begin mask = 32'h0000003f; shifted_base = value >>> 6;  end
        6'd7:  begin mask = 32'h0000007f; shifted_base = value >>> 7;  end
        6'd8:  begin mask = 32'h000000ff; shifted_base = value >>> 8;  end
        6'd9:  begin mask = 32'h000001ff; shifted_base = value >>> 9;  end
        6'd10: begin mask = 32'h000003ff; shifted_base = value >>> 10; end
        6'd11: begin mask = 32'h000007ff; shifted_base = value >>> 11; end
        6'd12: begin mask = 32'h00000fff; shifted_base = value >>> 12; end
        6'd13: begin mask = 32'h00001fff; shifted_base = value >>> 13; end
        6'd14: begin mask = 32'h00003fff; shifted_base = value >>> 14; end
        6'd15: begin mask = 32'h00007fff; shifted_base = value >>> 15; end
        6'd16: begin mask = 32'h0000ffff; shifted_base = value >>> 16; end
        6'd17: begin mask = 32'h0001ffff; shifted_base = value >>> 17; end
        6'd18: begin mask = 32'h0003ffff; shifted_base = value >>> 18; end
        6'd19: begin mask = 32'h0007ffff; shifted_base = value >>> 19; end
        6'd20: begin mask = 32'h000fffff; shifted_base = value >>> 20; end
        6'd21: begin mask = 32'h001fffff; shifted_base = value >>> 21; end
        6'd22: begin mask = 32'h003fffff; shifted_base = value >>> 22; end
        6'd23: begin mask = 32'h007fffff; shifted_base = value >>> 23; end
        6'd24: begin mask = 32'h00ffffff; shifted_base = value >>> 24; end
        6'd25: begin mask = 32'h01ffffff; shifted_base = value >>> 25; end
        6'd26: begin mask = 32'h03ffffff; shifted_base = value >>> 26; end
        6'd27: begin mask = 32'h07ffffff; shifted_base = value >>> 27; end
        6'd28: begin mask = 32'h0fffffff; shifted_base = value >>> 28; end
        6'd29: begin mask = 32'h1fffffff; shifted_base = value >>> 29; end
        6'd30: begin mask = 32'h3fffffff; shifted_base = value >>> 30; end
        6'd31: begin mask = 32'h7fffffff; shifted_base = value >>> 31; end
        default: begin mask = 32'hffffffff; shifted_base = value >>> 31; end
      endcase
      remainder = value & mask;
      threshold = (mask >> 1) + ((value < 0) ? 1 : 0);
      rounding_divide_by_pot = shifted_base;
      if (remainder > threshold) rounding_divide_by_pot = shifted_base + 32'sd1;
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

  // Stage-3b half of round_saturate: apply zero point and saturate to the
  // already-registered rounded value. Keeping the rounding shift in a separate
  // stage removes its case-select fanout from the add/saturate path.
  function automatic logic signed [7:0] saturate_zero_point(
    input logic signed [31:0] shifted,
    input logic signed [7:0] zero_point,
    input logic apply_relu
  );
    logic signed [31:0] with_zero_point;
    logic signed [31:0] zero_extended;
    begin
      zero_extended = {{24{zero_point[7]}}, zero_point};
      with_zero_point = shifted + zero_extended;
      if (apply_relu && (with_zero_point < zero_extended)) begin
        saturate_zero_point = zero_point;
      end else if (with_zero_point > 127) begin
        saturate_zero_point = 8'sh7f;
      end else if (with_zero_point < -128) begin
        saturate_zero_point = -8'sh80;
      end else begin
        saturate_zero_point = with_zero_point[7:0];
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

  // Stage one: form one fixed four-lane product block. The input indices here
  // are fixed; the chunk counter is not in front of the DSP operands.
  // The input indices here are fixed. The only variable-index memory reads
  // happen when the next block is moved into the prefetch registers, so the
  // chunk counter is no longer on the DSP input timing path. A single shared
  // multiplier group handles either live capture or the registered prefetch;
  // duplicating the two branches would waste four DSP48E1 blocks.
  always_comb begin
    logic signed [31:0] selected_psum;
    logic signed [31:0] selected_multiplier;
    logic selected_enable;
    product_comb = '0;
    product_special_comb = '0;
    for (int lane_off = 0; lane_off < PARALLEL_LANES; lane_off++) begin
      if (processing) begin
        selected_psum = prefetched_psum_chunk[lane_off];
        selected_multiplier = prefetched_multiplier_chunk[lane_off];
        selected_enable = pending_enable && prefetched_lane_enable_chunk[lane_off];
      end else begin
        selected_psum = in_psum[lane_off];
        selected_multiplier = multiplier[lane_off];
        selected_enable = enable && in_lane_enable[lane_off];
      end
      if (selected_enable) begin
        product_comb[lane_off] = $signed(selected_psum) * $signed(selected_multiplier);
        product_special_comb[lane_off] =
          (selected_psum == 32'sh8000_0000) &&
          (selected_multiplier == 32'sh8000_0000);
      end
    end
  end

  // Stage two: high-word rounding starts from the registered DSP product.
  // The carry chain here is only the 64-bit product-plus-nudge reduction and
  // is no longer combined with the multiplier itself.
  always_comb begin
    chunk_mul_comb = '0;
    for (int lane_off = 0; lane_off < PARALLEL_LANES; lane_off++) begin
      if (product_valid) begin
        chunk_mul_comb[lane_off] = high_mul_from_product(
          product_pipe[lane_off], product_special_case[lane_off]
        );
      end
    end
  end

  // Stage three: round/saturate the registered high-mul result. Metadata is
  // delayed with the result so the extra arithmetic stage cannot misalign a
  // lane's scale, zero point, or pass-through mode.
  always_comb begin
    // Stage 3a: rounded value. Requant lanes do the rounding shift; pass-through
    // lanes simply carry their accumulator through to the saturator.
    shifted_comb = '0;
    shift_config_error_comb = 1'b0;
    for (int lane_off = 0; lane_off < PARALLEL_LANES; lane_off++) begin
      if (result_right_shift_chunk[lane_off] > 31) shift_config_error_comb = 1'b1;
      if (pending_enable && result_lane_enable_chunk[lane_off]) begin
        shifted_comb[lane_off] = rounding_divide_by_pot(
          chunk_mul_result[lane_off], result_right_shift_chunk[lane_off]
        );
      end else begin
        shifted_comb[lane_off] = result_psum_chunk[lane_off];
      end
    end

    // Stage 3b: zero point + saturation, fed from the registered shifted value.
    chunk_data_comb = '0;
    for (int lane_off = 0; lane_off < PARALLEL_LANES; lane_off++) begin
      if (!shifted_lane_enable[lane_off]) begin
        chunk_data_comb[lane_off] = '0;
      end else if (shifted_requant[lane_off]) begin
        chunk_data_comb[lane_off] = saturate_zero_point(
          shifted_value[lane_off],
          pending_output_zero_point, pending_relu_enable
        );
      end else begin
        chunk_data_comb[lane_off] = passthrough_lane(shifted_value[lane_off]);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      processing <= 1'b0;
      lane_chunk_index <= '0;
      chunk_mul_result <= '0;
      product_pipe <= '0;
      product_special_case <= '0;
      product_valid <= 1'b0;
      product_last <= 1'b0;
      product_psum_chunk <= '0;
      product_lane_enable_chunk <= '0;
      product_right_shift_chunk <= '0;
      prefetched_psum_chunk <= '0;
      prefetched_multiplier_chunk <= '0;
      prefetched_lane_enable_chunk <= '0;
      prefetched_right_shift_chunk <= '0;
      result_valid <= 1'b0;
      result_last <= 1'b0;
      result_psum_chunk <= '0;
      result_lane_enable_chunk <= '0;
      result_right_shift_chunk <= '0;
      result_chunk_index <= '0;
      shifted_value <= '0;
      shifted_requant <= '0;
      shifted_lane_enable <= '0;
      shift_valid <= 1'b0;
      shift_last <= 1'b0;
      shift_chunk_index <= '0;
      shift_config_error <= 1'b0;
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
        // Capture product block zero and prefetch block one. These are fixed
        // input slices, so no runtime block-index mux is introduced at start.
        for (int lane_off = 0; lane_off < PARALLEL_LANES; lane_off++) begin
          product_pipe[lane_off] <= product_comb[lane_off];
          product_special_case[lane_off] <= product_special_comb[lane_off];
          product_psum_chunk[lane_off] <= in_psum[lane_off];
          product_lane_enable_chunk[lane_off] <= in_lane_enable[lane_off];
          product_right_shift_chunk[lane_off] <= right_shift[lane_off];
          if ((PARALLEL_LANES + lane_off) < LANES) begin
            prefetched_psum_chunk[lane_off] <= in_psum[PARALLEL_LANES + lane_off];
            prefetched_multiplier_chunk[lane_off] <= multiplier[PARALLEL_LANES + lane_off];
            prefetched_lane_enable_chunk[lane_off] <= in_lane_enable[PARALLEL_LANES + lane_off];
            prefetched_right_shift_chunk[lane_off] <= right_shift[PARALLEL_LANES + lane_off];
          end else begin
            prefetched_psum_chunk[lane_off] <= '0;
            prefetched_multiplier_chunk[lane_off] <= '0;
            prefetched_lane_enable_chunk[lane_off] <= 1'b0;
            prefetched_right_shift_chunk[lane_off] <= '0;
          end
        end
        product_valid <= 1'b1;
        product_last <= (CHUNK_COUNT == 1);
        result_valid <= 1'b0;
        result_chunk_index <= '0;
        shift_valid <= 1'b0;
        shift_chunk_index <= '0;
      end else if (processing) begin
        // Stage 3a: register the rounded value and its metadata so the
        // zero-point add and saturation run in the following cycle.
        if (result_valid) begin
          shifted_value <= shifted_comb;
          shifted_requant <= (pending_enable ? result_lane_enable_chunk : '0);
          shifted_lane_enable <= result_lane_enable_chunk;
          shift_valid <= 1'b1;
          shift_last <= result_last;
          shift_chunk_index <= result_chunk_index;
          shift_config_error <= shift_config_error_comb;
          if (!result_last) result_chunk_index <= result_chunk_index + 1'b1;
        end

        // Stage 3b: consume the registered rounded value.
        if (shift_valid) begin
          for (int lane_off = 0; lane_off < PARALLEL_LANES; lane_off++) begin
            if ((int'(shift_chunk_index) * PARALLEL_LANES + lane_off) < LANES) begin
              out_data[int'(shift_chunk_index) * PARALLEL_LANES + lane_off] <= chunk_data_comb[lane_off];
            end
          end
          if (shift_config_error) config_error <= 1'b1;
          if (shift_last) begin
            processing <= 1'b0;
            out_valid <= 1'b1;
            shift_valid <= 1'b0;
          end
        end

        // Stage two consumes the registered product and creates one result
        // block per cycle. The result-valid/last flags provide the one-cycle
        // latency bubble only at the beginning and end of a vector.
        result_valid <= product_valid;
        if (product_valid) begin
          chunk_mul_result <= chunk_mul_comb;
          result_last <= product_last;
          result_psum_chunk <= product_psum_chunk;
          result_lane_enable_chunk <= product_lane_enable_chunk;
          result_right_shift_chunk <= product_right_shift_chunk;
        end

        if (product_valid && !product_last) begin
          // Feed the already captured next product block and advance the
          // producer side. Output-side result_chunk_index advances separately.
          for (int lane_off = 0; lane_off < PARALLEL_LANES; lane_off++) begin
            product_pipe[lane_off] <= product_comb[lane_off];
            product_special_case[lane_off] <= product_special_comb[lane_off];
            product_psum_chunk[lane_off] <= prefetched_psum_chunk[lane_off];
            product_lane_enable_chunk[lane_off] <= prefetched_lane_enable_chunk[lane_off];
            product_right_shift_chunk[lane_off] <= prefetched_right_shift_chunk[lane_off];
            if (((int'(lane_chunk_index) + 2) * PARALLEL_LANES + lane_off) < LANES) begin
              prefetched_psum_chunk[lane_off] <= pending_psum[(int'(lane_chunk_index) + 2) * PARALLEL_LANES + lane_off];
              prefetched_multiplier_chunk[lane_off] <= pending_multiplier[(int'(lane_chunk_index) + 2) * PARALLEL_LANES + lane_off];
              prefetched_lane_enable_chunk[lane_off] <= pending_lane_enable[(int'(lane_chunk_index) + 2) * PARALLEL_LANES + lane_off];
              prefetched_right_shift_chunk[lane_off] <= pending_right_shift[(int'(lane_chunk_index) + 2) * PARALLEL_LANES + lane_off];
            end else begin
              prefetched_psum_chunk[lane_off] <= '0;
              prefetched_multiplier_chunk[lane_off] <= '0;
              prefetched_lane_enable_chunk[lane_off] <= 1'b0;
              prefetched_right_shift_chunk[lane_off] <= '0;
            end
          end
          product_last <= (lane_chunk_index == CHUNK_W'(CHUNK_COUNT - 2));
          lane_chunk_index <= lane_chunk_index + 1'b1;
        end else if (product_valid) begin
          product_valid <= 1'b0;
        end
      end
    end
  end
endmodule
