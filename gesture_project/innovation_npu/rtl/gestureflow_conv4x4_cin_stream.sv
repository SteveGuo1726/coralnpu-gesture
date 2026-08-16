// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Four-lane GestureFlow body-convolution stream. INPUT_CHANNELS must be a
// multiple of four; all channel windows are retained locally, then scheduled
// as tap x input-channel-group into one INT32-resident MAC-tile transaction.
`timescale 1ns/1ps
module gestureflow_conv4x4_cin_stream #(
  parameter int IMAGE_WIDTH = 96,
  parameter int INPUT_CHANNELS = 16,
  parameter int OUT_LANES = 16
) (
  input logic clk, input logic rst_n, input logic frame_start,
  input logic pixel_valid, output logic pixel_ready,
  input logic signed [INPUT_CHANNELS-1:0][7:0] pixel_data,
  input logic weight_write_valid,
  input logic [$clog2(OUT_LANES)-1:0] weight_write_oc,
  input logic [3:0] weight_write_tap,
  input logic [$clog2(INPUT_CHANNELS/4)-1:0] weight_write_ic_group,
  input logic signed [3:0][7:0] weight_write_data,
  input logic signed [OUT_LANES-1:0][31:0] bias,
  input logic [OUT_LANES-1:0] output_lane_enable,
  output logic output_valid, input logic output_ready,
  output logic signed [OUT_LANES-1:0][31:0] output_psum,
  output logic [OUT_LANES-1:0] output_lane_enable_valid,
  output logic busy, output logic protocol_error
);
  localparam int IC_GROUPS = INPUT_CHANNELS / 4;
  logic [INPUT_CHANNELS-1:0] window_valid, line_pixel_ready;
  logic core_pixel_ready;
  logic signed [INPUT_CHANNELS-1:0][15:0][7:0] window_data, held_window;
  logic pending_window, mac_active, tile_start_ready, tile_mac_ready;
  logic [3:0] tap_index;
  logic [$clog2(IC_GROUPS)-1:0] ic_group_index;
  logic signed [3:0][7:0] tile_activation;

  for (genvar c = 0; c < INPUT_CHANNELS; c++) begin : channel_windows
    gestureflow_line_window #(.IMAGE_WIDTH(IMAGE_WIDTH), .KERNEL_SIZE(4)) line_window (
      .clk(clk), .rst_n(rst_n), .frame_start(frame_start),
      .pixel_valid(pixel_valid && core_pixel_ready), .pixel_data(pixel_data[c]),
      .pixel_ready(line_pixel_ready[c]),
      .window_ready(1'b1),
      .window_valid(window_valid[c]), .window_data(window_data[c])
    );
  end
  always_comb begin
    for (int lane = 0; lane < 4; lane++) begin
      tile_activation[lane] = held_window[ic_group_index*4 + lane][tap_index];
    end
  end
  gestureflow_mac_tile #(.OUT_LANES(OUT_LANES), .INPUT_LANES(4),
    .MAX_TAPS(16), .MAX_IC_GROUPS(IC_GROUPS)) mac_tile (
    .clk(clk), .rst_n(rst_n), .weight_write_valid(weight_write_valid),
    .weight_write_oc(weight_write_oc), .weight_write_tap(weight_write_tap),
    .weight_write_ic_group(weight_write_ic_group), .weight_write_data(weight_write_data),
    .start_valid(pending_window), .start_ready(tile_start_ready), .bias(bias),
    .output_lane_enable(output_lane_enable), .mac_valid(mac_active), .mac_ready(tile_mac_ready),
    .mac_tap(tap_index), .mac_ic_group(ic_group_index), .activation(tile_activation),
    .input_lane_enable(4'b1111),
    .mac_last((tap_index == 4'd15) && (ic_group_index == $clog2(IC_GROUPS)'(IC_GROUPS-1))),
    .result_valid(output_valid), .result_ready(output_ready), .result_psum(output_psum),
    .result_lane_enable(output_lane_enable_valid), .busy(busy), .protocol_error(protocol_error)
  );
  assign core_pixel_ready = !pending_window && !mac_active && !busy && !window_valid[0] && !output_valid;
  assign pixel_ready = core_pixel_ready && line_pixel_ready[0];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin pending_window <= 0; mac_active <= 0; tap_index <= 0; ic_group_index <= 0; held_window <= '0; end
    else begin
      if (window_valid[0] && !pending_window && !mac_active && !busy) begin held_window <= window_data; pending_window <= 1; end
      if (pending_window && tile_start_ready) begin pending_window <= 0; mac_active <= 1; tap_index <= 0; ic_group_index <= 0; end
      if (mac_active && tile_mac_ready) begin
        if (ic_group_index == $clog2(IC_GROUPS)'(IC_GROUPS-1)) begin
          ic_group_index <= 0;
          if (tap_index == 15) mac_active <= 0; else tap_index <= tap_index + 1'b1;
        end else ic_group_index <= ic_group_index + 1'b1;
      end
    end
  end
endmodule
