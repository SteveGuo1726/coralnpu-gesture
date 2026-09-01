// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Streaming TFLite SAME window front end for an RGB 4x4 convolution. The
// virtual input is padded by {top,left}=1 and {bottom,right}=2, so a stride-1
// HxW input produces exactly HxW windows. Input is stalled while window_ready
// is low; no ARM per-window command or off-chip repacking is required.
`timescale 1ns/1ps
module gestureflow_same4x4_rgb_window #(
  parameter int IMAGE_WIDTH = 96,
  parameter int IMAGE_HEIGHT = 96,
  parameter int CHANNELS = 3
) (
  input  logic clk,
  input  logic rst_n,
  input  logic frame_start,
  input  logic pixel_valid,
  output logic pixel_ready,
  input  logic signed [CHANNELS-1:0][7:0] pixel_data,
  // TFLite pads quantized convolution inputs with the input zero point, not
  // necessarily with the signed byte value zero. Keeping this explicit is
  // required when an RGB camera tensor uses zero_point=-128.
  input  logic signed [CHANNELS-1:0][7:0] padding_value,
  output logic window_valid,
  input  logic window_ready,
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
  logic [CHANNELS-1:0] channel_pixel_ready;
  logic [CHANNELS-1:0] channel_window_valid;
  logic signed [CHANNELS-1:0][15:0][7:0] channel_window_data;

  always_comb begin
    source_pixel_needed = active &&
      (virtual_row >= ROW_W'(1)) && (virtual_row <= ROW_W'(IMAGE_HEIGHT)) &&
      (virtual_column >= COL_W'(1)) && (virtual_column <= COL_W'(IMAGE_WIDTH));
    line_accept = channel_pixel_ready[0];
    line_pixel_valid = active && line_accept &&
      (!source_pixel_needed || pixel_valid);
    line_pixel_data = source_pixel_needed ? pixel_data : padding_value;
    pixel_ready = source_pixel_needed && line_accept;
    window_valid = channel_window_valid[0];
    window_data = channel_window_data;
  end

  for (genvar channel = 0; channel < CHANNELS; channel++) begin : rgb_rows
    gestureflow_line_window #(
      .IMAGE_WIDTH(PADDED_WIDTH),
      .KERNEL_SIZE(4)
    ) line_window (
      .clk(clk),
      .rst_n(rst_n),
      .frame_width(16'(PADDED_WIDTH)),
      .frame_start(frame_start),
      .pixel_valid(line_pixel_valid),
      .pixel_data(line_pixel_data[channel]),
      .pixel_ready(channel_pixel_ready[channel]),
      .window_ready(window_ready),
      .window_valid(channel_window_valid[channel]),
      .window_data(channel_window_data[channel])
    );
  end

  // active and the virtual coordinates feed the line-buffer enable path.
  // They must not carry asynchronous reset into an inferred RAMB18 control.
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
        // The window ending at virtual (3,3) is output (0,0). Coordinates
        // are captured with the emitted window and remain stable under MAC
        // backpressure.
        if ((virtual_row >= ROW_W'(3)) && (virtual_column >= COL_W'(3))) begin
          output_row <= {{(16-ROW_W){1'b0}}, virtual_row - ROW_W'(3)};
          output_column <= {{(16-COL_W){1'b0}}, virtual_column - COL_W'(3)};
        end
        if ((virtual_row == ROW_W'(PADDED_HEIGHT - 1)) &&
            (virtual_column == COL_W'(PADDED_WIDTH - 1))) begin
          active <= 1'b0;
          frame_done <= 1'b1;
        end else if (virtual_column == COL_W'(PADDED_WIDTH - 1)) begin
          virtual_column <= '0;
          virtual_row <= virtual_row + 1'b1;
        end else begin
          virtual_column <= virtual_column + 1'b1;
        end
      end
    end
  end
endmodule
