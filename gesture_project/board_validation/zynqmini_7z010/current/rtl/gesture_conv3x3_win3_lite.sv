module GestureSignedMul8x8Dsp (
  input  wire               clock,
  input  wire               reset,
  input  wire               clear,
  input  wire signed [7:0]  a,
  input  wire signed [7:0]  b,
  output reg  signed [17:0] p
);
  wire signed [17:0] a_ext = {{10{a[7]}}, a};
  wire signed [17:0] b_ext = {{10{b[7]}}, b};
  (* use_dsp = "yes" *) wire signed [35:0] prod_full = a_ext * b_ext;

  always @(posedge clock or posedge reset) begin
    if (reset) begin
      p <= 18'sd0;
    end else if (clear) begin
      p <= 18'sd0;
    end else begin
      p <= prod_full[17:0];
    end
  end
endmodule

module GestureConv3x3Win3Lite (
  input  wire        clock,
  input  wire        reset,
  input  wire        start,
  input  wire        clear,
  input  wire [31:0] row0_lo,
  input  wire [31:0] row0_hi,
  input  wire [31:0] row1_lo,
  input  wire [31:0] row1_hi,
  input  wire [31:0] row2_lo,
  input  wire [31:0] row2_hi,
  input  wire [31:0] wgt0,
  input  wire [31:0] wgt1,
  input  wire [31:0] wgt2,
  input  wire [31:0] bias,
  output reg         busy,
  output reg         valid,
  output reg  [31:0] result0,
  output reg  [31:0] result1,
  output reg  [31:0] result2,
  output reg  [7:0]  relu8_0,
  output reg  [7:0]  relu8_1,
  output reg  [7:0]  relu8_2,
  output reg  [31:0] out_count
);
  localparam [2:0] PHASE_IDLE          = 3'd0;
  localparam [2:0] PHASE_LOAD_WIN1     = 3'd1;
  localparam [2:0] PHASE_PARTIAL_WIN0  = 3'd2;
  localparam [2:0] PHASE_SUM0_PARTIAL1 = 3'd3;
  localparam [2:0] PHASE_SUM1_PARTIAL2 = 3'd4;
  localparam [2:0] PHASE_SUM2          = 3'd5;
  localparam [2:0] PHASE_OUTPUT        = 3'd6;

  wire signed [7:0] r0c0 = row0_lo[7:0];
  wire signed [7:0] r0c1 = row0_lo[15:8];
  wire signed [7:0] r0c2 = row0_lo[23:16];
  wire signed [7:0] r0c3 = row0_lo[31:24];
  wire signed [7:0] r0c4 = row0_hi[7:0];
  wire signed [7:0] r1c0 = row1_lo[7:0];
  wire signed [7:0] r1c1 = row1_lo[15:8];
  wire signed [7:0] r1c2 = row1_lo[23:16];
  wire signed [7:0] r1c3 = row1_lo[31:24];
  wire signed [7:0] r1c4 = row1_hi[7:0];
  wire signed [7:0] r2c0 = row2_lo[7:0];
  wire signed [7:0] r2c1 = row2_lo[15:8];
  wire signed [7:0] r2c2 = row2_lo[23:16];
  wire signed [7:0] r2c3 = row2_lo[31:24];
  wire signed [7:0] r2c4 = row2_hi[7:0];

  reg [31:0] row0_lo_q;
  reg [31:0] row0_hi_q;
  reg [31:0] row1_lo_q;
  reg [31:0] row1_hi_q;
  reg [31:0] row2_lo_q;
  reg [31:0] row2_hi_q;
  reg [31:0] wgt0_q;
  reg [31:0] wgt1_q;
  reg [31:0] wgt2_q;

  wire signed [7:0] r0c0_q = row0_lo_q[7:0];
  wire signed [7:0] r0c1_q = row0_lo_q[15:8];
  wire signed [7:0] r0c2_q = row0_lo_q[23:16];
  wire signed [7:0] r0c3_q = row0_lo_q[31:24];
  wire signed [7:0] r0c4_q = row0_hi_q[7:0];
  wire signed [7:0] r1c0_q = row1_lo_q[7:0];
  wire signed [7:0] r1c1_q = row1_lo_q[15:8];
  wire signed [7:0] r1c2_q = row1_lo_q[23:16];
  wire signed [7:0] r1c3_q = row1_lo_q[31:24];
  wire signed [7:0] r1c4_q = row1_hi_q[7:0];
  wire signed [7:0] r2c0_q = row2_lo_q[7:0];
  wire signed [7:0] r2c1_q = row2_lo_q[15:8];
  wire signed [7:0] r2c2_q = row2_lo_q[23:16];
  wire signed [7:0] r2c3_q = row2_lo_q[31:24];
  wire signed [7:0] r2c4_q = row2_hi_q[7:0];

  wire signed [7:0] w0_q = wgt0_q[7:0];
  wire signed [7:0] w1_q = wgt0_q[15:8];
  wire signed [7:0] w2_q = wgt0_q[23:16];
  wire signed [7:0] w3_q = wgt0_q[31:24];
  wire signed [7:0] w4_q = wgt1_q[7:0];
  wire signed [7:0] w5_q = wgt1_q[15:8];
  wire signed [7:0] w6_q = wgt1_q[23:16];
  wire signed [7:0] w7_q = wgt1_q[31:24];
  wire signed [7:0] w8_q = wgt2_q[7:0];

  reg [2:0] phase;
  reg signed [7:0] mul_a0;
  reg signed [7:0] mul_a1;
  reg signed [7:0] mul_a2;
  reg signed [7:0] mul_a3;
  reg signed [7:0] mul_a4;
  reg signed [7:0] mul_a5;
  reg signed [7:0] mul_a6;
  reg signed [7:0] mul_a7;
  reg signed [7:0] mul_a8;
  reg signed [7:0] mul_b0;
  reg signed [7:0] mul_b1;
  reg signed [7:0] mul_b2;
  reg signed [7:0] mul_b3;
  reg signed [7:0] mul_b4;
  reg signed [7:0] mul_b5;
  reg signed [7:0] mul_b6;
  reg signed [7:0] mul_b7;
  reg signed [7:0] mul_b8;

  wire signed [17:0] p0;
  wire signed [17:0] p1;
  wire signed [17:0] p2;
  wire signed [17:0] p3;
  wire signed [17:0] p4;
  wire signed [17:0] p5;
  wire signed [17:0] p6;
  wire signed [17:0] p7;
  wire signed [17:0] p8;

  reg signed [18:0] pair01_r;
  reg signed [18:0] pair23_r;
  reg signed [18:0] pair45_r;
  reg signed [18:0] pair67_r;
  reg signed [17:0] tail_r;
  reg signed [31:0] bias_r;
  reg signed [31:0] sum0_r;
  reg signed [31:0] sum1_r;
  reg signed [31:0] sum2_r;

  function [7:0] relu8_sat;
    input signed [31:0] value;
    begin
      if (value[31]) begin
        relu8_sat = 8'd0;
      end else if (value > 32'sd255) begin
        relu8_sat = 8'd255;
      end else begin
        relu8_sat = value[7:0];
      end
    end
  endfunction

  task automatic clear_mul_inputs;
    begin
      mul_a0 <= 8'sd0; mul_b0 <= 8'sd0;
      mul_a1 <= 8'sd0; mul_b1 <= 8'sd0;
      mul_a2 <= 8'sd0; mul_b2 <= 8'sd0;
      mul_a3 <= 8'sd0; mul_b3 <= 8'sd0;
      mul_a4 <= 8'sd0; mul_b4 <= 8'sd0;
      mul_a5 <= 8'sd0; mul_b5 <= 8'sd0;
      mul_a6 <= 8'sd0; mul_b6 <= 8'sd0;
      mul_a7 <= 8'sd0; mul_b7 <= 8'sd0;
      mul_a8 <= 8'sd0; mul_b8 <= 8'sd0;
    end
  endtask

  task automatic load_mul_inputs_win0;
    begin
      mul_a0 <= r0c0;   mul_b0 <= wgt0[7:0];
      mul_a1 <= r0c1;   mul_b1 <= wgt0[15:8];
      mul_a2 <= r0c2;   mul_b2 <= wgt0[23:16];
      mul_a3 <= r1c0;   mul_b3 <= wgt0[31:24];
      mul_a4 <= r1c1;   mul_b4 <= wgt1[7:0];
      mul_a5 <= r1c2;   mul_b5 <= wgt1[15:8];
      mul_a6 <= r2c0;   mul_b6 <= wgt1[23:16];
      mul_a7 <= r2c1;   mul_b7 <= wgt1[31:24];
      mul_a8 <= r2c2;   mul_b8 <= wgt2[7:0];
    end
  endtask

  task automatic load_mul_inputs_win1;
    begin
      mul_a0 <= r0c1_q; mul_b0 <= w0_q;
      mul_a1 <= r0c2_q; mul_b1 <= w1_q;
      mul_a2 <= r0c3_q; mul_b2 <= w2_q;
      mul_a3 <= r1c1_q; mul_b3 <= w3_q;
      mul_a4 <= r1c2_q; mul_b4 <= w4_q;
      mul_a5 <= r1c3_q; mul_b5 <= w5_q;
      mul_a6 <= r2c1_q; mul_b6 <= w6_q;
      mul_a7 <= r2c2_q; mul_b7 <= w7_q;
      mul_a8 <= r2c3_q; mul_b8 <= w8_q;
    end
  endtask

  task automatic load_mul_inputs_win2;
    begin
      mul_a0 <= r0c2_q; mul_b0 <= w0_q;
      mul_a1 <= r0c3_q; mul_b1 <= w1_q;
      mul_a2 <= r0c4_q; mul_b2 <= w2_q;
      mul_a3 <= r1c2_q; mul_b3 <= w3_q;
      mul_a4 <= r1c3_q; mul_b4 <= w4_q;
      mul_a5 <= r1c4_q; mul_b5 <= w5_q;
      mul_a6 <= r2c2_q; mul_b6 <= w6_q;
      mul_a7 <= r2c3_q; mul_b7 <= w7_q;
      mul_a8 <= r2c4_q; mul_b8 <= w8_q;
    end
  endtask

  GestureSignedMul8x8Dsp mul0 (.clock(clock), .reset(reset), .clear(clear), .a(mul_a0), .b(mul_b0), .p(p0));
  GestureSignedMul8x8Dsp mul1 (.clock(clock), .reset(reset), .clear(clear), .a(mul_a1), .b(mul_b1), .p(p1));
  GestureSignedMul8x8Dsp mul2 (.clock(clock), .reset(reset), .clear(clear), .a(mul_a2), .b(mul_b2), .p(p2));
  GestureSignedMul8x8Dsp mul3 (.clock(clock), .reset(reset), .clear(clear), .a(mul_a3), .b(mul_b3), .p(p3));
  GestureSignedMul8x8Dsp mul4 (.clock(clock), .reset(reset), .clear(clear), .a(mul_a4), .b(mul_b4), .p(p4));
  GestureSignedMul8x8Dsp mul5 (.clock(clock), .reset(reset), .clear(clear), .a(mul_a5), .b(mul_b5), .p(p5));
  GestureSignedMul8x8Dsp mul6 (.clock(clock), .reset(reset), .clear(clear), .a(mul_a6), .b(mul_b6), .p(p6));
  GestureSignedMul8x8Dsp mul7 (.clock(clock), .reset(reset), .clear(clear), .a(mul_a7), .b(mul_b7), .p(p7));
  GestureSignedMul8x8Dsp mul8 (.clock(clock), .reset(reset), .clear(clear), .a(mul_a8), .b(mul_b8), .p(p8));

  always @(posedge clock or posedge reset) begin
    if (reset) begin
      phase <= PHASE_IDLE;
      busy <= 1'b0;
      valid <= 1'b0;
      result0 <= 32'd0;
      result1 <= 32'd0;
      result2 <= 32'd0;
      relu8_0 <= 8'd0;
      relu8_1 <= 8'd0;
      relu8_2 <= 8'd0;
      out_count <= 32'd0;
      row0_lo_q <= 32'd0;
      row0_hi_q <= 32'd0;
      row1_lo_q <= 32'd0;
      row1_hi_q <= 32'd0;
      row2_lo_q <= 32'd0;
      row2_hi_q <= 32'd0;
      wgt0_q <= 32'd0;
      wgt1_q <= 32'd0;
      wgt2_q <= 32'd0;
      pair01_r <= 19'sd0;
      pair23_r <= 19'sd0;
      pair45_r <= 19'sd0;
      pair67_r <= 19'sd0;
      tail_r <= 18'sd0;
      bias_r <= 32'sd0;
      sum0_r <= 32'sd0;
      sum1_r <= 32'sd0;
      sum2_r <= 32'sd0;
      clear_mul_inputs();
    end else begin
      valid <= 1'b0;
      if (clear) begin
        phase <= PHASE_IDLE;
        busy <= 1'b0;
        result0 <= 32'd0;
        result1 <= 32'd0;
        result2 <= 32'd0;
        relu8_0 <= 8'd0;
        relu8_1 <= 8'd0;
        relu8_2 <= 8'd0;
        out_count <= 32'd0;
        row0_lo_q <= 32'd0;
        row0_hi_q <= 32'd0;
        row1_lo_q <= 32'd0;
        row1_hi_q <= 32'd0;
        row2_lo_q <= 32'd0;
        row2_hi_q <= 32'd0;
        wgt0_q <= 32'd0;
        wgt1_q <= 32'd0;
        wgt2_q <= 32'd0;
        pair01_r <= 19'sd0;
        pair23_r <= 19'sd0;
        pair45_r <= 19'sd0;
        pair67_r <= 19'sd0;
        tail_r <= 18'sd0;
        bias_r <= 32'sd0;
        sum0_r <= 32'sd0;
        sum1_r <= 32'sd0;
        sum2_r <= 32'sd0;
        clear_mul_inputs();
      end else begin
        case (phase)
          PHASE_IDLE: begin
            if (start) begin
              phase <= PHASE_LOAD_WIN1;
              busy <= 1'b1;
              row0_lo_q <= row0_lo;
              row0_hi_q <= row0_hi;
              row1_lo_q <= row1_lo;
              row1_hi_q <= row1_hi;
              row2_lo_q <= row2_lo;
              row2_hi_q <= row2_hi;
              wgt0_q <= wgt0;
              wgt1_q <= wgt1;
              wgt2_q <= wgt2;
              bias_r <= $signed(bias);
              pair01_r <= 19'sd0;
              pair23_r <= 19'sd0;
              pair45_r <= 19'sd0;
              pair67_r <= 19'sd0;
              tail_r <= 18'sd0;
              sum0_r <= 32'sd0;
              sum1_r <= 32'sd0;
              sum2_r <= 32'sd0;
              load_mul_inputs_win0();
            end
          end

          PHASE_LOAD_WIN1: begin
            phase <= PHASE_PARTIAL_WIN0;
            load_mul_inputs_win1();
          end

          PHASE_PARTIAL_WIN0: begin
            phase <= PHASE_SUM0_PARTIAL1;
            pair01_r <= $signed(p0) + $signed(p1);
            pair23_r <= $signed(p2) + $signed(p3);
            pair45_r <= $signed(p4) + $signed(p5);
            pair67_r <= $signed(p6) + $signed(p7);
            tail_r <= p8;
            load_mul_inputs_win2();
          end

          PHASE_SUM0_PARTIAL1: begin
            phase <= PHASE_SUM1_PARTIAL2;
            sum0_r <= bias_r
              + $signed(pair01_r) + $signed(pair23_r)
              + $signed(pair45_r) + $signed(pair67_r)
              + $signed(tail_r);
            pair01_r <= $signed(p0) + $signed(p1);
            pair23_r <= $signed(p2) + $signed(p3);
            pair45_r <= $signed(p4) + $signed(p5);
            pair67_r <= $signed(p6) + $signed(p7);
            tail_r <= p8;
            clear_mul_inputs();
          end

          PHASE_SUM1_PARTIAL2: begin
            phase <= PHASE_SUM2;
            sum1_r <= bias_r
              + $signed(pair01_r) + $signed(pair23_r)
              + $signed(pair45_r) + $signed(pair67_r)
              + $signed(tail_r);
            pair01_r <= $signed(p0) + $signed(p1);
            pair23_r <= $signed(p2) + $signed(p3);
            pair45_r <= $signed(p4) + $signed(p5);
            pair67_r <= $signed(p6) + $signed(p7);
            tail_r <= p8;
          end

          PHASE_SUM2: begin
            phase <= PHASE_OUTPUT;
            sum2_r <= bias_r
              + $signed(pair01_r) + $signed(pair23_r)
              + $signed(pair45_r) + $signed(pair67_r)
              + $signed(tail_r);
          end

          PHASE_OUTPUT: begin
            phase <= PHASE_IDLE;
            busy <= 1'b0;
            valid <= 1'b1;
            result0 <= sum0_r;
            result1 <= sum1_r;
            result2 <= sum2_r;
            relu8_0 <= relu8_sat(sum0_r);
            relu8_1 <= relu8_sat(sum1_r);
            relu8_2 <= relu8_sat(sum2_r);
            out_count <= out_count + 32'd3;
          end

          default: begin
            phase <= PHASE_IDLE;
            busy <= 1'b0;
            clear_mul_inputs();
          end
        endcase
      end
    end
  end
endmodule
