// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Generic NHWC, stride-one SAME 4x4 window front end. It is the body-layer
// counterpart to the RGB ingress: all channels advance on the same raster
// coordinate, each channel has a three-row BRAM delay, and the current tensor
// zero point supplies the virtual border. The next MAC stage may stall a
// window; input pixels are back-pressured without losing channel alignment.
`timescale 1ns/1ps
module gestureflow_same4x4_cin_window #(
  parameter int IMAGE_WIDTH = 96,
  parameter int IMAGE_HEIGHT = 96,
  parameter int CHANNELS = 16
) (
  input logic clk,
  input logic rst_n,
  input logic [15:0] image_width,
  input logic [15:0] image_height,
  input logic frame_start,
  input logic pixel_valid,
  output logic pixel_ready,
  input logic signed [CHANNELS-1:0][7:0] pixel_data,
  input logic signed [CHANNELS-1:0][7:0] padding_value,
  output logic window_valid,
  input logic window_ready,
  output logic signed [CHANNELS-1:0][15:0][7:0] window_data,
  output logic [15:0] output_row,
  output logic [15:0] output_column,
  output logic frame_done
);
  localparam int PADDED_WIDTH = IMAGE_WIDTH + 3;
  localparam int PADDED_HEIGHT = IMAGE_HEIGHT + 3;
  localparam int ROW_W = (PADDED_HEIGHT <= 1) ? 1 : $clog2(PADDED_HEIGHT);
  localparam int COL_W = (PADDED_WIDTH <= 1) ? 1 : $clog2(PADDED_WIDTH);

  logic active;
  logic [ROW_W-1:0] virtual_row;
  logic [COL_W-1:0] virtual_column;
  logic source_pixel_needed;
  logic line_accept;
  logic line_pixel_valid;
  logic signed [CHANNELS-1:0][7:0] line_pixel_data;
  logic line_pixel_ready;
  logic packed_window_valid;
  logic signed [15:0][CHANNELS*8-1:0] packed_window_data;
  logic [15:0] padded_width, padded_height;

  always_comb begin
    padded_width = image_width + 16'd3;
    padded_height = image_height + 16'd3;
    source_pixel_needed = active &&
      (virtual_row >= ROW_W'(1)) && (virtual_row <= ROW_W'(image_height)) &&
      (virtual_column >= COL_W'(1)) && (virtual_column <= COL_W'(image_width));
    line_accept = line_pixel_ready;
    line_pixel_valid = active && line_accept && (!source_pixel_needed || pixel_valid);
    line_pixel_data = source_pixel_needed ? pixel_data : padding_value;
    pixel_ready = source_pixel_needed && line_accept;
    window_valid = packed_window_valid;
  end

  gestureflow_line_window_vector #(
    .IMAGE_WIDTH(PADDED_WIDTH), .KERNEL_SIZE(4), .DATA_WIDTH(CHANNELS * 8)
  ) line_window (
    .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .frame_width(padded_width),
    .pixel_valid(line_pixel_valid), .pixel_data(line_pixel_data), .pixel_ready(line_pixel_ready),
    .window_ready(window_ready), .window_valid(packed_window_valid), .window_data(packed_window_data)
  );

  for (genvar channel = 0; channel < CHANNELS; channel++) begin : unpack_channel
    for (genvar tap = 0; tap < 16; tap++) begin : unpack_tap
      assign window_data[channel][tap] = packed_window_data[tap][channel*8 +: 8];
    end
  end

  // These controls feed inferred BRAM enables and addresses through the line
  // windows, so reset remains synchronous for implementation reliability.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      active <= 1'b0;
      virtual_row <= '0;
      virtual_column <= '0;
      output_row <= '0;
      output_column <= '0;
      frame_done <= 1'b0;
    end else begin
      frame_done <= 1'b0;
      if (frame_start) begin
        active <= 1'b1;
        virtual_row <= '0;
        virtual_column <= '0;
        output_row <= '0;
        output_column <= '0;
      end else if (line_pixel_valid) begin
        if ((virtual_row >= ROW_W'(3)) && (virtual_column >= COL_W'(3))) begin
          output_row <= {{(16-ROW_W){1'b0}}, virtual_row - ROW_W'(3)};
          output_column <= {{(16-COL_W){1'b0}}, virtual_column - COL_W'(3)};
        end
        if ((virtual_row == ROW_W'(padded_height - 1'b1)) &&
            (virtual_column == COL_W'(padded_width - 1'b1))) begin
          active <= 1'b0;
          frame_done <= 1'b1;
        end else if (virtual_column == COL_W'(padded_width - 1'b1)) begin
          virtual_column <= '0;
          virtual_row <= virtual_row + 1'b1;
        end else begin
          virtual_column <= virtual_column + 1'b1;
        end
      end
    end
  end
endmodule
