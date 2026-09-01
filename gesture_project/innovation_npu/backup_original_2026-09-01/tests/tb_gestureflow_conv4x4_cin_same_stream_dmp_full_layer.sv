// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps

// Full real DMP layer regression: TFLite tensor 16x96x96 -> 16x96x96.  It
// feeds the complete real input tensor, loads DMP-packed weights from the
// generated golden, and checks every raw INT32 vector through a byte-level
// FNV plus seven probe vectors.
module tb_gestureflow_conv4x4_cin_same_stream_dmp_full_layer;
  `include "generated_gestureflow_dmp_body2_golden.svh"

  localparam int W = GF_DMP_BODY2_WIDTH;
  localparam int H = GF_DMP_BODY2_HEIGHT;
  localparam int C = GF_DMP_BODY2_INPUT_CHANNELS;
  localparam int OC = GF_DMP_BODY2_OUTPUT_LANES;
  localparam int PAIRS = OC / 2;
  localparam int GROUPS = GF_DMP_BODY2_INPUT_GROUPS;
  localparam int WORDS_PER_ENTRY = 6;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic frame_start = 1'b0;
  logic pixel_valid = 1'b0;
  logic pixel_ready;
  logic signed [C-1:0][7:0] pixel_data = '0;
  logic signed [C-1:0][7:0] input_zero_point = '0;
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

  integer output_count = 0;
  integer probe_hits = 0;
  integer unsigned output_hash = 32'h811C9DC5;
  logic frame_input_done_seen = 1'b0;
  integer cycle_count = 0;
  integer frame_start_cycle = -1;
  integer final_output_cycle = -1;

  gestureflow_conv4x4_cin_same_stream_dmp #(
    .IMAGE_WIDTH(W), .IMAGE_HEIGHT(H),
    .INPUT_CHANNELS(C), .OUT_LANES(OC), .KERNEL_SIZE(4)
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

  always @(posedge clk) begin
    cycle_count = cycle_count + 1;
    if (frame_start) frame_start_cycle = cycle_count;
    if (frame_input_done) frame_input_done_seen = 1'b1;
    if (output_valid && output_ready) begin
      int row = int'(output_row);
      int col = int'(output_column);
      final_output_cycle = cycle_count;
      output_count = output_count + 1;
      for (int lane = 0; lane < OC; lane++) begin
        for (int bindex = 0; bindex < 4; bindex++) begin
          output_hash = (output_hash ^ {24'd0, output_psum[lane][bindex*8 +: 8]}) * 32'h01000193;
        end
      end
      for (int probe = 0; probe < GF_DMP_BODY2_PROBE_COUNT; probe++) begin
        if ((row == int'(gf_dmp_body2_probe_y[probe])) &&
            (col == int'(gf_dmp_body2_probe_x[probe]))) begin
          for (int lane = 0; lane < OC; lane++) begin
            if (output_psum[lane] !== gf_dmp_body2_probe_raw[probe][lane]) begin
              $fatal(1, "DMP layer probe mismatch y=%0d x=%0d lane=%0d got=%0d expected=%0d",
                     row, col, lane, output_psum[lane], gf_dmp_body2_probe_raw[probe][lane]);
            end
          end
          probe_hits = probe_hits + 1;
        end
      end
    end
  end

  task automatic load_weight_entry(input int pair, input int tap, input int group);
    logic [8*24-1:0] wdata;
    begin
      for (int word = 0; word < WORDS_PER_ENTRY; word++) begin
        int base = (((pair * 16) + tap) * GROUPS + group) * WORDS_PER_ENTRY + word;
        wdata[word*32 +: 32] = gf_dmp_body2_weights_dma[base];
      end
      @(negedge clk);
      weight_write_pair = pair[$clog2(PAIRS)-1:0];
      weight_write_tap = 4'(tap);
      weight_write_ic_group = group[$clog2(GROUPS)-1:0];
      weight_write_data = wdata;
      weight_write_valid = 1'b1;
      @(negedge clk);
      weight_write_valid = 1'b0;
    end
  endtask

  initial begin
    for (int ch = 0; ch < C; ch++) begin
      input_zero_point[ch] = GF_DMP_BODY2_INPUT_ZERO_POINT[7:0];
    end
    for (int lane = 0; lane < OC; lane++) begin
      bias[lane] = gf_dmp_body2_folded_bias[lane];
    end
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int pair = 0; pair < PAIRS; pair++) begin
      for (int tap = 0; tap < 16; tap++) begin
        for (int group = 0; group < GROUPS; group++) begin
          load_weight_entry(pair, tap, group);
        end
      end
    end

    @(negedge clk);
    frame_start = 1'b1;
    @(negedge clk);
    frame_start = 1'b0;
    for (int row = 0; row < H; row++) begin
      for (int col = 0; col < W; col++) begin
        while (!pixel_ready) @(negedge clk);
        for (int ch = 0; ch < C; ch++) begin
          pixel_data[ch] = gf_dmp_body2_input_q[((row * W) + col) * C + ch];
        end
        pixel_valid = 1'b1;
        @(negedge clk);
        pixel_valid = 1'b0;
      end
    end

    for (int watchdog = 0; watchdog < 1500000 && output_count < H*W; watchdog++) begin
      @(negedge clk);
    end
    @(negedge clk);
    if (protocol_error || !frame_input_done_seen || probe_hits != GF_DMP_BODY2_PROBE_COUNT ||
        output_count != H*W || output_hash != GF_DMP_BODY2_RAW_FNV1A) begin
      $fatal(1, "DMP full layer failed outputs=%0d probes=%0d done=%b fault=%b hash=%08x expected=%08x",
             output_count, probe_hits, frame_input_done_seen, protocol_error,
             output_hash, GF_DMP_BODY2_RAW_FNV1A);
    end
    $display("GESTUREFLOW_CONV4X4_CIN_SAME_STREAM_DMP_FULL_LAYER_PASS outputs=%0d probes=%0d raw_fnv1a=%08x",
             output_count, probe_hits, output_hash);
    $display("GESTUREFLOW_CONV4X4_CIN_SAME_STREAM_DMP_FULL_LAYER_CYCLES=%0d",
             final_output_cycle - frame_start_cycle + 1);
    $finish;
  end
endmodule
