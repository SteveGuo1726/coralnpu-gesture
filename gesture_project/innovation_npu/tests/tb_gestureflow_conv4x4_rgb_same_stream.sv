// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_conv4x4_rgb_same_stream;
  localparam int IMAGE_WIDTH = 4;
  localparam int IMAGE_HEIGHT = 3;
  logic clk = 0, rst_n = 0, frame_start = 0, pixel_valid = 0, pixel_ready;
  logic signed [2:0][7:0] pixel_rgb;
  logic signed [2:0][7:0] input_zero_point;
  logic weight_write_valid = 0;
  logic [0:0] weight_write_oc;
  logic [3:0] weight_write_tap;
  logic signed [3:0][7:0] weight_write_data;
  logic signed [1:0][31:0] bias;
  logic [1:0] output_lane_enable = 2'b11;
  logic output_valid, output_ready = 1;
  logic signed [1:0][31:0] output_psum;
  logic [1:0] output_lane_enable_valid;
  logic [15:0] output_row, output_column;
  logic busy, protocol_error, frame_input_done;
  integer outputs_seen = 0;
  logic input_done_seen = 0;

  gestureflow_conv4x4_rgb_same_stream #(
    .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT), .OUT_LANES(2)
  ) dut (.*);
  always #5 clk = ~clk;

  function automatic integer sample(input integer row, input integer column, input integer channel);
    if ((row < 0) || (row >= IMAGE_HEIGHT) || (column < 0) || (column >= IMAGE_WIDTH)) begin
      sample = 0;
    end else begin
      sample = 1 + row * IMAGE_WIDTH + column + channel * 20;
    end
  endfunction

  function automatic integer expected_lane0(input integer out_row, input integer out_column);
    integer kr, kc;
    begin
      expected_lane0 = 7;
      for (kr = 0; kr < 4; kr++) begin
        for (kc = 0; kc < 4; kc++) begin
          expected_lane0 = expected_lane0 + sample(out_row + kr - 1, out_column + kc - 1, 0);
          expected_lane0 = expected_lane0 - 2 * sample(out_row + kr - 1, out_column + kc - 1, 1);
          expected_lane0 = expected_lane0 + 3 * sample(out_row + kr - 1, out_column + kc - 1, 2);
        end
      end
    end
  endfunction

  task automatic write_weight(input integer oc, input integer tap);
    begin
      @(negedge clk);
      weight_write_valid = 1'b1;
      weight_write_oc = 1'(oc);
      weight_write_tap = 4'(tap);
      if (oc == 0) begin
        weight_write_data[0] = 8'sd1;
        weight_write_data[1] = -8'sd2;
        weight_write_data[2] = 8'sd3;
      end else begin
        weight_write_data[0] = -8'sd1;
        weight_write_data[1] = 8'sd2;
        weight_write_data[2] = -8'sd3;
      end
      weight_write_data[3] = 0;
      @(negedge clk);
      weight_write_valid = 1'b0;
    end
  endtask

  always @(posedge clk) begin
    integer exp0;
    if (frame_input_done) input_done_seen = 1'b1;
    if (output_valid) begin
      exp0 = expected_lane0(int'(output_row), int'(output_column));
      if ((int'(output_row) >= IMAGE_HEIGHT) || (int'(output_column) >= IMAGE_WIDTH) ||
          (output_psum[0] !== exp0) || (output_psum[1] !== (-exp0 - 4)) ||
          (output_lane_enable_valid !== 2'b11)) begin
        $fatal(1, "SAME output (%0d,%0d): got %0d,%0d expected %0d,%0d mask=%b",
          output_row, output_column, output_psum[0], output_psum[1], exp0,
          -exp0 - 4, output_lane_enable_valid);
      end
      outputs_seen = outputs_seen + 1;
    end
  end

  initial begin
    pixel_rgb = '0;
    input_zero_point = '0;
    weight_write_oc = '0;
    weight_write_tap = '0;
    weight_write_data = '0;
    bias = '0;
    bias[0] = 7;
    bias[1] = -11;
    repeat (3) @(negedge clk);
    rst_n = 1;
    for (int oc = 0; oc < 2; oc++) begin
      for (int tap = 0; tap < 16; tap++) begin
        write_weight(oc, tap);
      end
    end
    @(negedge clk);
    frame_start = 1;
    @(negedge clk);
    frame_start = 0;
    for (int row = 0; row < IMAGE_HEIGHT; row++) begin
      for (int column = 0; column < IMAGE_WIDTH; column++) begin
        while (!pixel_ready) @(negedge clk);
        pixel_rgb[0] = 8'(sample(row, column, 0));
        pixel_rgb[1] = 8'(sample(row, column, 1));
        pixel_rgb[2] = 8'(sample(row, column, 2));
        pixel_valid = 1;
        @(negedge clk);
        pixel_valid = 0;
      end
    end
    for (int watchdog = 0; watchdog < 2000 && outputs_seen < IMAGE_WIDTH * IMAGE_HEIGHT; watchdog++) begin
      @(negedge clk);
    end
    if (outputs_seen != IMAGE_WIDTH * IMAGE_HEIGHT || protocol_error || !input_done_seen) begin
      $fatal(1, "SAME stream incomplete outputs=%0d done=%b fault=%b",
        outputs_seen, input_done_seen, protocol_error);
    end
    $display("GESTUREFLOW_CONV4X4_RGB_SAME_STREAM_PASS outputs=%0d", outputs_seen);
    $finish;
  end
endmodule
