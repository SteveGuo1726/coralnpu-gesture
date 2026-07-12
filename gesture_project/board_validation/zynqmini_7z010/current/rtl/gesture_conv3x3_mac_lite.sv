module GestureConv3x3MacLite (
  input  wire        clock,
  input  wire        reset,
  input  wire        start,
  input  wire        clear,
  input  wire [31:0] act0,
  input  wire [31:0] act1,
  input  wire [31:0] act2,
  input  wire [31:0] wgt0,
  input  wire [31:0] wgt1,
  input  wire [31:0] wgt2,
  input  wire [31:0] bias,
  output reg         busy,
  output reg         valid,
  output reg  [31:0] result,
  output reg  [7:0]  relu8,
  output reg  [31:0] op_count
);
  wire signed [7:0] a0 = act0[7:0];
  wire signed [7:0] a1 = act0[15:8];
  wire signed [7:0] a2 = act0[23:16];
  wire signed [7:0] a3 = act0[31:24];
  wire signed [7:0] a4 = act1[7:0];
  wire signed [7:0] a5 = act1[15:8];
  wire signed [7:0] a6 = act1[23:16];
  wire signed [7:0] a7 = act1[31:24];
  wire signed [7:0] a8 = act2[7:0];

  wire signed [7:0] a0_q = act0_q[7:0];
  wire signed [7:0] a1_q = act0_q[15:8];
  wire signed [7:0] a2_q = act0_q[23:16];
  wire signed [7:0] a3_q = act0_q[31:24];
  wire signed [7:0] a4_q = act1_q[7:0];
  wire signed [7:0] a5_q = act1_q[15:8];
  wire signed [7:0] a6_q = act1_q[23:16];
  wire signed [7:0] a7_q = act1_q[31:24];
  wire signed [7:0] a8_q = act2_q[7:0];

  wire signed [7:0] w0 = wgt0[7:0];
  wire signed [7:0] w1 = wgt0[15:8];
  wire signed [7:0] w2 = wgt0[23:16];
  wire signed [7:0] w3 = wgt0[31:24];
  wire signed [7:0] w4 = wgt1[7:0];
  wire signed [7:0] w5 = wgt1[15:8];
  wire signed [7:0] w6 = wgt1[23:16];
  wire signed [7:0] w7 = wgt1[31:24];
  wire signed [7:0] w8 = wgt2[7:0];

  wire signed [7:0] w0_q = wgt0_q[7:0];
  wire signed [7:0] w1_q = wgt0_q[15:8];
  wire signed [7:0] w2_q = wgt0_q[23:16];
  wire signed [7:0] w3_q = wgt0_q[31:24];
  wire signed [7:0] w4_q = wgt1_q[7:0];
  wire signed [7:0] w5_q = wgt1_q[15:8];
  wire signed [7:0] w6_q = wgt1_q[23:16];
  wire signed [7:0] w7_q = wgt1_q[31:24];
  wire signed [7:0] w8_q = wgt2_q[7:0];

  reg [31:0] act0_q;
  reg [31:0] act1_q;
  reg [31:0] act2_q;
  reg [31:0] wgt0_q;
  reg [31:0] wgt1_q;
  reg [31:0] wgt2_q;

  reg [1:0] phase;
  reg signed [15:0] p0;
  reg signed [15:0] p1;
  reg signed [15:0] p2;
  reg signed [15:0] p3;
  reg signed [15:0] p4;
  reg signed [15:0] p5;
  reg signed [15:0] p6;
  reg signed [15:0] p7;
  reg signed [15:0] p8;
  reg signed [31:0] bias_r;
  reg signed [31:0] sum_r;

  always @(posedge clock or posedge reset) begin
    if (reset) begin
      phase <= 2'd0;
      busy <= 1'b0;
      valid <= 1'b0;
      result <= 32'd0;
      relu8 <= 8'd0;
      op_count <= 32'd0;
      act0_q <= 32'd0;
      act1_q <= 32'd0;
      act2_q <= 32'd0;
      wgt0_q <= 32'd0;
      wgt1_q <= 32'd0;
      wgt2_q <= 32'd0;
      p0 <= 16'sd0;
      p1 <= 16'sd0;
      p2 <= 16'sd0;
      p3 <= 16'sd0;
      p4 <= 16'sd0;
      p5 <= 16'sd0;
      p6 <= 16'sd0;
      p7 <= 16'sd0;
      p8 <= 16'sd0;
      bias_r <= 32'sd0;
      sum_r <= 32'sd0;
    end else begin
      if (clear) begin
        phase <= 2'd0;
        busy <= 1'b0;
        valid <= 1'b0;
        result <= 32'd0;
        relu8 <= 8'd0;
        op_count <= 32'd0;
        act0_q <= 32'd0;
        act1_q <= 32'd0;
        act2_q <= 32'd0;
        wgt0_q <= 32'd0;
        wgt1_q <= 32'd0;
        wgt2_q <= 32'd0;
        p0 <= 16'sd0;
        p1 <= 16'sd0;
        p2 <= 16'sd0;
        p3 <= 16'sd0;
        p4 <= 16'sd0;
        p5 <= 16'sd0;
        p6 <= 16'sd0;
        p7 <= 16'sd0;
        p8 <= 16'sd0;
        bias_r <= 32'sd0;
        sum_r <= 32'sd0;
      end else if (start && phase == 2'd0) begin
        phase <= 2'd1;
        busy <= 1'b1;
        valid <= 1'b0;
        act0_q <= act0;
        act1_q <= act1;
        act2_q <= act2;
        wgt0_q <= wgt0;
        wgt1_q <= wgt1;
        wgt2_q <= wgt2;
        p0 <= $signed(a0) * $signed(w0);
        p1 <= $signed(a1) * $signed(w1);
        p2 <= $signed(a2) * $signed(w2);
        p3 <= $signed(a3) * $signed(w3);
        p4 <= $signed(a4) * $signed(w4);
        p5 <= $signed(a5) * $signed(w5);
        p6 <= $signed(a6) * $signed(w6);
        p7 <= $signed(a7) * $signed(w7);
        p8 <= $signed(a8) * $signed(w8);
        bias_r <= $signed(bias);
      end else if (phase == 2'd1) begin
        phase <= 2'd2;
        sum_r <= bias_r
          + $signed(p0) + $signed(p1) + $signed(p2)
          + $signed(p3) + $signed(p4) + $signed(p5)
          + $signed(p6) + $signed(p7) + $signed(p8);
        p0 <= $signed(a0_q) * $signed(w0_q);
        p1 <= $signed(a1_q) * $signed(w1_q);
        p2 <= $signed(a2_q) * $signed(w2_q);
        p3 <= $signed(a3_q) * $signed(w3_q);
        p4 <= $signed(a4_q) * $signed(w4_q);
        p5 <= $signed(a5_q) * $signed(w5_q);
        p6 <= $signed(a6_q) * $signed(w6_q);
        p7 <= $signed(a7_q) * $signed(w7_q);
        p8 <= $signed(a8_q) * $signed(w8_q);
      end else if (phase == 2'd2) begin
        phase <= 2'd0;
        busy <= 1'b0;
        valid <= 1'b1;
        result <= sum_r;
        op_count <= op_count + 32'd1;
        if (sum_r[31]) begin
          relu8 <= 8'd0;
        end else if (sum_r > 32'sd255) begin
          relu8 <= 8'd255;
        end else begin
          relu8 <= sum_r[7:0];
        end
      end
    end
  end
endmodule
