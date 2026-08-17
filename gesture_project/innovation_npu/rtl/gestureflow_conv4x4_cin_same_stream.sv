// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Real body-convolution engine for NHWC INT8 tensors. A 4x4 window is held
// locally while the existing 16-output x 4-input-lane MAC tile walks all
// input-channel groups; therefore INT32 partial sums never leave the tile.
`timescale 1ns/1ps
module gestureflow_conv4x4_cin_same_stream #(
  parameter int IMAGE_WIDTH = 96,
  parameter int IMAGE_HEIGHT = 96,
  parameter int INPUT_CHANNELS = 16,
  parameter int OUT_LANES = 16
) (
  input logic clk,
  input logic rst_n,
  input logic [15:0] image_width,
  input logic [15:0] image_height,
  input logic frame_start,
  input logic pixel_valid,
  output logic pixel_ready,
  input logic signed [INPUT_CHANNELS-1:0][7:0] pixel_data,
  input logic signed [INPUT_CHANNELS-1:0][7:0] input_zero_point,
  // Runtime lane masking lets one physical 4-lane tile serve RGB (3 lanes)
  // and full 16-channel body layers without instantiating a second MAC core.
  input logic [3:0] input_lane_enable,
  input logic weight_write_valid,
  input logic [$clog2(OUT_LANES)-1:0] weight_write_oc,
  input logic [3:0] weight_write_tap,
  input logic [(INPUT_CHANNELS <= 4 ? 1 : $clog2(INPUT_CHANNELS/4))-1:0] weight_write_ic_group,
  input logic signed [3:0][7:0] weight_write_data,
  input logic signed [OUT_LANES-1:0][31:0] bias,
  input logic [OUT_LANES-1:0] output_lane_enable,
  output logic output_valid,
  input logic output_ready,
  output logic signed [OUT_LANES-1:0][31:0] output_psum,
  output logic [OUT_LANES-1:0] output_lane_enable_valid,
  output logic [15:0] output_row,
  output logic [15:0] output_column,
  output logic busy,
  output logic protocol_error,
  output logic frame_input_done
);
  localparam int IC_GROUPS = INPUT_CHANNELS / 4;
  localparam int IC_GROUP_W = (IC_GROUPS <= 1) ? 1 : $clog2(IC_GROUPS);
  logic window_valid;
  logic window_ready;
  logic pending_window;
  logic mac_active;
  logic signed [INPUT_CHANNELS-1:0][15:0][7:0] window_data;
  logic signed [INPUT_CHANNELS-1:0][15:0][7:0] held_window;
  logic [15:0] window_row;
  logic [15:0] window_column;
  logic [15:0] held_row;
  logic [15:0] held_column;
  logic tile_start_ready;
  logic tile_mac_ready;
  logic [3:0] tap_index;
  logic [IC_GROUP_W-1:0] ic_group_index;
  logic signed [3:0][7:0] tile_activation;

  initial begin
    if ((INPUT_CHANNELS % 4) != 0) $error("INPUT_CHANNELS must be divisible by four");
  end

  assign window_ready = !pending_window && !mac_active && !busy && !output_valid;

  gestureflow_same4x4_cin_window #(
    .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT), .CHANNELS(INPUT_CHANNELS)
  ) same_window (
    .clk(clk), .rst_n(rst_n), .image_width(image_width), .image_height(image_height), .frame_start(frame_start),
    .pixel_valid(pixel_valid), .pixel_ready(pixel_ready), .pixel_data(pixel_data),
    .padding_value(input_zero_point), .window_valid(window_valid), .window_ready(window_ready),
    .window_data(window_data), .output_row(window_row), .output_column(window_column),
    .frame_done(frame_input_done)
  );

  always_comb begin
    tile_activation = '0;
    for (int lane = 0; lane < 4; lane++) begin
      tile_activation[lane] = held_window[int'(ic_group_index) * 4 + lane][tap_index];
    end
    output_row = held_row;
    output_column = held_column;
  end

  gestureflow_mac_tile #(
    .OUT_LANES(OUT_LANES), .INPUT_LANES(4), .MAX_TAPS(16), .MAX_IC_GROUPS(IC_GROUPS)
  ) mac_tile (
    .clk(clk), .rst_n(rst_n), .weight_write_valid(weight_write_valid),
    .weight_write_oc(weight_write_oc), .weight_write_tap(weight_write_tap),
    .weight_write_ic_group(weight_write_ic_group), .weight_write_data(weight_write_data),
    .start_valid(pending_window), .start_ready(tile_start_ready), .bias(bias),
    .output_lane_enable(output_lane_enable), .mac_valid(mac_active), .mac_ready(tile_mac_ready),
    .mac_tap(tap_index), .mac_ic_group(ic_group_index), .activation(tile_activation),
    .input_lane_enable(input_lane_enable),
    .mac_last((tap_index == 4'd15) && (ic_group_index == IC_GROUP_W'(IC_GROUPS - 1))),
    .result_valid(output_valid), .result_ready(output_ready), .result_psum(output_psum),
    .result_lane_enable(output_lane_enable_valid), .busy(busy), .protocol_error(protocol_error)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pending_window <= 1'b0;
      mac_active <= 1'b0;
      tap_index <= '0;
      ic_group_index <= '0;
      held_window <= '0;
      held_row <= '0;
      held_column <= '0;
    end else begin
      if (window_valid && window_ready) begin
        held_window <= window_data;
        held_row <= window_row;
        held_column <= window_column;
        pending_window <= 1'b1;
      end
      if (pending_window && tile_start_ready) begin
        pending_window <= 1'b0;
        mac_active <= 1'b1;
        tap_index <= '0;
        ic_group_index <= '0;
      end
      if (mac_active && tile_mac_ready) begin
        if (ic_group_index == IC_GROUP_W'(IC_GROUPS - 1)) begin
          ic_group_index <= '0;
          if (tap_index == 4'd15) mac_active <= 1'b0;
          else tap_index <= tap_index + 1'b1;
        end else begin
          ic_group_index <= ic_group_index + 1'b1;
        end
      end
    end
  end
endmodule
