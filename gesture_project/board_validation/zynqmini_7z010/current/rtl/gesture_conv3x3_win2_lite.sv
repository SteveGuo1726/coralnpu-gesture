module GestureConv3x3Win2Lite (
  input  wire        clock,
  input  wire        reset,
  input  wire        start,
  input  wire        clear,
  input  wire [31:0] row0,
  input  wire [31:0] row1,
  input  wire [31:0] row2,
  input  wire [31:0] wgt0,
  input  wire [31:0] wgt1,
  input  wire [31:0] wgt2,
  input  wire [31:0] bias,
  output reg         busy,
  output reg         valid,
  output reg  [31:0] result0,
  output reg  [31:0] result1,
  output reg  [7:0]  relu8_0,
  output reg  [7:0]  relu8_1,
  output reg  [31:0] out_count
);
  wire signed [7:0] r0c0 = row0[7:0];
  wire signed [7:0] r0c1 = row0[15:8];
  wire signed [7:0] r0c2 = row0[23:16];
  wire signed [7:0] r0c3 = row0[31:24];
  wire signed [7:0] r1c0 = row1[7:0];
  wire signed [7:0] r1c1 = row1[15:8];
  wire signed [7:0] r1c2 = row1[23:16];
  wire signed [7:0] r1c3 = row1[31:24];
  wire signed [7:0] r2c0 = row2[7:0];
  wire signed [7:0] r2c1 = row2[15:8];
  wire signed [7:0] r2c2 = row2[23:16];
  wire signed [7:0] r2c3 = row2[31:24];

  wire signed [7:0] w0 = wgt0[7:0];
  wire signed [7:0] w1 = wgt0[15:8];
  wire signed [7:0] w2 = wgt0[23:16];
  wire signed [7:0] w3 = wgt0[31:24];
  wire signed [7:0] w4 = wgt1[7:0];
  wire signed [7:0] w5 = wgt1[15:8];
  wire signed [7:0] w6 = wgt1[23:16];
  wire signed [7:0] w7 = wgt1[31:24];
  wire signed [7:0] w8 = wgt2[7:0];

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
  reg signed [15:0] q0;
  reg signed [15:0] q1;
  reg signed [15:0] q2;
  reg signed [15:0] q3;
  reg signed [15:0] q4;
  reg signed [15:0] q5;
  reg signed [15:0] q6;
  reg signed [15:0] q7;
  reg signed [15:0] q8;
  reg signed [31:0] bias_r;
  reg signed [31:0] sum0_r;
  reg signed [31:0] sum1_r;

  always @(posedge clock or posedge reset) begin
    if (reset) begin
      phase <= 2'd0;
      busy <= 1'b0;
      valid <= 1'b0;
      result0 <= 32'd0;
      result1 <= 32'd0;
      relu8_0 <= 8'd0;
      relu8_1 <= 8'd0;
      out_count <= 32'd0;
      p0 <= 16'sd0;
      p1 <= 16'sd0;
      p2 <= 16'sd0;
      p3 <= 16'sd0;
      p4 <= 16'sd0;
      p5 <= 16'sd0;
      p6 <= 16'sd0;
      p7 <= 16'sd0;
      p8 <= 16'sd0;
      q0 <= 16'sd0;
      q1 <= 16'sd0;
      q2 <= 16'sd0;
      q3 <= 16'sd0;
      q4 <= 16'sd0;
      q5 <= 16'sd0;
      q6 <= 16'sd0;
      q7 <= 16'sd0;
      q8 <= 16'sd0;
      bias_r <= 32'sd0;
      sum0_r <= 32'sd0;
      sum1_r <= 32'sd0;
    end else begin
      if (clear) begin
        phase <= 2'd0;
        busy <= 1'b0;
        valid <= 1'b0;
        result0 <= 32'd0;
        result1 <= 32'd0;
        relu8_0 <= 8'd0;
        relu8_1 <= 8'd0;
        out_count <= 32'd0;
        sum0_r <= 32'sd0;
        sum1_r <= 32'sd0;
      end else if (start && phase == 2'd0) begin
        phase <= 2'd1;
        busy <= 1'b1;
        valid <= 1'b0;
        p0 <= $signed(r0c0) * $signed(w0);
        p1 <= $signed(r0c1) * $signed(w1);
        p2 <= $signed(r0c2) * $signed(w2);
        p3 <= $signed(r1c0) * $signed(w3);
        p4 <= $signed(r1c1) * $signed(w4);
        p5 <= $signed(r1c2) * $signed(w5);
        p6 <= $signed(r2c0) * $signed(w6);
        p7 <= $signed(r2c1) * $signed(w7);
        p8 <= $signed(r2c2) * $signed(w8);
        q0 <= $signed(r0c1) * $signed(w0);
        q1 <= $signed(r0c2) * $signed(w1);
        q2 <= $signed(r0c3) * $signed(w2);
        q3 <= $signed(r1c1) * $signed(w3);
        q4 <= $signed(r1c2) * $signed(w4);
        q5 <= $signed(r1c3) * $signed(w5);
        q6 <= $signed(r2c1) * $signed(w6);
        q7 <= $signed(r2c2) * $signed(w7);
        q8 <= $signed(r2c3) * $signed(w8);
        bias_r <= $signed(bias);
      end else if (phase == 2'd1) begin
        phase <= 2'd2;
        sum0_r <= bias_r
          + $signed(p0) + $signed(p1) + $signed(p2)
          + $signed(p3) + $signed(p4) + $signed(p5)
          + $signed(p6) + $signed(p7) + $signed(p8);
        sum1_r <= bias_r
          + $signed(q0) + $signed(q1) + $signed(q2)
          + $signed(q3) + $signed(q4) + $signed(q5)
          + $signed(q6) + $signed(q7) + $signed(q8);
      end else if (phase == 2'd2) begin
        phase <= 2'd0;
        busy <= 1'b0;
        valid <= 1'b1;
        result0 <= sum0_r;
        result1 <= sum1_r;
        out_count <= out_count + 32'd2;
        if (sum0_r[31]) begin
          relu8_0 <= 8'd0;
        end else if (sum0_r > 32'sd255) begin
          relu8_0 <= 8'd255;
        end else begin
          relu8_0 <= sum0_r[7:0];
        end
        if (sum1_r[31]) begin
          relu8_1 <= 8'd0;
        end else if (sum1_r > 32'sd255) begin
          relu8_1 <= 8'd255;
        end else begin
          relu8_1 <= sum1_r[7:0];
        end
      end
    end
  end
endmodule
