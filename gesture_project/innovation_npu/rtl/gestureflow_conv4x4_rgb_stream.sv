// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// RGB first-layer variant of the GestureFlow stream. The three RGB channels
// occupy lanes 0..2 of the four-lane MAC tile; lane 3 is explicitly masked.
// This matches the current student's Cin=3 stem without inventing padding
// pixels or relying on an unverified implicit zero-weight convention.
`timescale 1ns/1ps
module gestureflow_conv4x4_rgb_stream #(
  parameter int IMAGE_WIDTH = 96,
  parameter int OUT_LANES = 16
) (
  input  logic clk,
  input  logic rst_n,
  input  logic frame_start,
  input  logic pixel_valid,
  output logic pixel_ready,
  input  logic signed [2:0][7:0] pixel_rgb,

  input  logic weight_write_valid,
  input  logic [$clog2(OUT_LANES)-1:0] weight_write_oc,
  input  logic [3:0] weight_write_tap,
  input  logic signed [3:0][7:0] weight_write_data,
  input  logic signed [OUT_LANES-1:0][31:0] bias,
  input  logic [OUT_LANES-1:0] output_lane_enable,

  output logic output_valid,
  input  logic output_ready,
  output logic signed [OUT_LANES-1:0][31:0] output_psum,
  output logic [OUT_LANES-1:0] output_lane_enable_valid,
  output logic busy,
  output logic protocol_error
);

  logic [2:0] line_window_valid;
  logic signed [2:0][15:0][7:0] line_window_data;
  logic pending_window;
  logic signed [2:0][15:0][7:0] held_window;
  logic mac_active;
  logic [3:0] tap_index;
  logic tile_start_ready;
  logic tile_mac_ready;
  logic signed [3:0][7:0] tile_activation;

  for (genvar channel = 0; channel < 3; channel++) begin : rgb_line_windows
    gestureflow_line_window #(
      .IMAGE_WIDTH(IMAGE_WIDTH),
      .KERNEL_SIZE(4)
    ) line_window (
      .clk(clk),
      .rst_n(rst_n),
      .frame_start(frame_start),
      .pixel_valid(pixel_valid && pixel_ready),
      .pixel_data(pixel_rgb[channel]),
      .window_ready(1'b1),
      .window_valid(line_window_valid[channel]),
      .window_data(line_window_data[channel])
    );
  end

  always_comb begin
    tile_activation = '0;
    for (int channel = 0; channel < 3; channel++) begin
      tile_activation[channel] = held_window[channel][tap_index];
    end
  end

  gestureflow_mac_tile #(
    .OUT_LANES(OUT_LANES),
    .INPUT_LANES(4),
    .MAX_TAPS(16),
    .MAX_IC_GROUPS(2)
  ) mac_tile (
    .clk(clk),
    .rst_n(rst_n),
    .weight_write_valid(weight_write_valid),
    .weight_write_oc(weight_write_oc),
    .weight_write_tap(weight_write_tap),
    .weight_write_ic_group('0),
    .weight_write_data(weight_write_data),
    .start_valid(pending_window),
    .start_ready(tile_start_ready),
    .bias(bias),
    .output_lane_enable(output_lane_enable),
    .mac_valid(mac_active),
    .mac_ready(tile_mac_ready),
    .mac_tap(tap_index),
    .mac_ic_group('0),
    .activation(tile_activation),
    .input_lane_enable(4'b0111),
    .mac_last(tap_index == 4'd15),
    .result_valid(output_valid),
    .result_ready(output_ready),
    .result_psum(output_psum),
    .result_lane_enable(output_lane_enable_valid),
    .busy(busy),
    .protocol_error(protocol_error)
  );

  assign pixel_ready = !pending_window && !mac_active && !busy &&
                       !line_window_valid[0] && !output_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending_window <= 1'b0;
      held_window <= '0;
      mac_active <= 1'b0;
      tap_index <= '0;
    end else begin
      if (line_window_valid[0] && !pending_window && !mac_active && !busy) begin
        held_window <= line_window_data;
        pending_window <= 1'b1;
      end
      if (pending_window && tile_start_ready) begin
        pending_window <= 1'b0;
        mac_active <= 1'b1;
        tap_index <= '0;
      end
      if (mac_active && tile_mac_ready) begin
        if (tap_index == 4'd15) begin
          mac_active <= 1'b0;
        end else begin
          tap_index <= tap_index + 1'b1;
        end
      end
    end
  end

endmodule
