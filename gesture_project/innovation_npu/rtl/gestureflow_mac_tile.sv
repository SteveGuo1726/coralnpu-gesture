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

  logic signed [7:0] weights [0:OUT_LANES-1][0:MAX_TAPS-1]
                            [0:MAX_IC_GROUPS-1][0:INPUT_LANES-1];
  logic signed [OUT_LANES-1:0][31:0] accum;
  logic [OUT_LANES-1:0] active_output_lanes;

  // This pipeline stage isolates DSP products from the following short
  // four-input add tree. It can accept one input-channel group each cycle.
  (* use_dsp = "yes" *) logic signed [OUT_LANES-1:0][INPUT_LANES-1:0][17:0] product_pipe;
  logic product_valid;
  logic product_last;
  logic [OUT_LANES-1:0] product_output_lanes;

  logic signed [OUT_LANES-1:0][31:0] reduced_products;

  always_comb begin
    reduced_products = '0;
    for (int oc = 0; oc < OUT_LANES; oc++) begin
      for (int ic = 0; ic < INPUT_LANES; ic++) begin
        reduced_products[oc] = reduced_products[oc] +
          {{14{product_pipe[oc][ic][17]}}, product_pipe[oc][ic]};
      end
    end
  end

  assign start_ready = !busy && !product_valid && !result_valid;
  // Do not accept a new vector in the cycle in which the previous vector is
  // tagged as final. All non-final vectors sustain one group per cycle.
  assign mac_ready = busy && !(product_valid && product_last) && !result_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      accum <= '0;
      active_output_lanes <= '0;
      product_pipe <= '0;
      product_valid <= 1'b0;
      product_last <= 1'b0;
      product_output_lanes <= '0;
      result_valid <= 1'b0;
      result_psum <= '0;
      result_lane_enable <= '0;
      busy <= 1'b0;
      protocol_error <= 1'b0;
    end else begin
      if (weight_write_valid) begin
        for (int ic = 0; ic < INPUT_LANES; ic++) begin
          weights[weight_write_oc][weight_write_tap][weight_write_ic_group][ic]
            <= weight_write_data[ic];
        end
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

      // Retire the prior DSP product group into the on-tile INT32 sums.
      if (product_valid) begin
        for (int oc = 0; oc < OUT_LANES; oc++) begin
          if (product_output_lanes[oc]) begin
            accum[oc] <= accum[oc] + reduced_products[oc];
          end
        end
        product_valid <= 1'b0;
        if (product_last) begin
          result_psum <= accum + reduced_products;
          result_lane_enable <= product_output_lanes;
          result_valid <= 1'b1;
          busy <= 1'b0;
        end
      end

      // Launch the next vector product. Disabled tail lanes are forced to
      // zero so a three-channel RGB stem is numerically exact on four lanes.
      if (mac_valid && mac_ready) begin
        for (int oc = 0; oc < OUT_LANES; oc++) begin
          for (int ic = 0; ic < INPUT_LANES; ic++) begin
            if (active_output_lanes[oc] && input_lane_enable[ic]) begin
              product_pipe[oc][ic] <= $signed(activation[ic]) *
                $signed(weights[oc][mac_tap][mac_ic_group][ic]);
            end else begin
              product_pipe[oc][ic] <= '0;
            end
          end
        end
        product_output_lanes <= active_output_lanes;
        product_last <= mac_last;
        product_valid <= 1'b1;
      end
    end
  end

endmodule
