// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps

module tb_gestureflow_conv4x4_stream;
  localparam int IMAGE_WIDTH = 6;
  localparam int OUT_LANES = 4;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic frame_start;
  logic pixel_valid;
  logic pixel_ready;
  logic signed [7:0] pixel_data;
  logic weight_write_valid;
  logic [$clog2(OUT_LANES)-1:0] weight_write_oc;
  logic [3:0] weight_write_tap;
  logic signed [7:0] weight_write_data;
  logic signed [OUT_LANES-1:0][31:0] bias;
  logic [OUT_LANES-1:0] output_lane_enable;
  logic output_valid;
  logic output_ready;
  logic signed [OUT_LANES-1:0][31:0] output_psum;
  logic [OUT_LANES-1:0] output_lane_enable_valid;
  logic busy;
  logic protocol_error;
  integer outputs_seen = 0;

  gestureflow_conv4x4_stream #(
    .IMAGE_WIDTH(IMAGE_WIDTH),
    .OUT_LANES(OUT_LANES)
  ) dut (.*);

  always #5 clk = ~clk;

  task automatic load_weight(input int oc, input int tap, input int value);
    begin
      @(negedge clk);
      weight_write_valid = 1'b1;
      weight_write_oc = oc[$clog2(OUT_LANES)-1:0];
      weight_write_tap = tap[3:0];
      weight_write_data = value[7:0];
      @(negedge clk);
      weight_write_valid = 1'b0;
    end
  endtask

  task automatic send_pixel(input int value);
    begin
      while (!pixel_ready) @(negedge clk);
      pixel_data = value[7:0];
      pixel_valid = 1'b1;
      @(negedge clk);
      pixel_valid = 1'b0;
    end
  endtask

  always @(posedge clk) begin
    if (output_valid && output_ready) begin
      int output_row;
      int output_column;
      output_row = outputs_seen / (IMAGE_WIDTH - 3);
      output_column = outputs_seen % (IMAGE_WIDTH - 3);
      for (int oc = 0; oc < OUT_LANES; oc++) begin
        int expected;
        expected = oc * 7;
        for (int row = 0; row < 4; row++) begin
          for (int column = 0; column < 4; column++) begin
            int tap;
            int pixel;
            tap = row * 4 + column;
            pixel = (output_row + row) * 10 + output_column + column;
            expected += pixel * (oc + tap + 1);
          end
        end
        if (output_psum[oc] !== expected) begin
          $fatal(1, "output %0d lane %0d expected %0d got %0d",
                 outputs_seen, oc, expected, output_psum[oc]);
        end
      end
      if (output_lane_enable_valid != 4'b1111) begin
        $fatal(1, "invalid output lane mask");
      end
      outputs_seen = outputs_seen + 1;
    end
  end

  initial begin
    frame_start = 1'b0;
    pixel_valid = 1'b0;
    pixel_data = '0;
    weight_write_valid = 1'b0;
    weight_write_oc = '0;
    weight_write_tap = '0;
    weight_write_data = '0;
    bias = '0;
    bias[0] = 0;
    bias[1] = 7;
    bias[2] = 14;
    bias[3] = 21;
    output_lane_enable = 4'b1111;
    output_ready = 1'b1;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int oc = 0; oc < OUT_LANES; oc++) begin
      for (int tap = 0; tap < 16; tap++) begin
        load_weight(oc, tap, oc + tap + 1);
      end
    end

    @(negedge clk);
    frame_start = 1'b1;
    @(negedge clk);
    frame_start = 1'b0;
    for (int row = 0; row < 5; row++) begin
      for (int column = 0; column < IMAGE_WIDTH; column++) begin
        send_pixel(row * 10 + column);
      end
    end
    for (int wait_cycles = 0; wait_cycles < 100 && outputs_seen < 6; wait_cycles++) begin
      @(negedge clk);
    end
    if (outputs_seen != 6) begin
      $fatal(1, "expected 6 convolution outputs, got %0d", outputs_seen);
    end
    if (protocol_error) begin
      $fatal(1, "tile reported a protocol error");
    end
    $display("GESTUREFLOW_CONV4X4_STREAM_PASS outputs=%0d", outputs_seen);
    $finish;
  end
endmodule
