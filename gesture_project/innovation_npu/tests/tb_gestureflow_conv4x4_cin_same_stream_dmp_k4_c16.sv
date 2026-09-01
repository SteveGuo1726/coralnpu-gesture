// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps

// Small two-group, 4x4 DMP regression.  It exercises the exact same
// IC_GROUPS=2 and KERNEL_SIZE=4 geometry used by the real body2 layer while
// keeping the reference model compact and fully exhaustive.
module tb_gestureflow_conv4x4_cin_same_stream_dmp_k4_c16;
  localparam int W = 5;
  localparam int H = 5;
  localparam int C = 16;
  localparam int OC = 4;
  localparam int K = 4;
  localparam int ACTIVE_TAPS = K * K;
  localparam int PAIRS = OC / 2;
  localparam int GROUPS = C / 8;
  localparam int ZP = -8;

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
  logic [$clog2(GROUPS)-1:0] weight_write_ic_group = '0;
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
    .IMAGE_WIDTH(W), .IMAGE_HEIGHT(H), .INPUT_CHANNELS(C), .OUT_LANES(OC), .KERNEL_SIZE(K)
  ) dut (
    .clk(clk), .rst_n(rst_n), .image_width(16'(W)), .image_height(16'(H)),
    .pointwise_mode(1'b0), .frame_start(frame_start), .pixel_valid(pixel_valid),
    .pixel_ready(pixel_ready), .pixel_data(pixel_data), .input_zero_point(input_zero_point),
    .input_group_count(5'(GROUPS)), .input_lane_enable(8'hff),
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
    return ((row * 11 + col * 7 + ch * 3 + 5) % 25) - 12;
  endfunction

  function automatic integer weight_val(input int oc, input int tap, input int ch);
    return ((oc * 7 + tap * 3 + ch * 5 + 2) % 21) - 10;
  endfunction

  function automatic integer orig_bias_val(input int oc);
    return oc * 13 - 7;
  endfunction

  task automatic load_weight(input int pair, input int tap, input int group);
    logic [7:0][23:0] wpack;
    begin
      for (int lane = 0; lane < 8; lane++) begin
        int ch = group * 8 + lane;
        integer w_even, w_odd;
        w_even = weight_val(2*pair, tap, ch) + 128;
        w_odd = weight_val(2*pair+1, tap, ch) + 128;
        wpack[lane] = {w_odd[7:0], 8'b0, w_even[7:0]};
      end
      @(negedge clk);
      weight_write_pair = pair[$clog2(PAIRS)-1:0];
      weight_write_tap = 4'(tap);
      weight_write_ic_group = group[$clog2(GROUPS)-1:0];
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
      for (int oc = 0; oc < OC; oc++) begin
        if ($signed(output_psum[oc]) !== expected[row][col][oc]) begin
          $display("FAIL row=%0d col=%0d oc=%0d expected=%0d got=%0d",
                   row, col, oc, expected[row][col][oc], $signed(output_psum[oc]));
          errors <= errors + 1;
        end
      end
      output_count <= output_count + 1;
    end
  end

  initial begin
    input_zero_point = {C{ZP[7:0]}};
    for (int row = 0; row < H; row++) begin
      for (int col = 0; col < W; col++) begin
        for (int oc = 0; oc < OC; oc++) begin
          integer sum = orig_bias_val(oc);
          for (int tap = 0; tap < ACTIVE_TAPS; tap++) begin
            int dy = tap / K;
            int dx = tap % K;
            int iy = row + dy - 1;
            int ix = col + dx - 1;
            for (int ch = 0; ch < C; ch++) begin
              integer win;
              if ((iy >= 0) && (iy < H) && (ix >= 0) && (ix < W)) begin
                win = activation_val(iy, ix, ch);
              end else begin
                win = ZP;
              end
              sum += win * weight_val(oc, tap, ch);
            end
          end
          expected[row][col][oc] = sum;
        end
      end
    end

    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    for (int pair = 0; pair < PAIRS; pair++) begin
      for (int tap = 0; tap < ACTIVE_TAPS; tap++) begin
        for (int group = 0; group < GROUPS; group++) begin
          load_weight(pair, tap, group);
        end
      end
    end
    for (int oc = 0; oc < OC; oc++) begin
      integer sum_w = 0;
      for (int tap = 0; tap < ACTIVE_TAPS; tap++) begin
        for (int ch = 0; ch < C; ch++) begin
          sum_w += weight_val(oc, tap, ch);
        end
      end
      bias[oc] = orig_bias_val(oc) - 128 * sum_w - 16384 * (ACTIVE_TAPS * C);
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
      $fatal(1, "DMP k4 c16 failed outputs=%0d done=%b fault=%b errors=%0d",
             output_count, frame_input_done_seen, protocol_error, errors);
    end
    $display("GESTUREFLOW_CONV4X4_CIN_SAME_STREAM_DMP_K4_C16_PASS outputs=%0d", output_count);
    $finish;
  end
endmodule
