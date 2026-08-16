// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Autonomous first-layer datapath: RGB stream -> SAME 4x4 -> INT32 ->
// per-channel TFLite requant/ReLU -> spatially addressed INT8 output tile.
`timescale 1ns/1ps
module gestureflow_conv4x4_rgb_same_layer #(
  parameter int IMAGE_WIDTH = 96,
  parameter int IMAGE_HEIGHT = 96,
  parameter int OUT_LANES = 16,
  parameter int OUTPUT_ADDR_W = 14
) (
  input logic clk, input logic rst_n, input logic frame_start,
  input logic pixel_valid, output logic pixel_ready,
  input logic signed [2:0][7:0] pixel_rgb,
  input logic signed [2:0][7:0] input_zero_point,
  input logic weight_write_valid,
  input logic [$clog2(OUT_LANES)-1:0] weight_write_oc,
  input logic [3:0] weight_write_tap,
  input logic signed [3:0][7:0] weight_write_data,
  input logic signed [OUT_LANES-1:0][31:0] bias,
  input logic [OUT_LANES-1:0] output_lane_enable,
  input logic requant_enable, input logic requant_relu_enable,
  input logic signed [7:0] output_zero_point,
  input logic signed [OUT_LANES-1:0][31:0] requant_multiplier,
  input logic [OUT_LANES-1:0][5:0] requant_right_shift,
  output logic frame_input_done, output logic layer_fault,
  output logic output_write_valid,
  output logic [OUTPUT_ADDR_W-1:0] output_write_addr,
  output logic signed [OUT_LANES-1:0][7:0] output_write_data,
  input logic output_read_enable,
  input logic [OUTPUT_ADDR_W-1:0] output_read_addr,
  output logic [OUT_LANES*8-1:0] output_read_data
);
  logic raw_valid, raw_ready, raw_fault;
  logic signed [OUT_LANES-1:0][31:0] raw_psum;
  logic [OUT_LANES-1:0] raw_mask;
  logic [15:0] raw_row, raw_column, quant_row, quant_column;
  logic quant_valid, quant_ready, quant_fault;
  logic signed [OUT_LANES-1:0][7:0] quant_data;

  gestureflow_conv4x4_rgb_same_stream #(
    .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT), .OUT_LANES(OUT_LANES)
  ) stream (
    .clk(clk), .rst_n(rst_n), .frame_start(frame_start),
    .pixel_valid(pixel_valid), .pixel_ready(pixel_ready), .pixel_rgb(pixel_rgb),
    .input_zero_point(input_zero_point),
    .weight_write_valid(weight_write_valid), .weight_write_oc(weight_write_oc),
    .weight_write_tap(weight_write_tap), .weight_write_data(weight_write_data),
    .bias(bias), .output_lane_enable(output_lane_enable), .output_valid(raw_valid),
    .output_ready(raw_ready), .output_psum(raw_psum),
    .output_lane_enable_valid(raw_mask), .output_row(raw_row), .output_column(raw_column),
    .busy(), .protocol_error(raw_fault), .frame_input_done(frame_input_done)
  );
  gestureflow_requant_relu #(.LANES(OUT_LANES)) requant (
    .clk(clk), .rst_n(rst_n), .in_valid(raw_valid), .in_ready(raw_ready),
    .in_psum(raw_psum), .in_lane_enable(raw_mask), .enable(requant_enable),
    .relu_enable(requant_relu_enable), .output_zero_point(output_zero_point),
    .multiplier(requant_multiplier), .right_shift(requant_right_shift),
    .out_valid(quant_valid), .out_ready(quant_ready), .out_data(quant_data),
    .out_lane_enable(), .config_error(quant_fault)
  );
  assign quant_ready = 1'b1;
  assign output_write_valid = quant_valid;
  assign output_write_addr = OUTPUT_ADDR_W'(int'(quant_row) * IMAGE_WIDTH + int'(quant_column));
  assign output_write_data = quant_data;
  assign layer_fault = raw_fault || quant_fault;

  gestureflow_output_bank #(.ADDR_W(OUTPUT_ADDR_W), .DATA_W(OUT_LANES*8)) output_bank (
    .clk(clk), .write_enable(quant_valid), .write_addr(output_write_addr),
    .write_data(quant_data), .read_enable(output_read_enable), .read_addr(output_read_addr),
    .read_data(output_read_data)
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin quant_row <= '0; quant_column <= '0; end
    else if (raw_valid && raw_ready) begin quant_row <= raw_row; quant_column <= raw_column; end
  end
endmodule
