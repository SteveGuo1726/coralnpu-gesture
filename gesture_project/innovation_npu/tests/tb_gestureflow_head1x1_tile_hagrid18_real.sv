// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Real head 1x1 tile regression for the first 16 output channels of the
// HaGRID-18 distilled student tail (48->64 head, 12 input-channel groups).
`timescale 1ns/1ps
module tb_gestureflow_head1x1_tile_hagrid18_real;
  `include "generated_gestureflow_real_conv4x4_head1x1_hagrid18_layer.svh"

  localparam int GF_TILE_LANES = 16;
  localparam int GF_HEAD1X1_EMBEDDED_CENTER_TAP = 5;

  logic clk = 0;
  logic rst_n = 0;
  logic frame_start = 0;
  logic pixel_valid = 0;
  logic pixel_ready;
  logic signed [GF_HEAD1X1_INPUT_CHANNELS-1:0][7:0] pixel_data;
  logic weight_write_valid = 0;
  logic weight_bank_select = 0;
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
  integer output_count = 0;
  integer probe_hits = 0;
  integer unsigned output_hash = 32'h811c9dc5;

  gestureflow_conv1x1_cin_stream #(
    .IMAGE_WIDTH(GF_HEAD1X1_WIDTH), .IMAGE_HEIGHT(GF_HEAD1X1_HEIGHT),
    .INPUT_CHANNELS(GF_HEAD1X1_INPUT_CHANNELS), .OUT_LANES(GF_TILE_LANES)
  ) stream (
    .clk(clk), .rst_n(rst_n),
    .image_width(16'(GF_HEAD1X1_WIDTH)), .image_height(16'(GF_HEAD1X1_HEIGHT)),
    .frame_start(frame_start), .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
    .pixel_data(pixel_data), .input_group_count(5'(GF_HEAD1X1_INPUT_CHANNELS/4)), .input_lane_enable(4'hf),
    .weight_write_valid(weight_write_valid), .weight_write_oc(weight_write_oc),
    .weight_write_tap(weight_write_tap), .weight_write_ic_group(weight_write_ic_group),
    .weight_write_data(weight_write_data), .weight_bank_select(weight_bank_select),
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

  always #5 clk = ~clk;

  always_ff @(posedge clk) begin
    if (frame_input_done) frame_input_done_seen <= 1'b1;
    if (raw_valid && raw_ready) begin
      quant_row <= raw_row;
      quant_column <= raw_column;
    end
    if (quant_valid && quant_ready) begin
      int row;
      int column;
      output_count = output_count + 1;
      row = int'(quant_row);
      column = int'(quant_column);
      for (int lane = 0; lane < GF_TILE_LANES; lane++) begin
        if ($signed(quant_data[lane]) !== gf_head1x1_output_q[
          ((row * GF_HEAD1X1_WIDTH + column) * GF_HEAD1X1_LANES) + lane
        ]) begin
          $fatal(1, "head1x1 tile mismatch y=%0d x=%0d lane=%0d got=%0d expected=%0d",
            row, column, lane, $signed(quant_data[lane]),
            gf_head1x1_output_q[((row * GF_HEAD1X1_WIDTH + column) * GF_HEAD1X1_LANES) + lane]);
        end
        output_hash = (output_hash ^ {24'd0, quant_data[lane]}) * 32'h01000193;
      end
      for (int probe = 0; probe < GF_HEAD1X1_PROBE_COUNT; probe++) begin
        if ((row == int'(gf_head1x1_probe_y[probe])) && (column == int'(gf_head1x1_probe_x[probe]))) begin
          for (int lane = 0; lane < GF_TILE_LANES; lane++) begin
            if ($signed(quant_data[lane]) !== gf_head1x1_probe_quant[probe][lane]) begin
              $fatal(1, "head1x1 probe mismatch y=%0d x=%0d lane=%0d got=%0d expected=%0d",
                row, column, lane, $signed(quant_data[lane]), gf_head1x1_probe_quant[probe][lane]);
            end
          end
          probe_hits = probe_hits + 1;
        end
      end
    end
  end

  initial begin
    pixel_data = '0;
    quant_row = '0;
    quant_column = '0;
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

    for (int watchdog = 0; watchdog < 200000 && output_count < GF_HEAD1X1_WIDTH * GF_HEAD1X1_HEIGHT; watchdog++) begin
      @(negedge clk);
    end
    if (raw_fault || quant_fault || !frame_input_done_seen || probe_hits != GF_HEAD1X1_PROBE_COUNT ||
        output_count != GF_HEAD1X1_WIDTH * GF_HEAD1X1_HEIGHT) begin
      $fatal(1, "head1x1 real failed outputs=%0d probes=%0d done=%b raw_fault=%b quant_fault=%b hash=%08x",
        output_count, probe_hits, frame_input_done_seen, raw_fault, quant_fault, output_hash);
    end
    $display("GESTUREFLOW_HEAD1X1_TILE_HAGRID18_REAL_PASS outputs=%0d probes=%0d hash=%08x",
      output_count, probe_hits, output_hash);
    $finish;
  end
endmodule
