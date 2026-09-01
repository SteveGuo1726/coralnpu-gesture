// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Full real second convolution regression: TFLite tensor 18 -> tensor 19.
// The test feeds every 16-channel activation pixel once and checks all 9,216
// resulting vectors through their full byte-level FNV signature and probes.
`timescale 1ns/1ps
module tb_gestureflow_conv4x4_cin_full_layer;
  `include "generated_gestureflow_real_conv4x4_body2_layer.svh"

  logic clk = 0;
  logic rst_n = 0;
  logic frame_start = 0;
  logic pixel_valid = 0;
  logic pixel_ready;
  logic signed [GF_FULL_INPUT_CHANNELS-1:0][7:0] pixel_data;
  logic signed [GF_FULL_INPUT_CHANNELS-1:0][7:0] input_zero_point;
  logic weight_write_valid = 0;
  logic weight_bank_select = 0;
  logic [$clog2(GF_FULL_LANES)-1:0] weight_write_oc;
  logic [3:0] weight_write_tap;
  logic [$clog2(GF_FULL_INPUT_CHANNELS/4)-1:0] weight_write_ic_group;
  logic signed [3:0][7:0] weight_write_data;
  logic signed [GF_FULL_LANES-1:0][31:0] bias;
  logic [GF_FULL_LANES-1:0] output_lane_enable = '1;
  logic raw_valid;
  logic raw_ready;
  logic signed [GF_FULL_LANES-1:0][31:0] raw_psum;
  logic [GF_FULL_LANES-1:0] raw_mask;
  logic [15:0] raw_row;
  logic [15:0] raw_column;
  logic raw_busy;
  logic raw_fault;
  logic frame_input_done;
  logic requant_enable = 1;
  logic requant_relu_enable = 1;
  logic signed [7:0] output_zero_point = -8'sd128;
  logic signed [GF_FULL_LANES-1:0][31:0] requant_multiplier;
  logic [GF_FULL_LANES-1:0][5:0] requant_right_shift;
  logic quant_valid;
  logic quant_ready = 1;
  logic signed [GF_FULL_LANES-1:0][7:0] quant_data;
  logic [GF_FULL_LANES-1:0] quant_mask;
  logic quant_fault;
  logic [15:0] quant_row;
  logic [15:0] quant_column;
  integer output_count = 0;
  integer probe_hits = 0;
  integer unsigned output_hash = 32'h811c9dc5;
  logic frame_input_done_seen = 0;
  integer cycle_count = 0;
  integer frame_start_cycle = -1;
  integer final_output_cycle = -1;

  gestureflow_conv4x4_cin_same_stream #(
    .IMAGE_WIDTH(GF_FULL_WIDTH), .IMAGE_HEIGHT(GF_FULL_HEIGHT),
    .INPUT_CHANNELS(GF_FULL_INPUT_CHANNELS), .OUT_LANES(GF_FULL_LANES)
  ) stream (
    .clk(clk), .rst_n(rst_n),
    .image_width(16'(GF_FULL_WIDTH)), .image_height(16'(GF_FULL_HEIGHT)),
    .pointwise_mode(1'b0),
    .frame_start(frame_start),
    .pixel_valid(pixel_valid), .pixel_ready(pixel_ready), .pixel_data(pixel_data),
    .input_zero_point(input_zero_point), .input_group_count(5'd4), .input_lane_enable(4'hf), .weight_write_valid(weight_write_valid),
    .weight_write_oc(weight_write_oc), .weight_write_tap(weight_write_tap),
    .weight_write_ic_group(weight_write_ic_group), .weight_write_data(weight_write_data), .weight_bank_select(weight_bank_select),
    .bias(bias), .output_lane_enable(output_lane_enable), .output_valid(raw_valid),
    .output_ready(raw_ready), .output_psum(raw_psum), .output_lane_enable_valid(raw_mask),
    .output_row(raw_row), .output_column(raw_column), .busy(raw_busy),
    .protocol_error(raw_fault), .frame_input_done(frame_input_done)
  );

  gestureflow_requant_relu #(.LANES(GF_FULL_LANES)) requant (
    .clk(clk), .rst_n(rst_n), .in_valid(raw_valid), .in_ready(raw_ready),
    .in_psum(raw_psum), .in_lane_enable(raw_mask), .enable(requant_enable),
    .relu_enable(requant_relu_enable), .output_zero_point(output_zero_point),
    .multiplier(requant_multiplier), .right_shift(requant_right_shift),
    .out_valid(quant_valid), .out_ready(quant_ready), .out_data(quant_data),
    .out_lane_enable(quant_mask), .config_error(quant_fault)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    cycle_count = cycle_count + 1;
    if (frame_start) frame_start_cycle = cycle_count;
    if (frame_input_done) frame_input_done_seen = 1;
    if (raw_valid && raw_ready) begin
      quant_row <= raw_row;
      quant_column <= raw_column;
    end
    if (quant_valid && quant_ready) begin
      int row;
      int column;
      output_count = output_count + 1;
      final_output_cycle = cycle_count;
      row = int'(quant_row);
      column = int'(quant_column);
      for (int lane = 0; lane < GF_FULL_LANES; lane++) begin
        output_hash = (output_hash ^ {24'd0, quant_data[lane]}) * 32'h01000193;
      end
      for (int probe = 0; probe < GF_FULL_PROBE_COUNT; probe++) begin
        if ((row == int'(gf_full_probe_y[probe])) && (column == int'(gf_full_probe_x[probe]))) begin
          for (int lane = 0; lane < GF_FULL_LANES; lane++) begin
            if ($signed(quant_data[lane]) !== gf_full_probe_quant[probe][lane]) begin
              $fatal(1, "Second-layer probe mismatch y=%0d x=%0d lane=%0d got=%0d expected=%0d",
                row, column, lane, $signed(quant_data[lane]), gf_full_probe_quant[probe][lane]);
            end
          end
          probe_hits = probe_hits + 1;
        end
      end
    end
  end

  initial begin
    pixel_data = '0;
    input_zero_point = {GF_FULL_INPUT_CHANNELS{-8'sd128}};
    weight_write_oc = '0;
    weight_write_tap = '0;
    weight_write_ic_group = '0;
    weight_write_data = '0;
    bias = '0;
    requant_multiplier = '0;
    requant_right_shift = '0;
    quant_row = '0;
    quant_column = '0;
    for (int lane = 0; lane < GF_FULL_LANES; lane++) begin
      bias[lane] = gf_full_folded_bias[lane];
      requant_multiplier[lane] = gf_full_multiplier[lane];
      requant_right_shift[lane] = gf_full_right_shift[lane];
    end
    repeat (3) @(negedge clk);
    rst_n = 1;

    // Weight banks are loaded once per layer. The MAC issue loop below has no
    // software interaction while it traverses 16 taps x four C-in groups.
    for (int oc = 0; oc < GF_FULL_LANES; oc++) begin
      for (int tap = 0; tap < 16; tap++) begin
        for (int group = 0; group < GF_FULL_INPUT_CHANNELS / 4; group++) begin
          @(negedge clk);
          weight_write_valid = 1;
          weight_write_oc = $clog2(GF_FULL_LANES)'(oc);
          weight_write_tap = 4'(tap);
          weight_write_ic_group = $clog2(GF_FULL_INPUT_CHANNELS/4)'(group);
          for (int lane = 0; lane < 4; lane++) begin
            weight_write_data[lane] = gf_full_weights[
              (oc * 16 * GF_FULL_INPUT_CHANNELS) + (tap * GF_FULL_INPUT_CHANNELS) + (group * 4) + lane
            ];
          end
          @(negedge clk);
          weight_write_valid = 0;
        end
      end
    end

    @(negedge clk);
    frame_start = 1;
    @(negedge clk);
    frame_start = 0;
    for (int row = 0; row < GF_FULL_HEIGHT; row++) begin
      for (int column = 0; column < GF_FULL_WIDTH; column++) begin
        while (!pixel_ready) @(negedge clk);
        for (int channel = 0; channel < GF_FULL_INPUT_CHANNELS; channel++) begin
          pixel_data[channel] = gf_full_input_q[
            ((row * GF_FULL_WIDTH + column) * GF_FULL_INPUT_CHANNELS) + channel
          ];
        end
        pixel_valid = 1;
        @(negedge clk);
        pixel_valid = 0;
      end
    end

    for (int watchdog = 0; watchdog < 1200000 && output_count < GF_FULL_WIDTH * GF_FULL_HEIGHT; watchdog++) begin
      @(negedge clk);
    end
    @(negedge clk);
    if (raw_fault || quant_fault || !frame_input_done_seen || probe_hits != GF_FULL_PROBE_COUNT ||
        output_count != GF_FULL_WIDTH * GF_FULL_HEIGHT || output_hash != GF_FULL_QUANT_FNV1A) begin
      $fatal(1, "Second full layer failed outputs=%0d probes=%0d done=%b raw_fault=%b quant_fault=%b hash=%08x expected=%08x",
        output_count, probe_hits, frame_input_done_seen, raw_fault, quant_fault, output_hash, GF_FULL_QUANT_FNV1A);
    end
    $display("GESTUREFLOW_CONV4X4_CIN_FULL_LAYER_PASS outputs=%0d probes=%0d quant_fnv1a=%08x",
      output_count, probe_hits, output_hash);
    $display("GESTUREFLOW_CONV4X4_CIN_FULL_LAYER_CYCLES=%0d", final_output_cycle - frame_start_cycle + 1);
    $finish;
  end
endmodule
