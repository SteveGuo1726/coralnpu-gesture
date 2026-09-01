// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// DMP streaming body-convolution engine for NHWC INT8 tensors.  It is the
// 8-input-lane companion to gestureflow_conv4x4_cin_same_stream and uses
// gestureflow_mac_tile_dmp instead of the single-product MAC tile.  One
// physical 16-tap window is held locally while the DMP tile walks all
// eight-channel input groups.  Each DSP48E1 therefore retires two output
// channels per accepted input lane, halving the input-channel time steps for
// the same number of DSP multipliers.
//
// KERNEL_SIZE selects whether taps [0..8] (3x3) or [0..15] (4x4) are active,
// without changing the 7020 banked BRAM or DSP placement shape.
`timescale 1ns/1ps
module gestureflow_conv4x4_cin_same_stream_dmp #(
  parameter int IMAGE_WIDTH = 96,
  parameter int IMAGE_HEIGHT = 96,
  parameter int INPUT_CHANNELS = 16,
  parameter int OUT_LANES = 32,
  parameter int KERNEL_SIZE = 4
) (
  input logic clk,
  input logic rst_n,
  input logic [15:0] image_width,
  input logic [15:0] image_height,
  // Runtime pointwise mode reuses the same DMP backend for 1x1.
  input logic pointwise_mode,
  input logic frame_start,
  input logic pixel_valid,
  output logic pixel_ready,
  input logic signed [INPUT_CHANNELS-1:0][7:0] pixel_data,
  input logic signed [INPUT_CHANNELS-1:0][7:0] input_zero_point,
  input logic [4:0] input_group_count,
  input logic [7:0] input_lane_enable,
  input logic weight_write_valid,
  input logic [((OUT_LANES/2) <= 1 ? 1 : $clog2(OUT_LANES/2))-1:0] weight_write_pair,
  input logic [3:0] weight_write_tap,
  input logic [(INPUT_CHANNELS <= 8 ? 1 : $clog2(INPUT_CHANNELS/8))-1:0] weight_write_ic_group,
  input logic [8*24-1:0] weight_write_data,
  input logic weight_bank_select,
  input logic read_bank_select,
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

  localparam int IC_GROUPS = INPUT_CHANNELS / 8;
  localparam int IC_GROUP_W = (IC_GROUPS <= 1) ? 1 : $clog2(IC_GROUPS);
  localparam int ACTIVE_TAPS = KERNEL_SIZE * KERNEL_SIZE;

  logic window_valid;
  logic spatial_window_ready;
  logic spatial_pixel_ready;
  logic point_pixel_ready;
  logic pending_window;
  logic mac_active;
  logic signed [INPUT_CHANNELS-1:0][15:0][7:0] window_data;
  logic signed [INPUT_CHANNELS-1:0][15:0][7:0] held_window;
  logic signed [INPUT_CHANNELS-1:0][7:0] held_pixel;
  logic [15:0] window_row;
  logic [15:0] window_column;
  logic [15:0] held_row;
  logic [15:0] held_column;
  logic [15:0] point_next_row;
  logic [15:0] point_next_column;
  logic point_active;
  logic point_pixel_accept;
  logic point_frame_done_pulse;
  logic spatial_frame_done;
  logic tile_start_ready;
  logic tile_mac_ready;
  logic [3:0] tap_index;
  logic [IC_GROUP_W-1:0] ic_group_index;
  logic signed [7:0][7:0] tile_activation;

  initial begin
    if ((INPUT_CHANNELS % 8) != 0) $error("INPUT_CHANNELS must be divisible by eight");
    if ((KERNEL_SIZE != 3) && (KERNEL_SIZE != 4)) $error("KERNEL_SIZE must be 3 or 4");
    if ((OUT_LANES % 2) != 0) $error("OUT_LANES must be even for DMP pairs");
  end

  assign spatial_window_ready = !pointwise_mode && !pending_window && !mac_active && !busy && !output_valid;
  assign point_pixel_ready = point_active && !pending_window && !mac_active && !busy && !output_valid;
  assign point_pixel_accept = pointwise_mode && pixel_valid && point_pixel_ready;
  assign pixel_ready = pointwise_mode ? point_pixel_ready : spatial_pixel_ready;
  assign frame_input_done = pointwise_mode ? point_frame_done_pulse : spatial_frame_done;

  gestureflow_same4x4_cin_window #(
    .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
    .CHANNELS(INPUT_CHANNELS), .KERNEL_SIZE(KERNEL_SIZE)
  ) same_window (
    .clk(clk), .rst_n(rst_n), .image_width(image_width), .image_height(image_height),
    .frame_start(frame_start && !pointwise_mode),
    .pixel_valid(pixel_valid && !pointwise_mode), .pixel_ready(spatial_pixel_ready), .pixel_data(pixel_data),
    .padding_value(input_zero_point), .window_valid(window_valid), .window_ready(spatial_window_ready),
    .window_data(window_data), .output_row(window_row), .output_column(window_column),
    .frame_done(spatial_frame_done)
  );

  always_comb begin
    tile_activation = '0;
    for (int lane = 0; lane < 8; lane++) begin
      if (pointwise_mode) begin
        tile_activation[lane] = held_pixel[int'(ic_group_index) * 8 + lane];
      end else begin
        tile_activation[lane] = held_window[int'(ic_group_index) * 8 + lane][tap_index];
      end
    end
    output_row = held_row;
    output_column = held_column;
  end

  gestureflow_mac_tile_dmp #(
    .OUT_LANES(OUT_LANES), .INPUT_LANES(8), .MAX_TAPS(16), .MAX_IC_GROUPS(IC_GROUPS)
  ) mac_tile (
    .clk(clk), .rst_n(rst_n), .weight_write_valid(weight_write_valid),
    .weight_write_pair(weight_write_pair), .weight_write_tap(weight_write_tap),
    .weight_write_ic_group(weight_write_ic_group), .weight_write_data(weight_write_data),
    .weight_bank_select(weight_bank_select), .read_bank_select(read_bank_select),
    .start_valid(pending_window), .start_ready(tile_start_ready), .bias(bias),
    .output_lane_enable(output_lane_enable), .mac_valid(mac_active), .mac_ready(tile_mac_ready),
    .mac_tap(pointwise_mode ? 4'd0 : tap_index), .mac_ic_group(ic_group_index),
    .activation(tile_activation), .input_lane_enable(input_lane_enable),
    .mac_last(pointwise_mode ?
      (ic_group_index == IC_GROUP_W'(input_group_count - 1'b1)) :
      ((tap_index == 4'(ACTIVE_TAPS - 1)) &&
       (ic_group_index == IC_GROUP_W'(input_group_count - 1'b1)))),
    .result_valid(output_valid), .result_ready(output_ready), .result_psum(output_psum),
    .result_lane_enable(output_lane_enable_valid), .busy(busy), .protocol_error(protocol_error)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pending_window <= 1'b0;
      mac_active <= 1'b0;
      tap_index <= '0;
      ic_group_index <= '0;
      held_pixel <= '0;
      /* verilator lint_off WIDTHCONCAT */
      held_window <= '0;
      /* verilator lint_on WIDTHCONCAT */
      held_row <= '0;
      held_column <= '0;
      point_next_row <= '0;
      point_next_column <= '0;
      point_active <= 1'b0;
      point_frame_done_pulse <= 1'b0;
    end else begin
      point_frame_done_pulse <= 1'b0;
      if (pointwise_mode && frame_start) begin
        point_active <= 1'b1;
        pending_window <= 1'b0;
        mac_active <= 1'b0;
        tap_index <= '0;
        ic_group_index <= '0;
        point_next_row <= '0;
        point_next_column <= '0;
      end
      if (!pointwise_mode && window_valid && spatial_window_ready) begin
        held_window <= window_data;
        held_row <= window_row;
        held_column <= window_column;
        pending_window <= 1'b1;
      end
      if (point_pixel_accept) begin
        held_pixel <= pixel_data;
        held_row <= point_next_row;
        held_column <= point_next_column;
        pending_window <= 1'b1;
        if ((point_next_row == image_height - 1'b1) && (point_next_column == image_width - 1'b1)) begin
          point_active <= 1'b0;
          point_frame_done_pulse <= 1'b1;
        end else if (point_next_column == image_width - 1'b1) begin
          point_next_column <= '0;
          point_next_row <= point_next_row + 1'b1;
        end else begin
          point_next_column <= point_next_column + 1'b1;
        end
      end
      if (pending_window && tile_start_ready) begin
        pending_window <= 1'b0;
        mac_active <= 1'b1;
        tap_index <= '0;
        ic_group_index <= '0;
      end
      if (mac_active && tile_mac_ready) begin
        if (ic_group_index == IC_GROUP_W'(input_group_count - 1'b1)) begin
          ic_group_index <= '0;
          if (pointwise_mode || (tap_index == 4'(ACTIVE_TAPS - 1))) begin
            mac_active <= 1'b0;
          end else begin
            tap_index <= tap_index + 1'b1;
          end
        end else begin
          ic_group_index <= ic_group_index + 1'b1;
        end
      end
    end
  end
endmodule
