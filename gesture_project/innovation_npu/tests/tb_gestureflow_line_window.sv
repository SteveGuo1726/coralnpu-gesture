// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps

module tb_gestureflow_line_window;
  localparam int IMAGE_WIDTH = 6;
  localparam int KERNEL_SIZE = 4;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic frame_start;
  logic pixel_valid;
  logic pixel_ready;
  logic window_ready = 1'b1;
  logic signed [7:0] pixel_data;
  logic window_valid;
  logic signed [KERNEL_SIZE*KERNEL_SIZE-1:0][7:0] window_data;
  integer windows_seen = 0;

  gestureflow_line_window #(
    .IMAGE_WIDTH(IMAGE_WIDTH),
    .KERNEL_SIZE(KERNEL_SIZE)
  ) dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (window_valid) begin
      int output_row;
      int output_column;
      output_row = KERNEL_SIZE - 1 + (windows_seen / (IMAGE_WIDTH - KERNEL_SIZE + 1));
      output_column = KERNEL_SIZE - 1 + (windows_seen % (IMAGE_WIDTH - KERNEL_SIZE + 1));
      for (int row = 0; row < KERNEL_SIZE; row++) begin
        for (int column = 0; column < KERNEL_SIZE; column++) begin
          int expected;
          expected = (output_row - (KERNEL_SIZE - 1) + row) * 10 +
                     (output_column - (KERNEL_SIZE - 1) + column);
          if (window_data[row*KERNEL_SIZE + column] !== expected[7:0]) begin
            $fatal(1, "window %0d element %0d,%0d expected %0d got %0d",
                   windows_seen, row, column, expected, window_data[row*KERNEL_SIZE + column]);
          end
        end
      end
      windows_seen = windows_seen + 1;
    end
  end

  initial begin
    frame_start = 1'b0;
    pixel_valid = 1'b0;
    pixel_data = '0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    frame_start = 1'b1;
    @(negedge clk);
    frame_start = 1'b0;

    for (int row = 0; row < 5; row++) begin
      for (int column = 0; column < IMAGE_WIDTH; column++) begin
        while (!pixel_ready) @(negedge clk);
        pixel_data = 8'(row * 10 + column);
        pixel_valid = 1'b1;
        @(negedge clk);
      end
    end
    pixel_valid = 1'b0;
    repeat (4) @(negedge clk);
    if (windows_seen != 6) begin
      $fatal(1, "expected 6 windows, got %0d", windows_seen);
    end
    $display("GESTUREFLOW_LINE_WINDOW_PASS windows=%0d", windows_seen);
    $finish;
  end
endmodule
