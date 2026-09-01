// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps

// Bit-exact proof for the DMP tile.  The reference model computes ordinary
// signed INT8 dot products in 64-bit integers.  The DUT packs two output
// channels into each 25x18 DSP product, folds the per-channel weight/bias
// correction into bias', and subtracts the shared activation correction.
// PASS means the packed hardware path and the naive signed model agree for
// every output channel after all taps and input-channel groups.
module tb_gestureflow_mac_tile_dmp;
  localparam int OUT_LANES = 4;
  localparam int INPUT_LANES = 8;
  localparam int MAX_TAPS = 3;
  localparam int MAX_IC_GROUPS = 2;
  localparam int PAIR_LANES = OUT_LANES / 2;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic weight_write_valid = 1'b0;
  logic [$clog2(PAIR_LANES)-1:0] weight_write_pair = '0;
  logic [$clog2(MAX_TAPS)-1:0] weight_write_tap = '0;
  logic [$clog2(MAX_IC_GROUPS)-1:0] weight_write_ic_group = '0;
  logic [INPUT_LANES*24-1:0] weight_write_data = '0;
  logic weight_bank_select = 1'b0;
  logic read_bank_select = 1'b0;
  logic start_valid = 1'b0;
  logic start_ready;
  logic signed [OUT_LANES-1:0][31:0] bias = '0;
  logic [OUT_LANES-1:0] output_lane_enable = '0;
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

  gestureflow_mac_tile_dmp #(
    .OUT_LANES(OUT_LANES),
    .INPUT_LANES(INPUT_LANES),
    .MAX_TAPS(MAX_TAPS),
    .MAX_IC_GROUPS(MAX_IC_GROUPS)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .weight_write_valid(weight_write_valid), .weight_write_pair(weight_write_pair),
    .weight_write_tap(weight_write_tap), .weight_write_ic_group(weight_write_ic_group),
    .weight_write_data(weight_write_data), .weight_bank_select(weight_bank_select),
    .read_bank_select(read_bank_select), .start_valid(start_valid),
    .start_ready(start_ready), .bias(bias), .output_lane_enable(output_lane_enable),
    .mac_valid(mac_valid), .mac_ready(mac_ready), .mac_tap(mac_tap),
    .mac_ic_group(mac_ic_group), .activation(activation),
    .input_lane_enable(input_lane_enable), .mac_last(mac_last),
    .result_valid(result_valid), .result_ready(result_ready),
    .result_psum(result_psum), .result_lane_enable(result_lane_enable),
    .busy(busy), .protocol_error(protocol_error)
  );

  always #5 clk = ~clk;

  integer expected [0:OUT_LANES-1];
  integer weight_sum [0:OUT_LANES-1];
  integer activation_sum = 0;
  int errors = 0;

  function automatic integer activation_val(input int g, input int ic);
    return ((g * 7 + ic * 3 + 5) % 33) - 16;
  endfunction

  function automatic integer weight_val(input int oc, input int tap, input int group,
                                       input int ic);
    return ((oc * 13 + tap * 5 + group * 11 + ic * 7 + 3) % 31) - 15;
  endfunction

  task automatic load_weight(input int pair, input int tap, input int group,
                             input logic bank_sel);
    logic [INPUT_LANES-1:0][23:0] wpack;
    begin
      for (int ic = 0; ic < INPUT_LANES; ic++) begin
        integer w_even, w_odd;
        w_even = weight_val(2*pair, tap, group, ic) + 128;
        w_odd = weight_val(2*pair+1, tap, group, ic) + 128;
        wpack[ic] = {w_odd[7:0], 8'b0, w_even[7:0]};
      end
      @(negedge clk);
      weight_bank_select = bank_sel;
      weight_write_pair = pair[$clog2(PAIR_LANES)-1:0];
      weight_write_tap = tap[$clog2(MAX_TAPS)-1:0];
      weight_write_ic_group = group[$clog2(MAX_IC_GROUPS)-1:0];
      weight_write_data = wpack;
      weight_write_valid = 1'b1;
      @(negedge clk);
      weight_write_valid = 1'b0;
    end
  endtask

  task automatic send_group(input int tap, input int group, input bit last);
    int g = tap * MAX_IC_GROUPS + group;
    begin
      while (!mac_ready) @(negedge clk);
      mac_tap = tap[$clog2(MAX_TAPS)-1:0];
      mac_ic_group = group[$clog2(MAX_IC_GROUPS)-1:0];
      input_lane_enable = '1;
      for (int ic = 0; ic < INPUT_LANES; ic++) begin
        integer a;
        a = activation_val(g, ic);
        activation[ic] = a[7:0];
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
      expected[oc] = oc * 17 - 20;
      weight_sum[oc] = 0;
      for (int tap = 0; tap < MAX_TAPS; tap++) begin
        for (int group = 0; group < MAX_IC_GROUPS; group++) begin
          int g = tap * MAX_IC_GROUPS + group;
          for (int ic = 0; ic < INPUT_LANES; ic++) begin
            integer a = activation_val(g, ic);
            integer w = weight_val(oc, tap, group, ic);
            expected[oc] += a * w;
            weight_sum[oc] += w;
            if (oc == 0) activation_sum += a;
          end
        end
      end
    end

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int pair = 0; pair < PAIR_LANES; pair++) begin
      for (int tap = 0; tap < MAX_TAPS; tap++) begin
        for (int group = 0; group < MAX_IC_GROUPS; group++) begin
          load_weight(pair, tap, group, 1'b0);
        end
      end
    end

    while (!start_ready) @(negedge clk);
    for (int oc = 0; oc < OUT_LANES; oc++) begin
      bias[oc] = (oc * 17 - 20) - 128 * weight_sum[oc]
               - 16384 * (MAX_TAPS * MAX_IC_GROUPS * INPUT_LANES);
    end
    output_lane_enable = '1;
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
    if (result_lane_enable !== {OUT_LANES{1'b1}}) begin
      $display("FAIL result_lane_enable=%b", result_lane_enable);
      errors++;
    end
    if (protocol_error) begin
      $display("FAIL protocol_error asserted");
      errors++;
    end

    if (errors == 0) begin
      $display("GESTUREFLOW_MAC_TILE_DMP_PASS psum=%0d,%0d,%0d,%0d",
               result_psum[0], result_psum[1], result_psum[2], result_psum[3]);
    end else begin
      $display("GESTUREFLOW_MAC_TILE_DMP_FAIL errors=%0d", errors);
    end
    $finish;
  end
endmodule
