// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps

// Wide-output DMP MAC regression: 16 output lanes, 8 input lanes, 16 taps and
// two input groups.  This mirrors the real body2 geometry and catches any
// output-pair addressing bug that a four-lane test would miss.
module tb_gestureflow_mac_tile_dmp_out16;
  localparam int OUT_LANES = 16;
  localparam int INPUT_LANES = 8;
  localparam int MAX_TAPS = 16;
  localparam int MAX_IC_GROUPS = 2;
  localparam int PAIRS = OUT_LANES / 2;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic weight_write_valid = 1'b0;
  logic [$clog2(PAIRS)-1:0] weight_write_pair = '0;
  logic [$clog2(MAX_TAPS)-1:0] weight_write_tap = '0;
  logic [$clog2(MAX_IC_GROUPS)-1:0] weight_write_ic_group = '0;
  logic [8*24-1:0] weight_write_data = '0;
  logic weight_bank_select = 1'b0;
  logic read_bank_select = 1'b0;
  logic start_valid = 1'b0;
  logic start_ready;
  logic signed [OUT_LANES-1:0][31:0] bias = '0;
  logic [OUT_LANES-1:0] output_lane_enable = '1;
  logic mac_valid = 1'b0;
  logic mac_ready;
  logic [$clog2(MAX_TAPS)-1:0] mac_tap = '0;
  logic [$clog2(MAX_IC_GROUPS)-1:0] mac_ic_group = '0;
  logic signed [INPUT_LANES-1:0][7:0] activation = '0;
  logic [INPUT_LANES-1:0] input_lane_enable = '0;
  logic mac_last = 1'b0;
  logic result_valid;
  logic result_ready = 1'b1;
  logic signed [OUT_LANES-1:0][31:0] result_psum;
  logic [OUT_LANES-1:0] result_lane_enable;
  logic busy;
  logic protocol_error;

  integer expected [0:OUT_LANES-1];
  int errors = 0;

  gestureflow_mac_tile_dmp #(
    .OUT_LANES(OUT_LANES), .INPUT_LANES(INPUT_LANES),
    .MAX_TAPS(MAX_TAPS), .MAX_IC_GROUPS(MAX_IC_GROUPS)
  ) dut (.*);

  always #5 clk = ~clk;

  function automatic integer weight_val(input int oc, input int tap, input int group, input int lane);
    return ((oc * 13 + tap * 7 + group * 11 + lane * 5 + 3) % 31) - 15;
  endfunction

  function automatic integer activation_val(input int tap, input int group, input int lane);
    return ((tap * 3 + group * 5 + lane * 2 + 1) % 17) - 8;
  endfunction

  task automatic load_weight(input int pair, input int tap, input int group);
    logic [7:0][23:0] wpack;
    begin
      for (int lane = 0; lane < 8; lane++) begin
        integer w_even, w_odd;
        w_even = weight_val(2*pair, tap, group, lane) + 128;
        w_odd = weight_val(2*pair+1, tap, group, lane) + 128;
        wpack[lane] = {w_odd[7:0], 8'b0, w_even[7:0]};
      end
      @(negedge clk);
      weight_write_pair = pair[$clog2(PAIRS)-1:0];
      weight_write_tap = tap[$clog2(MAX_TAPS)-1:0];
      weight_write_ic_group = group[$clog2(MAX_IC_GROUPS)-1:0];
      weight_write_data = wpack;
      weight_write_valid = 1'b1;
      @(negedge clk);
      weight_write_valid = 1'b0;
    end
  endtask

  task automatic send_group(input int tap, input int group, input bit last);
    begin
      while (!mac_ready) @(negedge clk);
      mac_tap = tap[$clog2(MAX_TAPS)-1:0];
      mac_ic_group = group[$clog2(MAX_IC_GROUPS)-1:0];
      input_lane_enable = '1;
      for (int lane = 0; lane < 8; lane++) begin
        integer a;
        a = activation_val(tap, group, lane);
        activation[lane] = a[7:0];
      end
      mac_last = last;
      mac_valid = 1'b1;
      @(negedge clk);
      mac_valid = 1'b0;
      mac_last = 1'b0;
    end
  endtask

  initial begin
    for (int oc = 0; oc < OUT_LANES; oc++) begin
      integer sum_w = 0;
      expected[oc] = 0;
      for (int tap = 0; tap < MAX_TAPS; tap++) begin
        for (int group = 0; group < MAX_IC_GROUPS; group++) begin
          for (int lane = 0; lane < INPUT_LANES; lane++) begin
            expected[oc] += activation_val(tap, group, lane) * weight_val(oc, tap, group, lane);
            sum_w += weight_val(oc, tap, group, lane);
          end
        end
      end
      bias[oc] = -128 * sum_w - 16384 * (MAX_TAPS * MAX_IC_GROUPS * INPUT_LANES);
    end

    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    for (int pair = 0; pair < PAIRS; pair++)
      for (int tap = 0; tap < MAX_TAPS; tap++)
        for (int group = 0; group < MAX_IC_GROUPS; group++)
          load_weight(pair, tap, group);

    while (!start_ready) @(negedge clk);
    start_valid = 1'b1;
    @(negedge clk);
    start_valid = 1'b0;
    for (int tap = 0; tap < MAX_TAPS; tap++) begin
      for (int group = 0; group < MAX_IC_GROUPS; group++) begin
        bit last = (tap == MAX_TAPS-1) && (group == MAX_IC_GROUPS-1);
        send_group(tap, group, last);
      end
    end
    while (!result_valid) @(negedge clk);
    for (int oc = 0; oc < OUT_LANES; oc++) begin
      if (result_psum[oc] !== expected[oc]) begin
        $display("FAIL oc=%0d expected=%0d got=%0d", oc, expected[oc], result_psum[oc]);
        errors++;
      end
    end
    if (protocol_error) begin
      $display("FAIL protocol_error"); errors++;
    end
    if (errors == 0) $display("GESTUREFLOW_MAC_TILE_DMP_OUT16_PASS");
    else $display("GESTUREFLOW_MAC_TILE_DMP_OUT16_FAIL errors=%0d", errors);
    $finish;
  end
endmodule
