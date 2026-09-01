// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Generic NHWC INT8 pointwise stream. One raster pixel vector is held locally
// while the existing 16-output x 4-input-lane MAC tile walks all input-channel
// groups with tap fixed at zero, so INT32 partial sums never leave the tile.
// This is the natural hardware path for static head 1x1, temporal embedding
// 1x1, and temporal fusion 1x1 without paying the line-buffer cost of the
// spatial 3x3/4x4 front end.
`timescale 1ns/1ps
module gestureflow_conv1x1_cin_stream #(
  parameter int IMAGE_WIDTH = 12,
  parameter int IMAGE_HEIGHT = 12,
  parameter int INPUT_CHANNELS = 80,
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
  input logic [4:0] input_group_count,
  input logic [3:0] input_lane_enable,
  input logic weight_write_valid,
  input logic [$clog2(OUT_LANES)-1:0] weight_write_oc,
  input logic [3:0] weight_write_tap,
  input logic [(INPUT_CHANNELS <= 4 ? 1 : $clog2(INPUT_CHANNELS/4))-1:0] weight_write_ic_group,
  input logic signed [3:0][7:0] weight_write_data,
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
  localparam int IC_GROUPS = INPUT_CHANNELS / 4;
  localparam int IC_GROUP_W = (IC_GROUPS <= 1) ? 1 : $clog2(IC_GROUPS);

  logic active;
  logic pending_pixel;
  logic mac_active;
  logic [15:0] next_row;
  logic [15:0] next_column;
  logic [15:0] held_row;
  logic [15:0] held_column;
  logic signed [INPUT_CHANNELS-1:0][7:0] held_pixel;
  logic tile_start_ready;
  logic tile_mac_ready;
  logic [IC_GROUP_W-1:0] ic_group_index;
  logic signed [3:0][7:0] tile_activation;
  logic pixel_accept;

  initial begin
    if ((INPUT_CHANNELS % 4) != 0) $error("INPUT_CHANNELS must be divisible by four");
  end

  always_comb begin
    pixel_ready = active && !pending_pixel && !mac_active && !busy && !output_valid;
    pixel_accept = pixel_valid && pixel_ready;
    tile_activation = '0;
    for (int lane = 0; lane < 4; lane++) begin
      tile_activation[lane] = held_pixel[int'(ic_group_index) * 4 + lane];
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
    .weight_bank_select(weight_bank_select),
    .read_bank_select(read_bank_select),
    .start_valid(pending_pixel), .start_ready(tile_start_ready), .bias(bias),
    .output_lane_enable(output_lane_enable), .mac_valid(mac_active), .mac_ready(tile_mac_ready),
    .mac_tap('0), .mac_ic_group(ic_group_index), .activation(tile_activation),
    .input_lane_enable(input_lane_enable),
    .mac_last(ic_group_index == IC_GROUP_W'(input_group_count - 1'b1)),
    .result_valid(output_valid), .result_ready(output_ready), .result_psum(output_psum),
    .result_lane_enable(output_lane_enable_valid), .busy(busy), .protocol_error(protocol_error)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      active <= 1'b0;
      pending_pixel <= 1'b0;
      mac_active <= 1'b0;
      next_row <= '0;
      next_column <= '0;
      held_row <= '0;
      held_column <= '0;
      held_pixel <= '0;
      ic_group_index <= '0;
      frame_input_done <= 1'b0;
    end else begin
      frame_input_done <= 1'b0;
      if (frame_start) begin
        active <= 1'b1;
        pending_pixel <= 1'b0;
        mac_active <= 1'b0;
        next_row <= '0;
        next_column <= '0;
        held_row <= '0;
        held_column <= '0;
        ic_group_index <= '0;
      end

      if (pixel_accept) begin
        held_pixel <= pixel_data;
        held_row <= next_row;
        held_column <= next_column;
        pending_pixel <= 1'b1;
        if ((next_row == image_height - 1'b1) && (next_column == image_width - 1'b1)) begin
          active <= 1'b0;
          frame_input_done <= 1'b1;
        end else if (next_column == image_width - 1'b1) begin
          next_column <= '0;
          next_row <= next_row + 1'b1;
        end else begin
          next_column <= next_column + 1'b1;
        end
      end

      if (pending_pixel && tile_start_ready) begin
        pending_pixel <= 1'b0;
        mac_active <= 1'b1;
        ic_group_index <= '0;
      end

      if (mac_active && tile_mac_ready) begin
        if (ic_group_index == IC_GROUP_W'(input_group_count - 1'b1)) begin
          ic_group_index <= '0;
          mac_active <= 1'b0;
        end else begin
          ic_group_index <= ic_group_index + 1'b1;
        end
      end
    end
  end
endmodule
