// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_conv1x1_cin_stream;
  localparam int IMAGE_WIDTH = 2;
  localparam int IMAGE_HEIGHT = 2;
  localparam int INPUT_CHANNELS = 4;
  localparam int OUT_LANES = 2;
  localparam int OUTPUT_COUNT = IMAGE_WIDTH * IMAGE_HEIGHT;

  logic clk = 0;
  logic rst_n = 0;
  logic frame_start = 0;
  logic pixel_valid = 0;
  logic pixel_ready;
  logic signed [INPUT_CHANNELS-1:0][7:0] pixel_data;
  logic [4:0] input_group_count = 5'd1;
  logic [3:0] input_lane_enable = 4'hf;
  logic weight_write_valid = 0;
  logic [$clog2(OUT_LANES)-1:0] weight_write_oc = '0;
  logic [3:0] weight_write_tap = '0;
  logic [(INPUT_CHANNELS <= 4 ? 1 : $clog2(INPUT_CHANNELS/4))-1:0] weight_write_ic_group = '0;
  logic signed [3:0][7:0] weight_write_data = '0;
  logic weight_bank_select = 0;
  logic read_bank_select = 0;
  logic signed [OUT_LANES-1:0][31:0] bias = '0;
  logic [OUT_LANES-1:0] output_lane_enable = 2'b01;
  logic output_valid;
  logic output_ready = 1;
  logic signed [OUT_LANES-1:0][31:0] output_psum;
  logic [OUT_LANES-1:0] output_lane_enable_valid;
  logic [15:0] output_row, output_column;
  logic busy, protocol_error, frame_input_done;
  logic frame_input_done_seen = 0;
  integer outputs_seen = 0;

  gestureflow_conv1x1_cin_stream #(
    .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
    .INPUT_CHANNELS(INPUT_CHANNELS), .OUT_LANES(OUT_LANES)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .image_width(16'(IMAGE_WIDTH)), .image_height(16'(IMAGE_HEIGHT)),
    .frame_start(frame_start), .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
    .pixel_data(pixel_data), .input_group_count(input_group_count), .input_lane_enable(input_lane_enable),
    .weight_write_valid(weight_write_valid), .weight_write_oc(weight_write_oc),
    .weight_write_tap(weight_write_tap), .weight_write_ic_group(weight_write_ic_group),
    .weight_write_data(weight_write_data), .weight_bank_select(weight_bank_select), .read_bank_select(read_bank_select),
    .bias(bias), .output_lane_enable(output_lane_enable), .output_valid(output_valid),
    .output_ready(output_ready), .output_psum(output_psum),
    .output_lane_enable_valid(output_lane_enable_valid), .output_row(output_row),
    .output_column(output_column), .busy(busy), .protocol_error(protocol_error),
    .frame_input_done(frame_input_done)
  );

  always #5 clk = ~clk;

  task automatic write_weights;
    begin
      @(negedge clk);
      weight_write_valid = 1'b1;
      weight_write_oc = '0;
      weight_write_tap = '0;
      weight_write_ic_group = '0;
      weight_write_data = '{default:8'sd1};
      @(negedge clk);
      weight_write_valid = 1'b0;
    end
  endtask

  always_ff @(posedge clk) begin
    if (frame_input_done) frame_input_done_seen <= 1'b1;
    if (output_valid && output_ready) begin
      if (output_psum[0] !== 32'sd9 || output_lane_enable_valid !== 2'b01) begin
        $fatal(1, "1x1 psum mismatch row=%0d col=%0d got=%0d mask=%b",
          output_row, output_column, output_psum[0], output_lane_enable_valid);
      end
      case (outputs_seen)
        0: if ((output_row !== 0) || (output_column !== 0)) $fatal(1, "bad coord0 %0d %0d", output_row, output_column);
        1: if ((output_row !== 0) || (output_column !== 1)) $fatal(1, "bad coord1 %0d %0d", output_row, output_column);
        2: if ((output_row !== 1) || (output_column !== 0)) $fatal(1, "bad coord2 %0d %0d", output_row, output_column);
        3: if ((output_row !== 1) || (output_column !== 1)) $fatal(1, "bad coord3 %0d %0d", output_row, output_column);
        default: $fatal(1, "unexpected extra output");
      endcase
      outputs_seen <= outputs_seen + 1;
    end
  end

  initial begin
    pixel_data = '0;
    bias[0] = 32'sd5;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    write_weights();

    @(negedge clk);
    frame_start = 1'b1;
    @(negedge clk);
    frame_start = 1'b0;

    for (int pixel = 0; pixel < OUTPUT_COUNT; pixel++) begin
      while (!pixel_ready) @(negedge clk);
      pixel_data = '{default:8'sd1};
      pixel_valid = 1'b1;
      @(negedge clk);
      pixel_valid = 1'b0;
    end

    for (int watchdog = 0; watchdog < 200 && outputs_seen < OUTPUT_COUNT; watchdog++) begin
      @(negedge clk);
    end
    if (protocol_error || !frame_input_done_seen || outputs_seen != OUTPUT_COUNT) begin
      $fatal(1, "1x1 summary outputs=%0d done=%0b busy=%0b fault=%0b",
        outputs_seen, frame_input_done_seen, busy, protocol_error);
    end
    $display("GESTUREFLOW_CONV1X1_CIN_STREAM_PASS outputs=%0d", outputs_seen);
    $finish;
  end
endmodule
