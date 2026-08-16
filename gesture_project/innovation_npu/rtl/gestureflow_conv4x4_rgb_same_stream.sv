// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// First-layer autonomous engine: RGB pixels enter once, a SAME 4x4 front end
// creates every spatial window, and the 16x4 tile retains weight/INT32 state.
// This is intentionally a compute-side stream primitive; DDR row-DMA and
// output-bank writeback are connected by the layer scheduler in the next step.
`timescale 1ns/1ps
module gestureflow_conv4x4_rgb_same_stream #(
  parameter int IMAGE_WIDTH = 96,
  parameter int IMAGE_HEIGHT = 96,
  parameter int OUT_LANES = 16
) (
  input logic clk,
  input logic rst_n,
  input logic frame_start,
  input logic pixel_valid,
  output logic pixel_ready,
  input logic signed [2:0][7:0] pixel_rgb,
  input logic signed [2:0][7:0] input_zero_point,
  input logic weight_write_valid,
  input logic [$clog2(OUT_LANES)-1:0] weight_write_oc,
  input logic [3:0] weight_write_tap,
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
  logic window_valid, window_ready, pending_window, mac_active;
  logic signed [2:0][15:0][7:0] window_data, held_window;
  logic [15:0] window_row, window_column, held_row, held_column;
  logic tile_start_ready, tile_mac_ready;
  logic [3:0] tap_index;
  logic signed [3:0][7:0] tile_activation;

  assign window_ready = !pending_window && !mac_active && !busy && !output_valid;

  gestureflow_same4x4_rgb_window #(
    .IMAGE_WIDTH(IMAGE_WIDTH),
    .IMAGE_HEIGHT(IMAGE_HEIGHT)
  ) same_window (
    .clk(clk), .rst_n(rst_n), .frame_start(frame_start),
    .pixel_valid(pixel_valid), .pixel_ready(pixel_ready), .pixel_data(pixel_rgb),
    .padding_value(input_zero_point),
    .window_valid(window_valid), .window_ready(window_ready), .window_data(window_data),
    .output_row(window_row), .output_column(window_column), .frame_done(frame_input_done)
  );

  always_comb begin
    tile_activation = '0;
    for (int channel = 0; channel < 3; channel++) begin
      tile_activation[channel] = held_window[channel][tap_index];
    end
    output_row = held_row;
    output_column = held_column;
  end

  gestureflow_mac_tile #(
    .OUT_LANES(OUT_LANES), .INPUT_LANES(4), .MAX_TAPS(16), .MAX_IC_GROUPS(1)
  ) mac_tile (
    .clk(clk), .rst_n(rst_n),
    .weight_write_valid(weight_write_valid), .weight_write_oc(weight_write_oc),
    .weight_write_tap(weight_write_tap), .weight_write_ic_group('0),
    .weight_write_data(weight_write_data),
    .start_valid(pending_window), .start_ready(tile_start_ready), .bias(bias),
    .output_lane_enable(output_lane_enable), .mac_valid(mac_active),
    .mac_ready(tile_mac_ready), .mac_tap(tap_index), .mac_ic_group('0),
    .activation(tile_activation), .input_lane_enable(4'b0111),
    .mac_last(tap_index == 4'd15), .result_valid(output_valid),
    .result_ready(output_ready), .result_psum(output_psum),
    .result_lane_enable(output_lane_enable_valid), .busy(busy),
    .protocol_error(protocol_error)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending_window <= 1'b0;
      mac_active <= 1'b0;
      tap_index <= '0;
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
