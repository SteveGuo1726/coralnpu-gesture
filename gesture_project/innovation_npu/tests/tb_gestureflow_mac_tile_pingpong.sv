// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps

// Verifies weight ping-pong preload: the MAC computes from read_bank_select
// while simultaneously accepting weight writes into the opposite bank. The
// in-flight job must keep its weights intact, and the newly written bank must
// be readable by a subsequent job.
module tb_gestureflow_mac_tile_pingpong;
  localparam int OUT_LANES = 2;
  localparam int INPUT_LANES = 2;
  localparam int MAX_TAPS = 4;
  localparam int MAX_IC_GROUPS = 2;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic weight_write_valid = 1'b0;
  logic [$clog2(OUT_LANES)-1:0] weight_write_oc = '0;
  logic [$clog2(MAX_TAPS)-1:0] weight_write_tap = '0;
  logic [$clog2(MAX_IC_GROUPS)-1:0] weight_write_ic_group = '0;
  logic signed [INPUT_LANES-1:0][7:0] weight_write_data = '0;
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

  gestureflow_mac_tile #(
    .OUT_LANES(OUT_LANES), .INPUT_LANES(INPUT_LANES),
    .MAX_TAPS(MAX_TAPS), .MAX_IC_GROUPS(MAX_IC_GROUPS)
  ) dut (
    .clk(clk), .rst_n(rst_n), .weight_write_valid(weight_write_valid),
    .weight_write_oc(weight_write_oc), .weight_write_tap(weight_write_tap),
    .weight_write_ic_group(weight_write_ic_group), .weight_write_data(weight_write_data),
    .weight_bank_select(weight_bank_select), .read_bank_select(read_bank_select),
    .start_valid(start_valid), .start_ready(start_ready), .bias(bias),
    .output_lane_enable(output_lane_enable), .mac_valid(mac_valid), .mac_ready(mac_ready),
    .mac_tap(mac_tap), .mac_ic_group(mac_ic_group), .activation(activation),
    .input_lane_enable(input_lane_enable), .mac_last(mac_last),
    .result_valid(result_valid), .result_ready(result_ready), .result_psum(result_psum),
    .result_lane_enable(result_lane_enable), .busy(busy), .protocol_error(protocol_error)
  );

  always #5 clk = ~clk;

  logic signed [OUT_LANES-1:0][31:0] exp_a, exp_b;
  int errors = 0;

  function automatic int w_a(int oc, int tap, int group, int lane);
    return (lane == 0) ? (oc * 100 + tap * 10 + group + 1)
                       : -(oc * 50 + tap * 5 + group + 2);
  endfunction

  function automatic int w_b(int oc, int tap, int group, int lane);
    return (lane == 0) ? (oc * 60 + tap * 20 + group + 3)
                       : -(oc * 50 + tap * 8 + group + 4);
  endfunction

  task automatic load_weight(input int oc, input int tap, input int group,
                             input logic bank_sel, input integer w0, input integer w1);
    @(negedge clk);
    weight_bank_select = bank_sel;
    weight_write_valid = 1'b1;
    weight_write_oc = oc[$clog2(OUT_LANES)-1:0];
    weight_write_tap = tap[$clog2(MAX_TAPS)-1:0];
    weight_write_ic_group = group[$clog2(MAX_IC_GROUPS)-1:0];
    weight_write_data[0] = w0[7:0];
    weight_write_data[1] = w1[7:0];
    @(negedge clk);
    weight_write_valid = 1'b0;
  endtask

  task automatic send_group(input int tap, input int group, input integer a0,
                            input integer a1, input bit last);
    while (!mac_ready) @(negedge clk);
    mac_tap = tap[$clog2(MAX_TAPS)-1:0];
    mac_ic_group = group[$clog2(MAX_IC_GROUPS)-1:0];
    activation[0] = a0[7:0];
    activation[1] = a1[7:0];
    input_lane_enable = 2'b11;
    mac_last = last;
    mac_valid = 1'b1;
    @(negedge clk);
    mac_valid = 1'b0;
    mac_last = 1'b0;
  endtask

  task automatic start_job(input logic bank_sel);
    while (!start_ready) @(negedge clk);
    read_bank_select = bank_sel;
    start_valid = 1'b1;
    @(negedge clk);
    start_valid = 1'b0;
  endtask

  task automatic run_all_groups;
    send_group(0, 0, 1, -2, 1'b0);
    send_group(0, 1, 1, -2, 1'b0);
    send_group(1, 0, 1, -2, 1'b0);
    send_group(1, 1, 1, -2, 1'b1);
  endtask

  initial begin
    for (int oc = 0; oc < OUT_LANES; oc++) begin
      exp_a[oc] = 0; exp_b[oc] = 0;
      for (int tap = 0; tap < 2; tap++) begin
        for (int group = 0; group < 2; group++) begin
          exp_a[oc] += 1 * w_a(oc, tap, group, 0) + (-2) * w_a(oc, tap, group, 1);
          exp_b[oc] += 1 * w_b(oc, tap, group, 0) + (-2) * w_b(oc, tap, group, 1);
        end
      end
    end

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // 1) Load bank A weights while idle.
    for (int oc = 0; oc < OUT_LANES; oc++)
      for (int tap = 0; tap < 2; tap++)
        for (int group = 0; group < 2; group++)
          load_weight(oc, tap, group, 1'b0, w_a(oc, tap, group, 0), w_a(oc, tap, group, 1));

    // 2) Start a job reading bank A; write bank B while the job is in flight.
    output_lane_enable = '1;
    start_job(1'b0);
    send_group(0, 0, 1, -2, 1'b0);
    if (!busy) begin $display("FAIL busy not asserted after first group"); errors++; end
    for (int oc = 0; oc < OUT_LANES; oc++)
      for (int tap = 0; tap < 2; tap++)
        for (int group = 0; group < 2; group++)
          load_weight(oc, tap, group, 1'b1, w_b(oc, tap, group, 0), w_b(oc, tap, group, 1));

    send_group(0, 1, 1, -2, 1'b0);
    send_group(1, 0, 1, -2, 1'b0);
    send_group(1, 1, 1, -2, 1'b1);
    while (!result_valid) @(negedge clk);

    for (int oc = 0; oc < OUT_LANES; oc++) begin
      if (result_psum[oc] !== exp_a[oc]) begin
        $display("FAIL bank A oc=%0d got=%0d want=%0d", oc, result_psum[oc], exp_a[oc]);
        errors++;
      end
    end
    if (protocol_error) begin $display("FAIL protocol_error during ping-pong"); errors++; end

    // 3) A second job reading bank B must see the freshly written weights.
    start_job(1'b1);
    run_all_groups();
    while (!result_valid) @(negedge clk);

    for (int oc = 0; oc < OUT_LANES; oc++) begin
      if (result_psum[oc] !== exp_b[oc]) begin
        $display("FAIL bank B oc=%0d got=%0d want=%0d", oc, result_psum[oc], exp_b[oc]);
        errors++;
      end
    end

    if (errors == 0) $display("GESTUREFLOW_MAC_TILE_PINGPONG_PASS");
    else $display("GESTUREFLOW_MAC_TILE_PINGPONG_FAIL errors=%0d", errors);
    $finish;
  end
endmodule
