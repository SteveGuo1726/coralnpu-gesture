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
  input  logic [15:0] window_row,
  input  logic [15:0] window_column,
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
  output logic [15:0] result_row,
  output logic [15:0] result_column,
  output logic busy,
  output logic protocol_error
);

  localparam int PAIR_LANES = OUT_LANES / 2;
  localparam int WEIGHT_DEPTH = MAX_TAPS * MAX_IC_GROUPS;
  localparam int WEIGHT_ADDR_W = $clog2(WEIGHT_DEPTH);
  localparam int WEIGHT_DATA_W = INPUT_LANES * 24;
  localparam int PAIR_COUNT = INPUT_LANES / 2;
  localparam int QUAD_COUNT = PAIR_COUNT / 2;

  // Multi-window streaming: per-window accumulator state is double-buffered
  // so the next window's first group can enter while the previous window's
  // tail drains.  A 1-bit window id toggles at each start and travels with the
  // pipeline; a small active-window counter replaces the single busy flag so
  // one window's retire cannot clear the busy state of an overlapping one.
  logic signed [1:0][OUT_LANES-1:0][31:0] accum;
  logic [1:0][OUT_LANES-1:0] active_output_lanes;
  logic signed [1:0][31:0] activation_sum;
  logic [1:0][15:0] window_row_reg;
  logic [1:0][15:0] window_column_reg;
  logic [1:0] windows_active;
  logic cur_win_id;
  logic s0_id, s1_id, product_id, pair_id, quad_id, oct_id, retire_id;

  logic [WEIGHT_ADDR_W:0] weight_write_addr;
  logic [WEIGHT_ADDR_W-1:0] mac_weight_addr;
  logic [WEIGHT_ADDR_W:0] weight_addr_s0;
  logic signed [INPUT_LANES-1:0][7:0] activation_s0;
  logic signed [INPUT_LANES-1:0][7:0] activation_s1;
  logic [INPUT_LANES-1:0] input_lane_enable_s0;
  logic [INPUT_LANES-1:0] input_lane_enable_s1;
  logic [OUT_LANES-1:0] output_lanes_s0;
  logic [OUT_LANES-1:0] output_lanes_s1;
  (* max_fanout = 32 *) logic s0_valid; logic s0_last;
  (* max_fanout = 32 *) logic s1_valid; logic s1_last;

  logic [WEIGHT_DATA_W-1:0] weight_pipe [0:PAIR_LANES-1];
  logic [INPUT_LANES-1:0][7:0] activation_offset_s1;
  logic signed [INPUT_LANES-1:0][7:0] activation_s1_padded;
  logic [INPUT_LANES-1:0] input_lane_enable_s1_padded;
  logic signed [31:0] activation_group_sum_s0;
  logic signed [31:0] activation_group_sum_s1;

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
  (* use_dsp = "yes" *) logic signed [PAIR_LANES-1:0][INPUT_LANES-1:0][31:0] product_comb;
  (* use_dsp = "yes" *) logic signed [PAIR_LANES-1:0][INPUT_LANES-1:0][31:0] product_pipe;
  (* max_fanout = 32 *) logic product_valid;
  logic product_last;
  logic [OUT_LANES-1:0] product_output_lanes;

  // Each unsigned low/high partial is 16 bits.  Two fit in 17 bits, four in
  // 18 bits, eight in 19 bits; these are the smallest exact widths and keep
  // the registered add tree from inflating XC7Z020 carry chains.
  logic [PAIR_LANES-1:0][PAIR_COUNT-1:0][16:0] pair_sum_low_pipe;
  logic [PAIR_LANES-1:0][PAIR_COUNT-1:0][16:0] pair_sum_high_pipe;
  (* max_fanout = 32 *) logic pair_valid;
  logic pair_last;
  logic [OUT_LANES-1:0] pair_output_lanes;

  logic [PAIR_LANES-1:0][QUAD_COUNT-1:0][17:0] quad_sum_low_pipe;
  logic [PAIR_LANES-1:0][QUAD_COUNT-1:0][17:0] quad_sum_high_pipe;
  (* max_fanout = 32 *) logic quad_valid;
  logic quad_last;
  logic [OUT_LANES-1:0] quad_output_lanes;

  logic [PAIR_LANES-1:0][18:0] oct_sum_low_pipe;
  logic [PAIR_LANES-1:0][18:0] oct_sum_high_pipe;
  (* max_fanout = 32 *) logic oct_valid;
  logic oct_last;
  logic [OUT_LANES-1:0] oct_output_lanes;
  logic signed [OUT_LANES-1:0][31:0] oct_contrib_ext;

  // Stage 7: the original retire combined the per-group accumulation with the
  // shared -128*sum(a) correction in one three-term 32-bit expression
  // (accum + oct_contrib - activation_sum<<7).  For a widened OUT_LANES=32
  // tile that was the dominant setup-critical node.  It is split into two
  // single 32-bit two-term operations: stage 6 accumulates, stage 7 subtracts
  // the activation correction and emits the result.
  (* max_fanout = 32 *) logic retire_valid;
  logic [OUT_LANES-1:0] retire_output_lanes;

  assign weight_write_addr = {weight_bank_select,
    WEIGHT_ADDR_W'(int'(weight_write_tap) * MAX_IC_GROUPS + int'(weight_write_ic_group))};
  assign mac_weight_addr = WEIGHT_ADDR_W'(
    int'(mac_tap) * MAX_IC_GROUPS + int'(mac_ic_group));

  always_comb begin
    activation_s1_padded = '0;
    input_lane_enable_s1_padded = '0;
    activation_offset_s1 = '0;
    activation_group_sum_s0 = '0;
    oct_contrib_ext = '0;
    for (int ic = 0; ic < INPUT_LANES; ic++) begin
      activation_s1_padded[ic] = activation_s1[ic];
      input_lane_enable_s1_padded[ic] = input_lane_enable_s1[ic];
      activation_offset_s1[ic] = activation_s1[ic] ^ 8'h80;
      if (input_lane_enable_s0[ic]) begin
        activation_group_sum_s0 = activation_group_sum_s0 + 32'($signed(activation_s0[ic]));
      end
    end

    product_comb = '0;
    for (int p = 0; p < PAIR_LANES; p++) begin
      for (int ic = 0; ic < INPUT_LANES; ic++) begin
        if ((output_lanes_s1[2*p] || output_lanes_s1[2*p+1]) &&
            input_lane_enable_s1_padded[ic]) begin
          product_comb[p][ic] =
            32'($signed({1'b0, weight_pipe[p][ic*24 +: 24]}) *
                $signed({10'b0, activation_offset_s1[ic]}));
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

  assign busy = (windows_active != 2'd0);
  // A new window launches as soon as the s0 input stage is free and no result
  // is still parked on the requant handshake.  Per-window state is double
  // buffered, so the previous window's tail drains in parallel with the next
  // window's fill, removing the per-window pipeline drain bubble.
  assign start_ready = !s0_valid && !retire_valid && !result_valid;
  // A new input group is accepted every cycle the tile has an active window
  // and the result register is free; the fixed shift register backpressures
  // naturally because s0 is only captured on mac_ready.
  assign mac_ready = (windows_active != 2'd0) && !retire_valid && !result_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      accum <= '0;
      activation_sum <= '0;
      active_output_lanes <= '0;
      window_row_reg <= '0;
      window_column_reg <= '0;
      windows_active <= 2'd0;
      cur_win_id <= 1'b0;
      s0_id <= 1'b0;
      s1_id <= 1'b0;
      product_id <= 1'b0;
      pair_id <= 1'b0;
      quad_id <= 1'b0;
      oct_id <= 1'b0;
      retire_id <= 1'b0;
      activation_s0 <= '0;
      activation_s1 <= '0;
      activation_group_sum_s1 <= '0;
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
      retire_valid <= 1'b0;
      retire_output_lanes <= '0;
      result_valid <= 1'b0;
      result_psum <= '0;
      result_lane_enable <= '0;
      protocol_error <= 1'b0;
    end else begin
      if (weight_write_valid && busy && (weight_bank_select == read_bank_select)) begin
        protocol_error <= 1'b1;
      end
      if (result_valid && result_ready) begin
        result_valid <= 1'b0;
      end

      if (start_valid && start_ready) begin
        cur_win_id <= !cur_win_id;
        accum[!cur_win_id] <= bias;
        activation_sum[!cur_win_id] <= '0;
        active_output_lanes[!cur_win_id] <= output_lane_enable;
        window_row_reg[!cur_win_id] <= window_row;
        window_column_reg[!cur_win_id] <= window_column;
        windows_active <= windows_active + 2'd1;
      end

      // Stage 0: capture the weight address, activation group and the shared
      // signed activation sum used by the final DMP correction.
      s0_valid <= 1'b0;
      if (mac_valid && mac_ready) begin
        s0_id <= cur_win_id;
        activation_s0 <= activation;
        input_lane_enable_s0 <= input_lane_enable;
        weight_addr_s0 <= {read_bank_select, mac_weight_addr};
        output_lanes_s0 <= active_output_lanes[cur_win_id];
        s0_last <= mac_last;
        s0_valid <= 1'b1;
      end

      // Stage 1: synchronous packed-weight read; activation moves with it.
      s1_valid <= s0_valid;
      s1_id <= s0_id;
      s1_last <= s0_last;
      activation_group_sum_s1 <= activation_group_sum_s0;
      if (s1_valid) begin
        activation_sum[s1_id] <= activation_sum[s1_id] + activation_group_sum_s1;
      end
      activation_s1 <= activation_s0;
      input_lane_enable_s1 <= input_lane_enable_s0;
      output_lanes_s1 <= output_lanes_s0;

      // Stage 2: register the 25x18 DMP products.
      product_valid <= s1_valid;
      product_id <= s1_id;
      product_last <= s1_last;
      product_output_lanes <= output_lanes_s1;
      if (s1_valid) begin
        product_pipe <= product_comb;
      end

      // Stage 3: reduce pairs of low and high DMP products.
      pair_valid <= product_valid;
      pair_id <= product_id;
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
      quad_id <= pair_id;
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
      oct_id <= quad_id;
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

      // Stage 6: retire one fully reduced group into local INT32 sums.
      // oct_contrib_ext is already zeroed for disabled output lanes, so the
      // per-lane guard can be removed and the update becomes a single 32-bit
      // two-term add (fewer clock-enable control sets, shorter carry path).
      if (oct_valid) begin
        for (int oc = 0; oc < OUT_LANES; oc++) begin
          accum[oct_id][oc] <= accum[oct_id][oc] + oct_contrib_ext[oc];
        end
        retire_id <= oct_id;
        retire_valid <= oct_last;
        retire_output_lanes <= oct_output_lanes;
      end

      // Stage 7: apply the shared signed-activation correction as a second
      // two-term 32-bit subtraction.  accum already contains the final group
      // because stage 6 updated it one cycle earlier.
      if (retire_valid && !result_valid) begin
        for (int oc = 0; oc < OUT_LANES; oc++) begin
          result_psum[oc] <= accum[retire_id][oc] - (activation_sum[retire_id] <<< 7);
        end
        result_lane_enable <= retire_output_lanes;
        result_row <= window_row_reg[retire_id];
        result_column <= window_column_reg[retire_id];
        result_valid <= 1'b1;
        retire_valid <= 1'b0;
        windows_active <= windows_active - 2'd1;
      end
    end
  end

endmodule
