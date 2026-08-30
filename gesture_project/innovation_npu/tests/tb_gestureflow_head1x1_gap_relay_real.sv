// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Real head_1x1 -> GAP on-chip relay regression. It reuses the verified
// conv1x1_cin_stream + requant_relu pair to compute the first 16-lane tile of
// the deployed head_1x1 layer, then feeds that quantized tile stream directly
// into gestureflow_head_tile_gap_accumulator instead of writing the 12x12x16
// intermediate tile to DDR. The 16 emitted GAP values must exactly match the
// first 16 entries of the TFLite golden GAP vector (gf_post_gap_golden).
`timescale 1ns/1ps
module tb_gestureflow_head1x1_gap_relay_real;
  `include "generated_gestureflow_real_conv4x4_head1x1_layer.svh"

  localparam int GF_TILE_LANES = 16;
  localparam int GF_HEAD1X1_EMBEDDED_CENTER_TAP = 5;
  localparam int GF_GAP_PIXELS = GF_HEAD1X1_WIDTH * GF_HEAD1X1_HEIGHT; // 144

  // Tile-0 GAP golden for the deployed HaGRID-18 model, copied from
  // gestureflow_real_gap_fc.h gf_post_gap_golden[0:15].
  localparam logic signed [7:0] gf_tile0_gap_golden [0:GF_TILE_LANES-1] = '{
    -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd118, -8'sd128, -8'sd128, -8'sd11,
    -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128
  };
  localparam logic signed [31:0] GF_GAP_MULTIPLIER = 32'sd1339606099;
  localparam logic [5:0] GF_GAP_RIGHT_SHIFT = 6'd1;
  localparam logic signed [7:0] GF_GAP_INPUT_ZERO_POINT = -8'sd128;
  localparam logic signed [7:0] GF_GAP_OUTPUT_ZERO_POINT = -8'sd128;

  logic clk = 0;
  logic rst_n = 0;
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
  logic raw_valid;
  logic raw_ready;
  logic signed [GF_TILE_LANES-1:0][31:0] raw_psum;
  logic [GF_TILE_LANES-1:0] raw_mask;
  logic [15:0] raw_row;
  logic [15:0] raw_column;
  logic raw_busy;
  logic raw_fault;
  logic frame_input_done;
  logic frame_input_done_seen = 0;
  logic requant_enable = 1;
  logic requant_relu_enable = 1;
  logic signed [7:0] output_zero_point = -8'sd128;
  logic signed [GF_TILE_LANES-1:0][31:0] requant_multiplier = '0;
  logic [GF_TILE_LANES-1:0][5:0] requant_right_shift = '0;
  logic quant_valid;
  logic quant_ready = 1;
  logic signed [GF_TILE_LANES-1:0][7:0] quant_data;
  logic [GF_TILE_LANES-1:0] quant_mask;
  logic quant_fault;
  logic [15:0] quant_row;
  logic [15:0] quant_column;

  logic gap_start = 0;
  logic gap_clear = 0;
  logic [13:0] gap_pixel_count = 14'(GF_GAP_PIXELS);
  logic gap_pixel_valid;
  logic gap_pixel_ready;
  logic signed [GF_TILE_LANES-1:0][7:0] gap_pixel_data;
  logic gap_valid;
  logic signed [GF_TILE_LANES-1:0][7:0] gap_data;
  logic [13:0] gap_pixels_seen;
  logic gap_busy;
  logic gap_done;
  logic gap_fault;

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
    .weight_write_data(weight_write_data), .weight_bank_select(weight_bank_select),
    .read_bank_select(read_bank_select),
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

  // The quantized head_1x1 tile stream is consumed on-chip by the tile-local
  // GAP accumulator. quant_ready is slaved to the accumulator's ACCUM state so
  // the two form a single valid/ready handshake and never write the tile to DDR.
  gestureflow_head_tile_gap_accumulator #(.LANES(GF_TILE_LANES), .PIXEL_COUNT_W(14)) gap (
    .clk(clk), .rst_n(rst_n), .start(gap_start), .clear(gap_clear),
    .pixel_count(gap_pixel_count), .gap_multiplier(GF_GAP_MULTIPLIER),
    .gap_right_shift(GF_GAP_RIGHT_SHIFT), .gap_input_zero_point(GF_GAP_INPUT_ZERO_POINT),
    .gap_output_zero_point(GF_GAP_OUTPUT_ZERO_POINT), .pixel_data(gap_pixel_data),
    .pixel_valid(gap_pixel_valid), .pixel_ready(gap_pixel_ready), .gap_valid(gap_valid),
    .gap_data(gap_data), .pixels_seen(gap_pixels_seen), .busy(gap_busy),
    .done(gap_done), .fault(gap_fault)
  );

  assign gap_pixel_data = quant_data;
  assign gap_pixel_valid = quant_valid;
  assign quant_ready = gap_pixel_ready;

  always #5 clk = ~clk;

  always_ff @(posedge clk) begin
    if (frame_input_done) frame_input_done_seen <= 1'b1;
    if (raw_valid && raw_ready) begin
      quant_row <= raw_row;
      quant_column <= raw_column;
    end
  end

  initial begin
    pixel_data = '0;
    quant_row = '0;
    quant_column = '0;
    gap_pixel_data = '0;
    for (int lane = 0; lane < GF_TILE_LANES; lane++) begin
      bias[lane] = gf_head1x1_folded_bias[lane];
      requant_multiplier[lane] = gf_head1x1_multiplier[lane];
      requant_right_shift[lane] = gf_head1x1_right_shift[lane];
    end
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int oc = 0; oc < GF_TILE_LANES; oc++) begin
      for (int group = 0; group < GF_HEAD1X1_INPUT_CHANNELS / 4; group++) begin
        @(negedge clk);
        weight_write_valid = 1'b1;
        weight_write_oc = $clog2(GF_TILE_LANES)'(oc);
        weight_write_tap = '0;
        weight_write_ic_group = $clog2(GF_HEAD1X1_INPUT_CHANNELS/4)'(group);
        for (int lane = 0; lane < 4; lane++) begin
          weight_write_data[lane] = gf_head1x1_weights[
            (oc * 16 * GF_HEAD1X1_INPUT_CHANNELS) +
            (GF_HEAD1X1_EMBEDDED_CENTER_TAP * GF_HEAD1X1_INPUT_CHANNELS) +
            (group * 4) + lane
          ];
        end
        @(negedge clk);
        weight_write_valid = 1'b0;
      end
    end

    // Start the GAP accumulator before the conv so its ACCUM state is ready
    // to accept the first quantized tile vector.
    @(negedge clk);
    gap_start = 1'b1;
    @(negedge clk);
    gap_start = 1'b0;

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

    wait (gap_done);
    repeat (2) @(posedge clk);
    if (raw_fault || quant_fault || gap_fault) begin
      $fatal(1, "head1x1 gap relay fault raw=%b quant=%b gap=%b", raw_fault, quant_fault, gap_fault);
    end
    if (!gap_valid) begin
      $fatal(1, "head1x1 gap relay did not emit valid=%b pixels_seen=%0d", gap_valid, gap_pixels_seen);
    end
    for (int lane = 0; lane < GF_TILE_LANES; lane++) begin
      if ($signed(gap_data[lane]) !== gf_tile0_gap_golden[lane]) begin
        $fatal(1, "head1x1 gap relay lane=%0d got=%0d expected=%0d",
          lane, $signed(gap_data[lane]), gf_tile0_gap_golden[lane]);
      end
    end
    $display("GESTUREFLOW_HEAD1X1_GAP_RELAY_REAL_PASS pixels=%0d", GF_GAP_PIXELS);
    $finish;
  end
endmodule
