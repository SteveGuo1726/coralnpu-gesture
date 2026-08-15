// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Resource/timing top for XC7Z020CLG400-1. All interfaces are retained as
// top-level ports so Vivado measures the full 16x4 weight-banked MAC tile.
`timescale 1ns/1ps
module gestureflow_mac_tile_7020_top (
  input  logic clk,
  input  logic rst_n,
  input  logic weight_write_valid,
  input  logic [3:0] weight_write_oc,
  input  logic [3:0] weight_write_tap,
  input  logic [3:0] weight_write_ic_group,
  input  logic signed [3:0][7:0] weight_write_data,
  input  logic start_valid,
  output logic start_ready,
  input  logic signed [15:0][31:0] bias,
  input  logic [15:0] output_lane_enable,
  input  logic mac_valid,
  output logic mac_ready,
  input  logic [3:0] mac_tap,
  input  logic [3:0] mac_ic_group,
  input  logic signed [3:0][7:0] activation,
  input  logic [3:0] input_lane_enable,
  input  logic mac_last,
  output logic result_valid,
  input  logic result_ready,
  output logic signed [15:0][31:0] result_psum,
  output logic [15:0] result_lane_enable,
  output logic busy,
  output logic protocol_error
);

  (* keep_hierarchy = "yes" *) gestureflow_mac_tile #(
    .OUT_LANES(16),
    .INPUT_LANES(4),
    .MAX_TAPS(16),
    .MAX_IC_GROUPS(16)
  ) dut (.*);

endmodule
