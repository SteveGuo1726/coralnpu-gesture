// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Full 96x96 first-layer regression against a real project TFLite tensor.
`timescale 1ns/1ps
module tb_gestureflow_conv4x4_rgb_full_layer;
  `include "generated_gestureflow_real_conv4x4_full_layer.svh"

  logic clk = 0, rst_n = 0, frame_start = 0, pixel_valid = 0, pixel_ready;
  logic signed [2:0][7:0] pixel_rgb, input_zero_point;
  logic weight_write_valid = 0;
  logic [3:0] weight_write_oc;
  logic [3:0] weight_write_tap;
  logic signed [3:0][7:0] weight_write_data;
  logic signed [15:0][31:0] bias;
  logic [15:0] output_lane_enable = 16'hffff;
  logic frame_input_done, layer_fault;
  logic requant_enable = 1, requant_relu_enable = 1;
  logic signed [7:0] output_zero_point = -8'sd128;
  logic signed [15:0][31:0] requant_multiplier;
  logic [15:0][5:0] requant_right_shift;
  logic output_write_valid;
  logic [13:0] output_write_addr;
  logic signed [15:0][7:0] output_write_data;
  logic output_read_enable = 0;
  logic [13:0] output_read_addr = 0;
  logic [127:0] output_read_data;
  integer output_count = 0;
  integer probe_hits = 0;
  integer unsigned output_hash = 32'h811c9dc5;
  logic frame_input_done_seen = 0;
  integer cycle_count = 0;
  integer frame_start_cycle = -1;
  integer final_output_cycle = -1;

  gestureflow_conv4x4_rgb_same_layer #(
    .IMAGE_WIDTH(GF_FULL_WIDTH), .IMAGE_HEIGHT(GF_FULL_HEIGHT),
    .OUT_LANES(GF_FULL_LANES), .OUTPUT_ADDR_W(14)
  ) dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk) begin
    cycle_count = cycle_count + 1;
    if (frame_start) frame_start_cycle = cycle_count;
    if (frame_input_done) frame_input_done_seen = 1;
    if (output_write_valid) begin
      int row;
      int column;
      output_count = output_count + 1;
      final_output_cycle = cycle_count;
      row = int'(output_write_addr) / GF_FULL_WIDTH;
      column = int'(output_write_addr) % GF_FULL_WIDTH;
      for (int lane = 0; lane < GF_FULL_LANES; lane++) begin
        output_hash = (output_hash ^ {24'd0, output_write_data[lane]}) * 32'h01000193;
      end
      for (int probe = 0; probe < GF_FULL_PROBE_COUNT; probe++) begin
        if ((row == int'(gf_full_probe_y[probe])) && (column == int'(gf_full_probe_x[probe]))) begin
          for (int lane = 0; lane < GF_FULL_LANES; lane++) begin
            if ($signed(output_write_data[lane]) !== gf_full_probe_quant[probe][lane]) begin
              $fatal(1, "TFLite probe mismatch y=%0d x=%0d lane=%0d got=%0d expected=%0d",
                row, column, lane, $signed(output_write_data[lane]),
                gf_full_probe_quant[probe][lane]);
            end
          end
          probe_hits = probe_hits + 1;
        end
      end
    end
  end

  initial begin
    pixel_rgb = '0;
    input_zero_point = {3{-8'sd128}};
    weight_write_oc = '0;
    weight_write_tap = '0;
    weight_write_data = '0;
    bias = '0;
    requant_multiplier = '0;
    requant_right_shift = '0;
    for (int lane = 0; lane < GF_FULL_LANES; lane++) begin
      bias[lane] = gf_full_folded_bias[lane];
      requant_multiplier[lane] = gf_full_multiplier[lane];
      requant_right_shift[lane] = gf_full_right_shift[lane];
    end
    repeat (3) @(negedge clk);
    rst_n = 1;

    // One physical BRAM write per output-channel/tap. Weights remain local
    // through the complete frame; no per-window software transaction exists.
    for (int oc = 0; oc < GF_FULL_LANES; oc++) begin
      for (int tap = 0; tap < 16; tap++) begin
        @(negedge clk);
        weight_write_valid = 1;
        weight_write_oc = 4'(oc);
        weight_write_tap = 4'(tap);
        for (int channel = 0; channel < 3; channel++) begin
          weight_write_data[channel] = gf_full_weights[(oc * 48) + (tap * 3) + channel];
        end
        weight_write_data[3] = 0;
        @(negedge clk);
        weight_write_valid = 0;
      end
    end

    @(negedge clk);
    frame_start = 1;
    @(negedge clk);
    frame_start = 0;
    for (int row = 0; row < GF_FULL_HEIGHT; row++) begin
      for (int column = 0; column < GF_FULL_WIDTH; column++) begin
        while (!pixel_ready) @(negedge clk);
        for (int channel = 0; channel < 3; channel++) begin
          pixel_rgb[channel] = gf_full_input_q[((row * GF_FULL_WIDTH + column) * 3) + channel];
        end
        pixel_valid = 1;
        @(negedge clk);
        pixel_valid = 0;
      end
    end

    for (int watchdog = 0; watchdog < 300000 && output_count < GF_FULL_WIDTH * GF_FULL_HEIGHT; watchdog++) begin
      @(negedge clk);
    end
    @(negedge clk);
    if (layer_fault || !frame_input_done_seen || probe_hits != GF_FULL_PROBE_COUNT ||
        output_count != GF_FULL_WIDTH * GF_FULL_HEIGHT || output_hash != GF_FULL_QUANT_FNV1A) begin
      $fatal(1, "Full layer failed outputs=%0d probes=%0d done=%b fault=%b hash=%08x expected=%08x",
        output_count, probe_hits, frame_input_done_seen, layer_fault, output_hash, GF_FULL_QUANT_FNV1A);
    end
    $display("GESTUREFLOW_CONV4X4_RGB_FULL_LAYER_PASS outputs=%0d probes=%0d quant_fnv1a=%08x",
      output_count, probe_hits, output_hash);
    $display("GESTUREFLOW_CONV4X4_RGB_FULL_LAYER_CYCLES=%0d",
      final_output_cycle - frame_start_cycle + 1);
    $finish;
  end
endmodule
