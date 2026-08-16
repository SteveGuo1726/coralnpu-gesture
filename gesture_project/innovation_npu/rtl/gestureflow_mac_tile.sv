// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// GestureFlow-NPU compute tile.  One accepted input vector performs
// OUT_LANES * INPUT_LANES signed INT8 products.  Weights are explicitly
// loaded into a local output-channel tile before a job starts; INT32 partial
// sums remain local until mac_last.  This module intentionally has no ARM
// per-window interface.
`timescale 1ns/1ps
module gestureflow_mac_tile #(
  parameter int OUT_LANES = 16,
  parameter int INPUT_LANES = 4,
  parameter int MAX_TAPS = 16,
  parameter int MAX_IC_GROUPS = 16
) (
  input  logic clk,
  input  logic rst_n,

  input  logic weight_write_valid,
  input  logic [$clog2(OUT_LANES)-1:0] weight_write_oc,
  input  logic [$clog2(MAX_TAPS)-1:0] weight_write_tap,
  input  logic [$clog2(MAX_IC_GROUPS)-1:0] weight_write_ic_group,
  input  logic signed [INPUT_LANES-1:0][7:0] weight_write_data,

  input  logic start_valid,
  output logic start_ready,
  input  logic signed [OUT_LANES-1:0][31:0] bias,
  input  logic [OUT_LANES-1:0] output_lane_enable,

  input  logic mac_valid,
  output logic mac_ready,
  input  logic [$clog2(MAX_TAPS)-1:0] mac_tap,
  input  logic [$clog2(MAX_IC_GROUPS)-1:0] mac_ic_group,
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

  localparam int WEIGHT_DEPTH = MAX_TAPS * MAX_IC_GROUPS;
  localparam int WEIGHT_ADDR_W = $clog2(WEIGHT_DEPTH);

  // One independently addressed bank per output lane provides all
  // OUT_LANES x INPUT_LANES operands each cycle. The physical bank is a
  // separate module because a variable-indexed two-dimensional array was
  // expanded by XC7 synthesis into 131072 flip-flops instead of block RAM.
  logic signed [OUT_LANES-1:0][31:0] accum;
  logic [OUT_LANES-1:0] active_output_lanes;

  logic [WEIGHT_ADDR_W-1:0] weight_write_addr;
  logic [WEIGHT_ADDR_W-1:0] mac_weight_addr;
  logic [WEIGHT_ADDR_W-1:0] weight_addr_s0;
  logic signed [INPUT_LANES-1:0][7:0] activation_s0;
  logic signed [INPUT_LANES-1:0][7:0] activation_s1;
  logic [INPUT_LANES-1:0] input_lane_enable_s0;
  logic [INPUT_LANES-1:0] input_lane_enable_s1;
  logic [OUT_LANES-1:0] output_lanes_s0;
  logic [OUT_LANES-1:0] output_lanes_s1;
  logic s0_valid, s0_last;
  logic s1_valid, s1_last;
  logic [INPUT_LANES*8-1:0] weight_pipe [0:OUT_LANES-1];

  for (genvar oc = 0; oc < OUT_LANES; oc++) begin : output_weight_banks
    gestureflow_weight_bank #(
      .ADDR_W(WEIGHT_ADDR_W),
      .DATA_W(INPUT_LANES * 8)
    ) weight_bank (
      .clk(clk),
      .write_enable(weight_write_valid && !busy && (weight_write_oc == oc)),
      .write_addr(weight_write_addr),
      .write_data(weight_write_data),
      .read_enable(s0_valid),
      .read_addr(weight_addr_s0),
      .read_data(weight_pipe[oc])
    );
  end

  // The first stage is a synchronous banked weight-RAM read. The second holds
  // four DSP products. Two registered add-tree stages then reduce four INT8
  // products before the final local INT32 accumulation. Once full this still
  // accepts one channel group per clock, while avoiding a long product-to-psum
  // combinational path at the 100MHz XC7Z020 target.
  (* use_dsp = "yes" *) logic signed [OUT_LANES-1:0][3:0][17:0] product_pipe;
  logic product_valid;
  logic product_last;
  logic [OUT_LANES-1:0] product_output_lanes;

  logic signed [OUT_LANES-1:0][1:0][18:0] pair_sum_pipe;
  logic pair_valid;
  logic pair_last;
  logic [OUT_LANES-1:0] pair_output_lanes;
  logic signed [OUT_LANES-1:0][19:0] reduced_sum_pipe;
  logic signed [OUT_LANES-1:0][31:0] reduced_sum_extended;
  logic reduced_valid;
  logic reduced_last;
  logic [OUT_LANES-1:0] reduced_output_lanes;
  logic signed [3:0][7:0] activation_s1_padded;
  logic [3:0] input_lane_enable_s1_padded;
  logic signed [OUT_LANES-1:0][3:0][7:0] weight_s1_padded;

  assign weight_write_addr = WEIGHT_ADDR_W'(
    int'(weight_write_tap) * MAX_IC_GROUPS + int'(weight_write_ic_group));
  assign mac_weight_addr = WEIGHT_ADDR_W'(
    int'(mac_tap) * MAX_IC_GROUPS + int'(mac_ic_group));

  // The data path is physically four lanes wide. Narrow stems use explicit
  // zero padding here, so RGB (three lanes), compatibility tests (one/two
  // lanes), and the four-lane main body share exactly the same add tree.
  always_comb begin
    activation_s1_padded = '0;
    input_lane_enable_s1_padded = '0;
    weight_s1_padded = '0;
    reduced_sum_extended = '0;
    for (int ic = 0; ic < INPUT_LANES; ic++) begin
      activation_s1_padded[ic] = activation_s1[ic];
      input_lane_enable_s1_padded[ic] = input_lane_enable_s1[ic];
      for (int oc = 0; oc < OUT_LANES; oc++) begin
        weight_s1_padded[oc][ic] = weight_pipe[oc][ic*8 +: 8];
      end
    end
    for (int oc = 0; oc < OUT_LANES; oc++) begin
      reduced_sum_extended[oc] = {
        {12{reduced_sum_pipe[oc][19]}}, reduced_sum_pipe[oc]
      };
    end
  end

  assign start_ready = !busy && !s0_valid && !s1_valid && !product_valid &&
                       !pair_valid && !reduced_valid && !result_valid;
  // A final input group may be in any pipeline stage. Once seen, no later
  // group may enter until its result has retired, but all preceding groups
  // still flow through at one group per cycle.
  assign mac_ready = busy && !result_valid &&
    !(s0_valid && s0_last) && !(s1_valid && s1_last) &&
    !(product_valid && product_last) && !(pair_valid && pair_last) &&
    !(reduced_valid && reduced_last);

  // Keep every BRAM address/control source synchronously reset.  An async
  // reset on a RAM address or enable can corrupt inferred RAMB18E1 contents
  // and is not timing-analysed by Vivado.  Weights themselves remain
  // intentionally unreset and must be loaded before each job.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      accum <= '0;
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
      pair_sum_pipe <= '0;
      pair_valid <= 1'b0;
      pair_last <= 1'b0;
      pair_output_lanes <= '0;
      reduced_sum_pipe <= '0;
      reduced_valid <= 1'b0;
      reduced_last <= 1'b0;
      reduced_output_lanes <= '0;
      result_valid <= 1'b0;
      result_psum <= '0;
      result_lane_enable <= '0;
      busy <= 1'b0;
      protocol_error <= 1'b0;
    end else begin
      if (weight_write_valid && busy) begin
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
        active_output_lanes <= output_lane_enable;
        busy <= 1'b1;
      end

      // Stage 0: capture a requested weight address and its activation group.
      s0_valid <= 1'b0;
      if (mac_valid && mac_ready) begin
        activation_s0 <= activation;
        input_lane_enable_s0 <= input_lane_enable;
        weight_addr_s0 <= mac_weight_addr;
        output_lanes_s0 <= active_output_lanes;
        s0_last <= mac_last;
        s0_valid <= 1'b1;
      end

      // Stage 1: every output-channel bank performs its synchronous read.
      // weight_pipe is registered by gestureflow_weight_bank in this cycle.
      s1_valid <= s0_valid;
      s1_last <= s0_last;
      activation_s1 <= activation_s0;
      input_lane_enable_s1 <= input_lane_enable_s0;
      output_lanes_s1 <= output_lanes_s0;
      // Stage 5: retire one fully reduced group into on-tile INT32 sums.
      if (reduced_valid) begin
        for (int oc = 0; oc < OUT_LANES; oc++) begin
          if (reduced_output_lanes[oc]) begin
            accum[oc] <= accum[oc] + reduced_sum_extended[oc];
          end
        end
        if (reduced_last) begin
          // These are packed lane arrays. A vector-wide '+' would propagate
          // the carry from lane N into lane N+1, corrupting only selected
          // output channels on real signed model data. Keep every INT32
          // output accumulator mathematically independent.
          for (int oc = 0; oc < OUT_LANES; oc++) begin
            result_psum[oc] <= accum[oc] + reduced_sum_extended[oc];
          end
          result_lane_enable <= reduced_output_lanes;
          result_valid <= 1'b1;
          busy <= 1'b0;
        end
      end

      // Stage 4: complete the four-way add tree after the two pair sums.
      reduced_valid <= pair_valid;
      reduced_last <= pair_last;
      reduced_output_lanes <= pair_output_lanes;
      if (pair_valid) begin
        for (int oc = 0; oc < OUT_LANES; oc++) begin
          reduced_sum_pipe[oc] <=
            $signed({pair_sum_pipe[oc][0][18], pair_sum_pipe[oc][0]}) +
            $signed({pair_sum_pipe[oc][1][18], pair_sum_pipe[oc][1]});
        end
      end

      // Stage 3: reduce four DSP products to two registered pair sums.
      pair_valid <= product_valid;
      pair_last <= product_last;
      pair_output_lanes <= product_output_lanes;
      if (product_valid) begin
        for (int oc = 0; oc < OUT_LANES; oc++) begin
          pair_sum_pipe[oc][0] <=
            $signed({product_pipe[oc][0][17], product_pipe[oc][0]}) +
            $signed({product_pipe[oc][1][17], product_pipe[oc][1]});
          pair_sum_pipe[oc][1] <=
            $signed({product_pipe[oc][2][17], product_pipe[oc][2]}) +
            $signed({product_pipe[oc][3][17], product_pipe[oc][3]});
        end
      end

      // Stage 2: product register. Disabled tail lanes are forced to zero so
      // a three-channel RGB stem is numerically exact on four lanes.
      product_valid <= s1_valid;
      product_last <= s1_last;
      product_output_lanes <= output_lanes_s1;
      if (s1_valid) begin
        for (int oc = 0; oc < OUT_LANES; oc++) begin
          for (int ic = 0; ic < 4; ic++) begin
            if (output_lanes_s1[oc] && input_lane_enable_s1_padded[ic]) begin
              product_pipe[oc][ic] <= $signed(activation_s1_padded[ic]) *
                $signed(weight_s1_padded[oc][ic]);
            end else begin
              product_pipe[oc][ic] <= '0;
            end
          end
        end
      end
    end
  end

endmodule
