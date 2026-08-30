// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps

module tb_gestureflow_mac_tile;
  localparam int OUT_LANES = 4;
  localparam int INPUT_LANES = 2;
  localparam int MAX_TAPS = 4;
  localparam int MAX_IC_GROUPS = 2;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic weight_write_valid;
  logic [$clog2(OUT_LANES)-1:0] weight_write_oc;
  logic [$clog2(MAX_TAPS)-1:0] weight_write_tap;
  logic [$clog2(MAX_IC_GROUPS)-1:0] weight_write_ic_group;
  logic signed [INPUT_LANES-1:0][7:0] weight_write_data;
  logic weight_bank_select;
  logic read_bank_select;
  logic start_valid;
  logic start_ready;
  logic signed [OUT_LANES-1:0][31:0] bias;
  logic [OUT_LANES-1:0] output_lane_enable;
  logic mac_valid;
  logic mac_ready;
  logic [$clog2(MAX_TAPS)-1:0] mac_tap;
  logic [$clog2(MAX_IC_GROUPS)-1:0] mac_ic_group;
  logic signed [INPUT_LANES-1:0][7:0] activation;
  logic [INPUT_LANES-1:0] input_lane_enable;
  logic mac_last;
  logic result_valid;
  logic result_ready;
  logic signed [OUT_LANES-1:0][31:0] result_psum;
  logic [OUT_LANES-1:0] result_lane_enable;
  logic busy;
  logic protocol_error;
  integer expected [0:OUT_LANES-1];

  gestureflow_mac_tile #(
    .OUT_LANES(OUT_LANES),
    .INPUT_LANES(INPUT_LANES),
    .MAX_TAPS(MAX_TAPS),
    .MAX_IC_GROUPS(MAX_IC_GROUPS)
  ) dut (.*);

  always #5 clk = ~clk;

  task automatic load_weight(input int oc, input int tap, input int group,
                             input integer w0, input integer w1);
    begin
      @(negedge clk);
      weight_write_valid = 1'b1;
      weight_write_oc = oc[$clog2(OUT_LANES)-1:0];
      weight_write_tap = tap[$clog2(MAX_TAPS)-1:0];
      weight_write_ic_group = group[$clog2(MAX_IC_GROUPS)-1:0];
      weight_write_data[0] = w0[7:0];
      weight_write_data[1] = w1[7:0];
      @(negedge clk);
      weight_write_valid = 1'b0;
    end
  endtask

  task automatic send_group(input int tap, input int group, input integer a0,
                            input integer a1, input bit last);
    begin
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
    end
  endtask

  initial begin
    weight_write_valid = 1'b0;
    start_valid = 1'b0;
    mac_valid = 1'b0;
    result_ready = 1'b1;
    bias = '0;
    output_lane_enable = '0;
    mac_tap = '0;
    mac_ic_group = '0;
    activation = '0;
    input_lane_enable = '0;
    mac_last = 1'b0;
    weight_bank_select = 1'b0;
    read_bank_select = 1'b0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // Four OC lanes, two taps, two IC groups. Weight values differ by every
    // index so the test catches lane, tap and group address mixups.
    for (int oc = 0; oc < OUT_LANES; oc++) begin
      expected[oc] = oc * 11;
      for (int tap = 0; tap < 2; tap++) begin
        for (int group = 0; group < 2; group++) begin
          load_weight(oc, tap, group,
                      oc + tap * 3 + group * 5 + 1,
                      -(oc + tap * 2 + group * 7 + 2));
        end
      end
    end

    for (int oc = 0; oc < OUT_LANES; oc++) begin
      for (int tap = 0; tap < 2; tap++) begin
        for (int group = 0; group < 2; group++) begin
          expected[oc] += 1 * (oc + tap * 3 + group * 5 + 1);
          expected[oc] += -2 * (-(oc + tap * 2 + group * 7 + 2));
        end
      end
    end

    while (!start_ready) @(negedge clk);
    bias[0] = 0;
    bias[1] = 11;
    bias[2] = 22;
    bias[3] = 33;
    output_lane_enable = 4'b1111;
    start_valid = 1'b1;
    @(negedge clk);
    start_valid = 1'b0;

    send_group(0, 0, 1, -2, 1'b0);
    send_group(0, 1, 1, -2, 1'b0);
    send_group(1, 0, 1, -2, 1'b0);
    send_group(1, 1, 1, -2, 1'b1);

    while (!result_valid) @(negedge clk);
    for (int oc = 0; oc < OUT_LANES; oc++) begin
      if (result_psum[oc] !== expected[oc]) begin
        $fatal(1, "lane %0d expected %0d got %0d", oc, expected[oc], result_psum[oc]);
      end
    end
    if (result_lane_enable !== 4'b1111 || protocol_error) begin
      $fatal(1, "result lanes or protocol state incorrect");
    end
    $display("GESTUREFLOW_MAC_TILE_PASS psum=%0d,%0d,%0d,%0d", result_psum[0], result_psum[1], result_psum[2], result_psum[3]);
    $finish;
  end
endmodule
