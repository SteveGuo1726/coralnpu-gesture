// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_head_tile_gap_accumulator;
  localparam int LANES = 16;
  localparam int PIXEL_COUNT = 4;

  logic clk = 0, rst_n = 0, start = 0, clear = 0;
  logic [13:0] pixel_count = 14'(PIXEL_COUNT);
  logic signed [31:0] gap_multiplier = 32'sd1161448398;
  logic [5:0] gap_right_shift = 1;
  logic signed [7:0] gap_input_zero_point = -8'sd128;
  logic signed [7:0] gap_output_zero_point = -8'sd128;
  logic signed [LANES-1:0][7:0] pixel_data;
  logic pixel_valid = 0, pixel_ready, gap_valid, busy, done, fault;
  logic signed [LANES-1:0][7:0] gap_data;
  logic [13:0] pixels_seen;

  gestureflow_head_tile_gap_accumulator dut (.*);

  always #5 clk = ~clk;

  function automatic logic signed [31:0] trunc_shift31(input logic signed [63:0] value);
    logic signed [63:0] magnitude;
    begin
      if (value < 0) begin
        magnitude = -value;
        trunc_shift31 = -$signed(magnitude[62:31]);
      end else begin
        trunc_shift31 = $signed(value[62:31]);
      end
    end
  endfunction

  function automatic logic signed [31:0] high_mul(
    input logic signed [31:0] left,
    input logic signed [31:0] right
  );
    logic signed [63:0] product, nudge;
    begin
      if ((left == 32'sh80000000) && (right == 32'sh80000000)) high_mul = 32'sh7fffffff;
      else begin
        product = left * right;
        nudge = product >= 0 ? 64'sh0000000040000000 : -64'sh000000003fffffff;
        high_mul = trunc_shift31(product + nudge);
      end
    end
  endfunction

  function automatic logic signed [31:0] round_div_pot(
    input logic signed [31:0] value,
    input logic [5:0] shift
  );
    logic [31:0] mask, remainder, threshold;
    logic signed [31:0] base;
    begin
      if (shift == 0) round_div_pot = value;
      else begin
        mask = (32'h1 << shift) - 1'b1;
        remainder = value & mask;
        threshold = (mask >> 1) + (value < 0 ? 1 : 0);
        base = value >>> shift;
        round_div_pot = remainder > threshold ? base + 1 : base;
      end
    end
  endfunction

  function automatic logic signed [7:0] requantize(
    input logic signed [31:0] accumulator,
    input logic signed [31:0] multiplier,
    input logic [5:0] right_shift,
    input logic signed [7:0] zero_point
  );
    logic signed [31:0] result, with_zero_point;
    begin
      result = round_div_pot(high_mul(accumulator, multiplier), right_shift);
      with_zero_point = result + {{24{zero_point[7]}}, zero_point};
      if (with_zero_point > 127) requantize = 8'sh7f;
      else if (with_zero_point < -128) requantize = -8'sh80;
      else requantize = with_zero_point[7:0];
    end
  endfunction

  task automatic send_pixel(input int base);
    begin
      @(negedge clk);
      for (int lane = 0; lane < LANES; lane++) pixel_data[lane] = 8'(base + lane - 8);
      pixel_valid = 1'b1;
      while (!pixel_ready) @(negedge clk);
      @(negedge clk);
      pixel_valid = 1'b0;
    end
  endtask

  initial begin
    logic signed [LANES-1:0][7:0] observed_gap;
    logic signed [LANES-1:0][7:0] expected_gap;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    for (int i = 0; i < PIXEL_COUNT; i++) send_pixel(i);
    wait (done);
    repeat (2) @(posedge clk);
    if (fault) $fatal(1, "head tile gap accumulator fault");
    if (!gap_valid) $fatal(1, "head tile gap accumulator did not emit");
    observed_gap = gap_data;
    for (int lane = 0; lane < LANES; lane++) begin
      logic signed [31:0] sum;
      sum = 0;
      for (int i = 0; i < PIXEL_COUNT; i++) sum += (i + lane - 8);
      expected_gap[lane] = requantize(
        sum - ($signed({{24{gap_input_zero_point[7]}}, gap_input_zero_point}) * 32'sd144),
        gap_multiplier, gap_right_shift, gap_output_zero_point
      );
      if (observed_gap[lane] !== expected_gap[lane]) begin
        $fatal(1, "lane mismatch lane=%0d got=%0d expected=%0d", lane, observed_gap[lane], expected_gap[lane]);
      end
    end
    $display("GESTUREFLOW_HEAD_TILE_GAP_ACCUMULATOR_PASS pixels=%0d", PIXEL_COUNT);
    $finish;
  end
endmodule
