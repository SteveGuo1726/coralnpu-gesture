// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// First integrated GestureFlow datapath: input stream -> four-row rolling
// window -> locally weighted INT8 MAC tile -> INT32 output. The deliberately
// small single-input-channel wrapper proves autonomous spatial scheduling;
// the next wrapper extends the same interfaces to input-channel groups.
`timescale 1ns/1ps
module gestureflow_conv4x4_stream #(
  parameter int IMAGE_WIDTH = 96,
  parameter int OUT_LANES = 16
) (
  input  logic clk,
  input  logic rst_n,
  input  logic frame_start,
  input  logic pixel_valid,
  output logic pixel_ready,
  input  logic signed [7:0] pixel_data,

  input  logic weight_write_valid,
  input  logic [$clog2(OUT_LANES)-1:0] weight_write_oc,
  input  logic [3:0] weight_write_tap,
  input  logic signed [7:0] weight_write_data,
  input  logic signed [OUT_LANES-1:0][31:0] bias,
  input  logic [OUT_LANES-1:0] output_lane_enable,

  output logic output_valid,
  input  logic output_ready,
  output logic signed [OUT_LANES-1:0][31:0] output_psum,
  output logic [OUT_LANES-1:0] output_lane_enable_valid,
  output logic busy,
  output logic protocol_error
);

  logic line_window_valid;
  logic signed [15:0][7:0] line_window_data;
  logic pending_window;
  logic signed [15:0][7:0] held_window;
  logic mac_active;
  logic [3:0] tap_index;

  logic tile_start_valid;
  logic tile_start_ready;
  logic tile_mac_valid;
  logic tile_mac_ready;
  logic [3:0] tile_mac_tap;
  logic [0:0] tile_mac_ic_group;
  logic signed [0:0][7:0] tile_activation;
  logic [0:0] tile_input_lane_enable;
  logic tile_mac_last;
  logic signed [0:0][7:0] tile_weight_write_data;
  logic [0:0] tile_weight_write_ic_group;

  gestureflow_line_window #(
    .IMAGE_WIDTH(IMAGE_WIDTH),
    .KERNEL_SIZE(4)
  ) line_window (
    .clk(clk),
    .rst_n(rst_n),
    .frame_start(frame_start),
    .pixel_valid(pixel_valid && pixel_ready),
    .pixel_data(pixel_data),
    .window_valid(line_window_valid),
    .window_data(line_window_data)
  );

  always_comb begin
    tile_weight_write_data = '0;
    tile_weight_write_data[0] = weight_write_data;
    tile_weight_write_ic_group = '0;
    tile_activation[0] = held_window[tap_index];
    tile_input_lane_enable = 1'b1;
    tile_mac_tap = tap_index;
    tile_mac_ic_group = '0;
    tile_mac_last = tap_index == 4'd15;
    tile_start_valid = pending_window;
    tile_mac_valid = mac_active;
  end

  gestureflow_mac_tile #(
    .OUT_LANES(OUT_LANES),
    .INPUT_LANES(1),
    .MAX_TAPS(16),
    .MAX_IC_GROUPS(2)
  ) mac_tile (
    .clk(clk),
    .rst_n(rst_n),
    .weight_write_valid(weight_write_valid),
    .weight_write_oc(weight_write_oc),
    .weight_write_tap(weight_write_tap),
    .weight_write_ic_group(tile_weight_write_ic_group),
    .weight_write_data(tile_weight_write_data),
    .start_valid(tile_start_valid),
    .start_ready(tile_start_ready),
    .bias(bias),
    .output_lane_enable(output_lane_enable),
    .mac_valid(tile_mac_valid),
    .mac_ready(tile_mac_ready),
    .mac_tap(tile_mac_tap),
    .mac_ic_group(tile_mac_ic_group),
    .activation(tile_activation),
    .input_lane_enable(tile_input_lane_enable),
    .mac_last(tile_mac_last),
    .result_valid(output_valid),
    .result_ready(output_ready),
    .result_psum(output_psum),
    .result_lane_enable(output_lane_enable_valid),
    .busy(busy),
    .protocol_error(protocol_error)
  );

  // The input side pauses only after a complete window is emitted, not at
  // every pixel. That preserves the rolling-buffer reuse without an external
  // per-window command protocol.
  assign pixel_ready = !pending_window && !mac_active && !busy &&
                       !line_window_valid && !output_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending_window <= 1'b0;
      held_window <= '0;
      mac_active <= 1'b0;
      tap_index <= '0;
    end else begin
      if (line_window_valid && !pending_window && !mac_active && !busy) begin
        held_window <= line_window_data;
        pending_window <= 1'b1;
      end
      if (tile_start_valid && tile_start_ready) begin
        pending_window <= 1'b0;
        mac_active <= 1'b1;
        tap_index <= '0;
      end
      if (tile_mac_valid && tile_mac_ready) begin
        if (tile_mac_last) begin
          mac_active <= 1'b0;
        end else begin
          tap_index <= tap_index + 1'b1;
        end
      end
    end
  end

endmodule
