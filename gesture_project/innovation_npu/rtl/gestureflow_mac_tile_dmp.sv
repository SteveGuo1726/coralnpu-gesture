// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// GestureFlow-NPU DMP compute tile.  One accepted input vector performs
// OUT_LANES * INPUT_LANES logical signed INT8 products, but packs two output
// channels into every DSP48E1 multiplier.  For each input lane one DSP takes
//
//   A = w'_even + (w'_odd << 16)     // two offset weights, 16-bit spacing
//   B = a'                           // one offset activation
//
// and produces the 32-bit result
//
//   A * B = w'_even*a' + (w'_odd*a') << 16.
//
// Because each unsigned 8x8 product is at most 0xFE01, the two products are
// cleanly separated by exactly 16 bits.  Signed values are converted with a
// -128 offset; the shared activation correction term -128*sum(a) is added at
// retirement, while the per-channel weight/bias corrections are pre-folded
// into the bias by the exporter.  This is the DMP (Dual-Multiply Packing)
// microarchitecture, not a Google implementation.
`timescale 1ns/1ps
module gestureflow_mac_tile_dmp #(
  parameter int OUT_LANES = 32,
  parameter int INPUT_LANES = 8,
  parameter int MAX_TAPS = 16,
  parameter int MAX_IC_GROUPS = 16
) (
  input  logic clk,
  input  logic rst_n,

  input  logic weight_write_valid,
  input  logic [((OUT_LANES/2) <= 1 ? 1 : $clog2(OUT_LANES/2))-1:0] weight_write_pair,
  input  logic [$clog2(MAX_TAPS)-1:0] weight_write_tap,
  input  logic [(MAX_IC_GROUPS <= 1 ? 1 : $clog2(MAX_IC_GROUPS))-1:0] weight_write_ic_group,
  input  logic [INPUT_LANES*24-1:0] weight_write_data,
  input  logic weight_bank_select,
  input  logic read_bank_select,

  input  logic start_valid,
  output logic start_ready,
  input  logic signed [OUT_LANES-1:0][31:0] bias,
  input  logic [OUT_LANES-1:0] output_lane_enable,

  input  logic mac_valid,
  output logic mac_ready,
  input  logic [$clog2(MAX_TAPS)-1:0] mac_tap,
  input  logic [(MAX_IC_GROUPS <= 1 ? 1 : $clog2(MAX_IC_GROUPS))-1:0] mac_ic_group,
  input  logic signed [INPUT_LANES-1:0][7:0] activation,
  input  logic [INPUT_LANES-1:0] input_lane_enable,
  input  logic mac_last,

  output logic result_valid,
  input  logic result_ready,
  output logic signed [OUT_LANES-1:0][31:0] result_psum,
  output logic [OUT_LANES-1:0] result_lane_enable,
  output logic busy,
  output logic protocol_error
);

  localparam int PAIR_LANES = OUT_LANES / 2;
  localparam int WEIGHT_DEPTH = MAX_TAPS * MAX_IC_GROUPS;
  localparam int WEIGHT_ADDR_W = $clog2(WEIGHT_DEPTH);
  localparam int WEIGHT_DATA_W = INPUT_LANES * 24;
  localparam int PAIR_COUNT = INPUT_LANES / 2;
  localparam int QUAD_COUNT = PAIR_COUNT / 2;

  logic signed [OUT_LANES-1:0][31:0] accum;
  logic [OUT_LANES-1:0] active_output_lanes;
  logic signed [31:0] activation_sum;

  logic [WEIGHT_ADDR_W:0] weight_write_addr;
  logic [WEIGHT_ADDR_W-1:0] mac_weight_addr;
  logic [WEIGHT_ADDR_W:0] weight_addr_s0;
  logic signed [INPUT_LANES-1:0][7:0] activation_s0;
  logic signed [INPUT_LANES-1:0][7:0] activation_s1;
  logic [INPUT_LANES-1:0] input_lane_enable_s0;
  logic [INPUT_LANES-1:0] input_lane_enable_s1;
  logic [OUT_LANES-1:0] output_lanes_s0;
  logic [OUT_LANES-1:0] output_lanes_s1;
  logic s0_valid, s0_last;
  logic s1_valid, s1_last;

  logic [WEIGHT_DATA_W-1:0] weight_pipe [0:PAIR_LANES-1];
  logic [INPUT_LANES-1:0][7:0] activation_offset_s1;
  logic signed [INPUT_LANES-1:0][7:0] activation_s1_padded;
  logic [INPUT_LANES-1:0] input_lane_enable_s1_padded;
  logic signed [31:0] activation_group_sum;

  for (genvar p = 0; p < PAIR_LANES; p++) begin : pair_weight_banks
    gestureflow_weight_bank #(
      .ADDR_W(WEIGHT_ADDR_W + 1),
      .DATA_W(WEIGHT_DATA_W)
    ) weight_bank (
      .clk(clk),
      // Ping-pong preload: compute reads one bank while the opposite bank can
      // accept the next layer's weight DMA.  Writing the live bank is a
      // protocol error, exactly as in the single-product tile.
      .write_enable(weight_write_valid && (weight_write_pair == p[$clog2(PAIR_LANES)-1:0]) &&
                    (!busy || (weight_bank_select != read_bank_select))),
      .write_addr(weight_write_addr),
      .write_data(weight_write_data),
      .read_enable(s0_valid),
      .read_addr(weight_addr_s0),
      .read_data(weight_pipe[p])
    );
  end

  // One DSP product per (output-channel pair, input lane).  The product is
  // signed 43-bit (25x18) by construction, but both operands are positive so
  // the useful part lies in bits [31:0]; bit 42 is an unused sign/extension
  // bit and is never used in the add tree below.
  (* use_dsp = "yes" *) logic signed [PAIR_LANES-1:0][INPUT_LANES-1:0][42:0] product_comb;
  (* use_dsp = "yes" *) logic signed [PAIR_LANES-1:0][INPUT_LANES-1:0][42:0] product_pipe;
  logic product_valid;
  logic product_last;
  logic [OUT_LANES-1:0] product_output_lanes;

  // Each unsigned low/high partial is 16 bits.  Two fit in 17 bits, four in
  // 18 bits, eight in 19 bits; these are the smallest exact widths and keep
  // the registered add tree from inflating XC7Z020 carry chains.
  logic [PAIR_LANES-1:0][PAIR_COUNT-1:0][16:0] pair_sum_low_pipe;
  logic [PAIR_LANES-1:0][PAIR_COUNT-1:0][16:0] pair_sum_high_pipe;
  logic pair_valid;
  logic pair_last;
  logic [OUT_LANES-1:0] pair_output_lanes;

  logic [PAIR_LANES-1:0][QUAD_COUNT-1:0][17:0] quad_sum_low_pipe;
  logic [PAIR_LANES-1:0][QUAD_COUNT-1:0][17:0] quad_sum_high_pipe;
  logic quad_valid;
  logic quad_last;
  logic [OUT_LANES-1:0] quad_output_lanes;

  logic [PAIR_LANES-1:0][18:0] oct_sum_low_pipe;
  logic [PAIR_LANES-1:0][18:0] oct_sum_high_pipe;
  logic oct_valid;
  logic oct_last;
  logic [OUT_LANES-1:0] oct_output_lanes;
  logic signed [OUT_LANES-1:0][31:0] oct_contrib_ext;

  assign weight_write_addr = {weight_bank_select,
    WEIGHT_ADDR_W'(int'(weight_write_tap) * MAX_IC_GROUPS + int'(weight_write_ic_group))};
  assign mac_weight_addr = WEIGHT_ADDR_W'(
    int'(mac_tap) * MAX_IC_GROUPS + int'(mac_ic_group));

  always_comb begin
    activation_s1_padded = '0;
    input_lane_enable_s1_padded = '0;
    activation_offset_s1 = '0;
    activation_group_sum = '0;
    oct_contrib_ext = '0;
    for (int ic = 0; ic < INPUT_LANES; ic++) begin
      activation_s1_padded[ic] = activation_s1[ic];
      input_lane_enable_s1_padded[ic] = input_lane_enable_s1[ic];
      activation_offset_s1[ic] = activation_s1[ic] ^ 8'h80;
      if (input_lane_enable[ic]) begin
        activation_group_sum = activation_group_sum + 32'($signed(activation[ic]));
      end
    end

    product_comb = '0;
    for (int p = 0; p < PAIR_LANES; p++) begin
      for (int ic = 0; ic < INPUT_LANES; ic++) begin
        if ((output_lanes_s1[2*p] || output_lanes_s1[2*p+1]) &&
            input_lane_enable_s1_padded[ic]) begin
          product_comb[p][ic] =
            $signed({1'b0, weight_pipe[p][ic*24 +: 24]}) *
            $signed({10'b0, activation_offset_s1[ic]});
        end
      end
    end

    for (int p = 0; p < PAIR_LANES; p++) begin
      if (oct_output_lanes[2*p]) begin
        oct_contrib_ext[2*p] = $signed({{13{1'b0}}, oct_sum_low_pipe[p]});
      end
      if (oct_output_lanes[2*p+1]) begin
        oct_contrib_ext[2*p+1] = $signed({{13{1'b0}}, oct_sum_high_pipe[p]});
      end
    end
  end

  assign start_ready = !busy && !s0_valid && !s1_valid && !product_valid &&
                       !pair_valid && !quad_valid && !oct_valid && !result_valid;
  // The last input group may be in any of the five pipeline stages.  Once it
  // is accepted, no later group enters until the result has retired.
  assign mac_ready = busy && !result_valid &&
    !(s0_valid && s0_last) && !(s1_valid && s1_last) &&
    !(product_valid && product_last) && !(pair_valid && pair_last) &&
    !(quad_valid && quad_last) && !(oct_valid && oct_last);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      accum <= '0;
      activation_sum <= '0;
      active_output_lanes <= '0;
      activation_s0 <= '0;
      activation_s1 <= '0;
      input_lane_enable_s0 <= '0;
      input_lane_enable_s1 <= '0;
      weight_addr_s0 <= '0;
      output_lanes_s0 <= '0;
      output_lanes_s1 <= '0;
      s0_valid <= 1'b0;
      s0_last <= 1'b0;
      s1_valid <= 1'b0;
      s1_last <= 1'b0;
      product_pipe <= '0;
      product_valid <= 1'b0;
      product_last <= 1'b0;
      product_output_lanes <= '0;
      pair_sum_low_pipe <= '0;
      pair_sum_high_pipe <= '0;
      pair_valid <= 1'b0;
      pair_last <= 1'b0;
      pair_output_lanes <= '0;
      quad_sum_low_pipe <= '0;
      quad_sum_high_pipe <= '0;
      quad_valid <= 1'b0;
      quad_last <= 1'b0;
      quad_output_lanes <= '0;
      oct_sum_low_pipe <= '0;
      oct_sum_high_pipe <= '0;
      oct_valid <= 1'b0;
      oct_last <= 1'b0;
      oct_output_lanes <= '0;
      result_valid <= 1'b0;
      result_psum <= '0;
      result_lane_enable <= '0;
      busy <= 1'b0;
      protocol_error <= 1'b0;
    end else begin
      if (weight_write_valid && busy && (weight_bank_select == read_bank_select)) begin
        protocol_error <= 1'b1;
      end
      if (result_valid && result_ready) begin
        result_valid <= 1'b0;
      end
      if (start_valid && !start_ready) begin
        protocol_error <= 1'b1;
      end
      if (mac_valid && !mac_ready) begin
        protocol_error <= 1'b1;
      end

      if (start_valid && start_ready) begin
        accum <= bias;
        activation_sum <= '0;
        active_output_lanes <= output_lane_enable;
        busy <= 1'b1;
      end

      // Stage 0: capture the weight address, activation group and the shared
      // signed activation sum used by the final DMP correction.
      s0_valid <= 1'b0;
      if (mac_valid && mac_ready) begin
        activation_s0 <= activation;
        input_lane_enable_s0 <= input_lane_enable;
        weight_addr_s0 <= {read_bank_select, mac_weight_addr};
        output_lanes_s0 <= active_output_lanes;
        s0_last <= mac_last;
        s0_valid <= 1'b1;
        activation_sum <= activation_sum + activation_group_sum;
      end

      // Stage 1: synchronous packed-weight read; activation moves with it.
      s1_valid <= s0_valid;
      s1_last <= s0_last;
      activation_s1 <= activation_s0;
      input_lane_enable_s1 <= input_lane_enable_s0;
      output_lanes_s1 <= output_lanes_s0;

      // Stage 2: register the 25x18 DMP products.
      product_valid <= s1_valid;
      product_last <= s1_last;
      product_output_lanes <= output_lanes_s1;
      if (s1_valid) begin
        product_pipe <= product_comb;
      end

      // Stage 3: reduce pairs of low and high DMP products.
      pair_valid <= product_valid;
      pair_last <= product_last;
      pair_output_lanes <= product_output_lanes;
      if (product_valid) begin
        for (int p = 0; p < PAIR_LANES; p++) begin
          for (int q = 0; q < PAIR_COUNT; q++) begin
            pair_sum_low_pipe[p][q] <=
              {1'b0, product_pipe[p][2*q][15:0]} +
              {1'b0, product_pipe[p][2*q+1][15:0]};
            pair_sum_high_pipe[p][q] <=
              {1'b0, product_pipe[p][2*q][31:16]} +
              {1'b0, product_pipe[p][2*q+1][31:16]};
          end
        end
      end

      // Stage 4: reduce the four pair sums to two quad sums.
      quad_valid <= pair_valid;
      quad_last <= pair_last;
      quad_output_lanes <= pair_output_lanes;
      if (pair_valid) begin
        for (int p = 0; p < PAIR_LANES; p++) begin
          for (int q = 0; q < QUAD_COUNT; q++) begin
            quad_sum_low_pipe[p][q] <=
              {1'b0, pair_sum_low_pipe[p][2*q]} +
              {1'b0, pair_sum_low_pipe[p][2*q+1]};
            quad_sum_high_pipe[p][q] <=
              {1'b0, pair_sum_high_pipe[p][2*q]} +
              {1'b0, pair_sum_high_pipe[p][2*q+1]};
          end
        end
      end

      // Stage 5: complete the eight-way add tree.
      oct_valid <= quad_valid;
      oct_last <= quad_last;
      oct_output_lanes <= quad_output_lanes;
      if (quad_valid) begin
        for (int p = 0; p < PAIR_LANES; p++) begin
          oct_sum_low_pipe[p] <=
            {1'b0, quad_sum_low_pipe[p][0]} +
            {1'b0, quad_sum_low_pipe[p][1]};
          oct_sum_high_pipe[p] <=
            {1'b0, quad_sum_high_pipe[p][0]} +
            {1'b0, quad_sum_high_pipe[p][1]};
        end
      end

      // Stage 6: retire one fully reduced group into local INT32 sums and, on
      // the final group, apply the shared signed-activation correction.
      if (oct_valid) begin
        for (int p = 0; p < PAIR_LANES; p++) begin
          if (oct_output_lanes[2*p]) begin
            accum[2*p] <= accum[2*p] + oct_contrib_ext[2*p];
          end
          if (oct_output_lanes[2*p+1]) begin
            accum[2*p+1] <= accum[2*p+1] + oct_contrib_ext[2*p+1];
          end
        end
        if (oct_last) begin
          for (int oc = 0; oc < OUT_LANES; oc++) begin
            if (oct_output_lanes[oc]) begin
              result_psum[oc] <= accum[oc] + oct_contrib_ext[oc] -
                                 (activation_sum <<< 7);
            end
          end
          result_lane_enable <= oct_output_lanes;
          result_valid <= 1'b1;
          busy <= 1'b0;
        end
      end
    end
  end

endmodule
