// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps

// Pointwise (1x1) counterpart of the DMP streaming-convolution regression.
// The same 8-lane engine is put into pointwise_mode; its MAC backend uses
// only tap 0 while walking one eight-channel input group.  Every output
// pixel/vector is compared with a 64-bit naive signed reference.
module tb_gestureflow_conv4x4_cin_same_stream_dmp_pointwise;
  localparam int W = 4;
  localparam int H = 4;
  localparam int C = 8;
  localparam int OC = 4;
  localparam int PAIRS = OC / 2;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic frame_start = 1'b0;
  logic pixel_valid = 1'b0;
  logic pixel_ready;
  logic signed [C-1:0][7:0] pixel_data = '0;
  logic signed [C-1:0][7:0] input_zero_point;
  logic weight_write_valid = 1'b0;
  logic weight_bank_select = 1'b0;
  logic read_bank_select = 1'b0;
  logic [$clog2(PAIRS)-1:0] weight_write_pair = '0;
  logic [3:0] weight_write_tap = '0;
  logic weight_write_ic_group = 1'b0;
  logic [8*24-1:0] weight_write_data = '0;
  logic signed [OC-1:0][31:0] bias = '0;
  logic [OC-1:0] output_lane_enable = '1;
  logic output_valid;
  logic output_ready = 1'b1;
  logic signed [OC-1:0][31:0] output_psum;
  logic [OC-1:0] output_lane_enable_valid;
  logic [15:0] output_row;
  logic [15:0] output_column;
  logic busy;
  logic protocol_error;
  logic frame_input_done;

  integer expected [0:H-1][0:W-1][0:OC-1];
  integer output_count = 0;
  int errors = 0;
  logic frame_input_done_seen = 1'b0;

  gestureflow_conv4x4_cin_same_stream_dmp #(
    .IMAGE_WIDTH(W), .IMAGE_HEIGHT(H),
    .INPUT_CHANNELS(C), .OUT_LANES(OC), .KERNEL_SIZE(4)
  ) dut (
    .clk(clk), .rst_n(rst_n), .image_width(16'(W)), .image_height(16'(H)),
    .pointwise_mode(1'b1), .frame_start(frame_start), .pixel_valid(pixel_valid),
    .pixel_ready(pixel_ready), .pixel_data(pixel_data), .input_zero_point(input_zero_point),
    .input_group_count(5'd1), .input_lane_enable(8'hff),
    .weight_write_valid(weight_write_valid), .weight_write_pair(weight_write_pair),
    .weight_write_tap(weight_write_tap), .weight_write_ic_group(weight_write_ic_group),
    .weight_write_data(weight_write_data), .weight_bank_select(weight_bank_select),
    .read_bank_select(read_bank_select), .bias(bias), .output_lane_enable(output_lane_enable),
    .output_valid(output_valid), .output_ready(output_ready), .output_psum(output_psum),
    .output_lane_enable_valid(output_lane_enable_valid), .output_row(output_row),
    .output_column(output_column), .busy(busy), .protocol_error(protocol_error),
    .frame_input_done(frame_input_done)
  );

  always #5 clk = ~clk;

  function automatic integer activation_val(input int row, input int col, input int ch);
    return ((row * 13 + col * 9 + ch * 5 + 7) % 29) - 14;
  endfunction

  function automatic integer weight_val(input int oc, input int ch);
    return ((oc * 11 + ch * 7 + 4) % 19) - 9;
  endfunction

  function automatic integer orig_bias_val(input int oc);
    return oc * 9 - 3;
  endfunction

  task automatic load_weight(input int pair);
    logic [7:0][23:0] wpack;
    begin
      for (int ch = 0; ch < 8; ch++) begin
        integer w_even, w_odd;
        w_even = weight_val(2*pair, ch) + 128;
        w_odd = weight_val(2*pair+1, ch) + 128;
        wpack[ch] = {w_odd[7:0], 8'b0, w_even[7:0]};
      end
      @(negedge clk);
      weight_write_pair = pair[$clog2(PAIRS)-1:0];
      weight_write_tap = 4'd0;
      weight_write_ic_group = 1'b0;
      weight_write_data = wpack;
      weight_write_valid = 1'b1;
      @(negedge clk);
      weight_write_valid = 1'b0;
    end
  endtask

  always @(posedge clk) begin
    if (frame_input_done) frame_input_done_seen <= 1'b1;
    if (output_valid && output_ready) begin
      int row = int'(output_row);
      int col = int'(output_column);
      if ((row < 0) || (row >= H) || (col < 0) || (col >= W)) begin
        $display("FAIL output coordinate row=%0d col=%0d", row, col);
        errors <= errors + 1;
      end else begin
        for (int oc = 0; oc < OC; oc++) begin
          if ($signed(output_psum[oc]) !== expected[row][col][oc]) begin
            $display("FAIL row=%0d col=%0d oc=%0d expected=%0d got=%0d",
                     row, col, oc, expected[row][col][oc], $signed(output_psum[oc]));
            errors <= errors + 1;
          end
        end
      end
      output_count <= output_count + 1;
    end
  end

  initial begin
    input_zero_point = {C{-8'sd8}};
    for (int row = 0; row < H; row++) begin
      for (int col = 0; col < W; col++) begin
        for (int oc = 0; oc < OC; oc++) begin
          integer sum = orig_bias_val(oc);
          for (int ch = 0; ch < C; ch++) begin
            sum += activation_val(row, col, ch) * weight_val(oc, ch);
          end
          expected[row][col][oc] = sum;
        end
      end
    end

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int pair = 0; pair < PAIRS; pair++) begin
      load_weight(pair);
    end

    for (int oc = 0; oc < OC; oc++) begin
      integer sum_w = 0;
      for (int ch = 0; ch < C; ch++) begin
        sum_w += weight_val(oc, ch);
      end
      bias[oc] = orig_bias_val(oc) - 128 * sum_w - 16384 * C;
    end

    @(negedge clk);
    frame_start = 1'b1;
    @(negedge clk);
    frame_start = 1'b0;
    for (int row = 0; row < H; row++) begin
      for (int col = 0; col < W; col++) begin
        while (!pixel_ready) @(negedge clk);
        for (int ch = 0; ch < C; ch++) begin
          integer a;
          a = activation_val(row, col, ch);
          pixel_data[ch] = a[7:0];
        end
        pixel_valid = 1'b1;
        @(negedge clk);
        pixel_valid = 1'b0;
      end
    end

    for (int watchdog = 0; watchdog < 50000 && output_count < H*W; watchdog++) begin
      @(negedge clk);
    end
    @(negedge clk);
    if ((output_count != H*W) || !frame_input_done_seen || protocol_error || errors != 0) begin
      $fatal(1, "DMP pointwise failed outputs=%0d done=%b fault=%b errors=%0d",
             output_count, frame_input_done_seen, protocol_error, errors);
    end
    $display("GESTUREFLOW_CONV4X4_CIN_SAME_STREAM_DMP_POINTWISE_PASS outputs=%0d", output_count);
    $finish;
  end
endmodule
