// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Full on-chip head_1x1 -> GAP -> FC tail regression. Seven 16-lane head tiles
// are produced by conv1x1_cin_stream, requantized, GAP-accumulated tile by tile
// into 112 values, and finally classified by the reusable FC classifier. No
// 12x12x112 intermediate tensor is ever written to DDR. The expected result is
// the deployed-model golden: fc=0xDDE32561, class=0.
`timescale 1ns/1ps
module tb_gestureflow_head1x1_gap_fc_real;
  `include "generated_gestureflow_real_conv4x4_head1x1_layer.svh"

  localparam int GF_TILE_LANES = 16;
  localparam int GF_HEAD1X1_EMBEDDED_CENTER_TAP = 5;
  localparam int GF_TILES = GF_HEAD1X1_LANES / GF_TILE_LANES; // 7
  localparam int GF_GAP_PIXELS = GF_HEAD1X1_WIDTH * GF_HEAD1X1_HEIGHT; // 144
  localparam int GF_GAP_LANES = GF_HEAD1X1_LANES; // 112

  logic clk = 0, rst_n = 0;
  logic frame_start = 0;
  logic pixel_valid = 0;
  logic pixel_ready;
  logic signed [GF_HEAD1X1_INPUT_CHANNELS-1:0][7:0] pixel_data;
  logic weight_write_valid = 0;
  logic weight_bank_select = 0;
  logic read_bank_select = 0;
  logic [$clog2(GF_TILE_LANES)-1:0] weight_write_oc = '0;
  logic [3:0] weight_write_tap = '0;
  logic [$clog2(GF_HEAD1X1_INPUT_CHANNELS/4)-1:0] weight_write_ic_group = '0;
  logic signed [3:0][7:0] weight_write_data = '0;
  logic signed [GF_TILE_LANES-1:0][31:0] bias = '0;
  logic [GF_TILE_LANES-1:0] output_lane_enable = '1;
  logic raw_valid, raw_ready;
  logic signed [GF_TILE_LANES-1:0][31:0] raw_psum;
  logic [GF_TILE_LANES-1:0] raw_mask;
  logic [15:0] raw_row, raw_column;
  logic raw_busy, raw_fault;
  logic frame_input_done;
  logic requant_enable = 1, requant_relu_enable = 1;
  logic signed [7:0] output_zero_point = -8'sd128;
  logic signed [GF_TILE_LANES-1:0][31:0] requant_multiplier = '0;
  logic [GF_TILE_LANES-1:0][5:0] requant_right_shift = '0;
  logic quant_valid, quant_ready = 1, quant_fault;
  logic signed [GF_TILE_LANES-1:0][7:0] quant_data;
  logic [GF_TILE_LANES-1:0] quant_mask;
  logic [15:0] quant_row, quant_column;

  logic gap_start = 0, gap_clear = 0;
  logic [13:0] gap_pixel_count = 14'(GF_GAP_PIXELS);
  logic gap_pixel_valid, gap_pixel_ready;
  logic signed [GF_TILE_LANES-1:0][7:0] gap_pixel_data;
  logic gap_valid;
  logic signed [GF_TILE_LANES-1:0][7:0] gap_data;
  logic [13:0] gap_pixels_seen;
  logic gap_busy, gap_done, gap_fault;

  logic fc_start = 0, fc_clear = 0;
  logic gap_write_valid = 0;
  logic [$clog2(GF_GAP_LANES)-1:0] gap_write_index = '0;
  logic signed [7:0] gap_write_data = '0;
  logic fc_weight_write_valid = 0;
  logic [2:0] fc_weight_write_class = '0;
  logic [$clog2(GF_GAP_LANES/4)-1:0] fc_weight_write_group = '0;
  logic signed [3:0][7:0] fc_weight_write_data = '0;
  logic signed [5:0][31:0] fc_bias, fc_multiplier;
  logic [5:0][5:0] fc_right_shift;
  logic signed [7:0] fc_output_zero_point = -8'sd6;
  logic fc_busy, fc_done, fc_fault;
  logic [31:0] fc_fnv1a;
  logic [2:0] fc_predicted_class, fc_values_done;
  logic signed [5:0][7:0] fc_value;

  logic [7:0] fc_memory [0:671];

  gestureflow_conv1x1_cin_stream #(
    .IMAGE_WIDTH(GF_HEAD1X1_WIDTH), .IMAGE_HEIGHT(GF_HEAD1X1_HEIGHT),
    .INPUT_CHANNELS(GF_HEAD1X1_INPUT_CHANNELS), .OUT_LANES(GF_TILE_LANES)
  ) stream (
    .clk(clk), .rst_n(rst_n),
    .image_width(16'(GF_HEAD1X1_WIDTH)), .image_height(16'(GF_HEAD1X1_HEIGHT)),
    .frame_start(frame_start), .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
    .pixel_data(pixel_data), .input_group_count(5'd12), .input_lane_enable(4'hf),
    .weight_write_valid(weight_write_valid), .weight_write_oc(weight_write_oc),
    .weight_write_tap(weight_write_tap), .weight_write_ic_group(weight_write_ic_group),
    .weight_write_data(weight_write_data), .weight_bank_select(weight_bank_select), .read_bank_select(read_bank_select),
    .bias(bias), .output_lane_enable(output_lane_enable), .output_valid(raw_valid),
    .output_ready(raw_ready), .output_psum(raw_psum), .output_lane_enable_valid(raw_mask),
    .output_row(raw_row), .output_column(raw_column), .busy(raw_busy),
    .protocol_error(raw_fault), .frame_input_done(frame_input_done)
  );

  gestureflow_requant_relu #(.LANES(GF_TILE_LANES)) requant (
    .clk(clk), .rst_n(rst_n), .in_valid(raw_valid), .in_ready(raw_ready),
    .in_psum(raw_psum), .in_lane_enable(raw_mask), .enable(requant_enable),
    .relu_enable(requant_relu_enable), .output_zero_point(output_zero_point),
    .multiplier(requant_multiplier), .right_shift(requant_right_shift),
    .out_valid(quant_valid), .out_ready(quant_ready), .out_data(quant_data),
    .out_lane_enable(quant_mask), .config_error(quant_fault)
  );

  gestureflow_head_tile_gap_accumulator #(.LANES(GF_TILE_LANES), .PIXEL_COUNT_W(14)) gap (
    .clk(clk), .rst_n(rst_n), .start(gap_start), .clear(gap_clear),
    .pixel_count(gap_pixel_count), .gap_multiplier(32'sd1161448398),
    .gap_right_shift(6'd1), .gap_input_zero_point(-8'sd128),
    .gap_output_zero_point(-8'sd128), .pixel_data(gap_pixel_data),
    .pixel_valid(gap_pixel_valid), .pixel_ready(gap_pixel_ready), .gap_valid(gap_valid),
    .gap_data(gap_data), .pixels_seen(gap_pixels_seen), .busy(gap_busy),
    .done(gap_done), .fault(gap_fault)
  );

  gestureflow_fc_classifier #(.GAP_LANES(GF_GAP_LANES), .CLASSES(6), .FC_GROUPS(GF_GAP_LANES/4)) fc (
    .clk(clk), .rst_n(rst_n), .start(fc_start), .clear(fc_clear),
    .gap_write_valid(gap_write_valid), .gap_write_index(gap_write_index), .gap_write_data(gap_write_data),
    .fc_weight_write_valid(fc_weight_write_valid), .fc_weight_write_class(fc_weight_write_class),
    .fc_weight_write_group(fc_weight_write_group), .fc_weight_write_data(fc_weight_write_data),
    .fc_bias(fc_bias), .fc_multiplier(fc_multiplier), .fc_right_shift(fc_right_shift),
    .fc_output_zero_point(fc_output_zero_point), .busy(fc_busy), .done(fc_done), .fault(fc_fault),
    .fc_fnv1a(fc_fnv1a), .predicted_class(fc_predicted_class), .fc_value(fc_value), .fc_values_done(fc_values_done)
  );

  assign gap_pixel_data = quant_data;
  assign gap_pixel_valid = quant_valid;
  assign quant_ready = gap_pixel_ready;

  always #5 clk = ~clk;

  task automatic load_head_tile_weights(input int tile);
    begin
      for (int oc = 0; oc < GF_TILE_LANES; oc++) begin
        for (int group = 0; group < GF_HEAD1X1_INPUT_CHANNELS / 4; group++) begin
          @(negedge clk);
          weight_write_valid = 1'b1;
          weight_write_oc = $clog2(GF_TILE_LANES)'(oc);
          weight_write_tap = '0;
          weight_write_ic_group = $clog2(GF_HEAD1X1_INPUT_CHANNELS/4)'(group);
          for (int lane = 0; lane < 4; lane++) begin
            weight_write_data[lane] = gf_head1x1_weights[
              ((tile * GF_TILE_LANES + oc) * 16 * GF_HEAD1X1_INPUT_CHANNELS) +
              (GF_HEAD1X1_EMBEDDED_CENTER_TAP * GF_HEAD1X1_INPUT_CHANNELS) +
              (group * 4) + lane
            ];
          end
          @(negedge clk);
          weight_write_valid = 1'b0;
        end
      end
    end
  endtask

  task automatic load_head_tile_params(input int tile);
    begin
      for (int lane = 0; lane < GF_TILE_LANES; lane++) begin
        bias[lane] = gf_head1x1_folded_bias[tile * GF_TILE_LANES + lane];
        requant_multiplier[lane] = gf_head1x1_multiplier[tile * GF_TILE_LANES + lane];
        requant_right_shift[lane] = gf_head1x1_right_shift[tile * GF_TILE_LANES + lane];
      end
    end
  endtask

  task automatic feed_frame();
    begin
      @(negedge clk);
      frame_start = 1'b1;
      @(negedge clk);
      frame_start = 1'b0;
      for (int row = 0; row < GF_HEAD1X1_HEIGHT; row++) begin
        for (int column = 0; column < GF_HEAD1X1_WIDTH; column++) begin
          while (!pixel_ready) @(negedge clk);
          for (int channel = 0; channel < GF_HEAD1X1_INPUT_CHANNELS; channel++) begin
            pixel_data[channel] = gf_head1x1_input_q[
              ((row * GF_HEAD1X1_WIDTH + column) * GF_HEAD1X1_INPUT_CHANNELS) + channel
            ];
          end
          pixel_valid = 1'b1;
          @(negedge clk);
          pixel_valid = 1'b0;
        end
      end
    end
  endtask

  task automatic capture_tile_gap(input int tile);
    begin
      wait (gap_done);
      repeat (2) @(posedge clk);
      if (gap_fault) $fatal(1, "head tile %0d GAP fault", tile);
      if (!gap_valid) $fatal(1, "head tile %0d GAP did not emit", tile);
      for (int lane = 0; lane < GF_TILE_LANES; lane++) begin
        @(negedge clk);
        gap_write_valid = 1'b1;
        gap_write_index = 6'(tile * GF_TILE_LANES + lane);
        gap_write_data = gap_data[lane];
      end
      @(negedge clk);
      gap_write_valid = 1'b0;
    end
  endtask

  initial begin
    string fc_path;
    if (!$value$plusargs("FC_MEM=%s", fc_path)) $fatal(1, "FC_MEM is required");
    $readmemh(fc_path, fc_memory);

    pixel_data = '0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int tile = 0; tile < GF_TILES; tile++) begin
      load_head_tile_params(tile);
      load_head_tile_weights(tile);

      @(negedge clk);
      gap_start = 1'b1;
      @(negedge clk);
      gap_start = 1'b0;

      feed_frame();
      capture_tile_gap(tile);
    end

    fc_bias[0] = -57642; fc_bias[1] = -120742; fc_bias[2] = -38881; fc_bias[3] = -33497; fc_bias[4] = -84369; fc_bias[5] = -95573;
    fc_multiplier[0] = 1083681381; fc_multiplier[1] = 1391943058; fc_multiplier[2] = 1082184949; fc_multiplier[3] = 1720878833; fc_multiplier[4] = 1079290077; fc_multiplier[5] = 1807948028;
    fc_right_shift[0] = 10; fc_right_shift[1] = 10; fc_right_shift[2] = 10; fc_right_shift[3] = 11; fc_right_shift[4] = 10; fc_right_shift[5] = 11;

    for (int class_index = 0; class_index < 6; class_index++) begin
      for (int group = 0; group < GF_GAP_LANES/4; group++) begin
        @(negedge clk);
        fc_weight_write_valid = 1'b1;
        fc_weight_write_class = 3'(class_index);
        fc_weight_write_group = 4'(group);
        for (int lane = 0; lane < 4; lane++) begin
          fc_weight_write_data[lane] = fc_memory[class_index * 112 + group * 4 + lane];
        end
      end
    end
    @(negedge clk);
    fc_weight_write_valid = 1'b0;

    @(negedge clk);
    fc_start = 1'b1;
    @(negedge clk);
    fc_start = 1'b0;
    wait (fc_done);
    repeat (2) @(posedge clk);
    if (fc_fault) $fatal(1, "FC tail fault");
    if (fc_predicted_class != 0 || fc_fnv1a != 32'hDDE32561) begin
      $fatal(1, "FC tail wrong class=%0d fc=%08x", fc_predicted_class, fc_fnv1a);
    end
    $display("GESTUREFLOW_HEAD1X1_GAP_FC_REAL_PASS fc=%08x class=%0d", fc_fnv1a, fc_predicted_class);
    $finish;
  end
endmodule
