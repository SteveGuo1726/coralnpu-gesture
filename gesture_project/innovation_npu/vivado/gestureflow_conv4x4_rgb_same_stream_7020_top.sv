// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Standalone XC7Z020 synthesis top that retains the complete autonomous
// first-layer SAME stream, including its RGB line storage and 16x4 MAC tile.
`timescale 1ns/1ps
module gestureflow_conv4x4_rgb_same_stream_7020_top (
  input logic clk,
  input logic rst_n,
  input logic frame_start,
  input logic pixel_valid,
  output logic pixel_ready,
  input logic signed [2:0][7:0] pixel_rgb,
  input logic weight_write_valid,
  input logic [3:0] weight_write_oc,
  input logic [3:0] weight_write_tap,
  input logic signed [3:0][7:0] weight_write_data,
  input logic signed [15:0][31:0] bias,
  input logic [15:0] output_lane_enable,
  output logic output_valid,
  input logic output_ready,
  output logic signed [15:0][31:0] output_psum,
  output logic [15:0] output_lane_enable_valid,
  output logic [15:0] output_row,
  output logic [15:0] output_column,
  output logic busy,
  output logic protocol_error,
  output logic frame_input_done
);
  (* keep_hierarchy = "yes" *) gestureflow_conv4x4_rgb_same_stream #(
    .IMAGE_WIDTH(96), .IMAGE_HEIGHT(96), .OUT_LANES(16)
  ) dut (.*);
endmodule
