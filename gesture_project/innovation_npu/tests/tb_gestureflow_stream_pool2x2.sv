// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_stream_pool2x2;
  localparam int W = 4;
  localparam int H = 4;
  localparam int L = 2; // two signed lanes

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic frame_start = 1'b0;
  logic vector_valid = 1'b0;
  logic vector_ready;
  logic signed [L-1:0][7:0] vector_data = '0;
  logic [15:0] image_width = W;
  logic [15:0] image_height = H;
  logic pooled_valid;
  logic pooled_ready = 1'b1;
  logic signed [L-1:0][7:0] pooled_data;
  logic pooled_last;

  // input[y][x] = two lanes (lane0, lane1)
  localparam int IN [0:H-1][0:W-1][0:L-1] = '{
    '{'{1, 10}, '{2, 9}, '{3, 8}, '{4, 7}},
    '{'{5, 6}, '{6, 5}, '{7, 4}, '{8, 3}},
    '{'{9, 2}, '{10, 1}, '{11, 0}, '{12, -1}},
    '{'{13, -2}, '{14, -3}, '{15, -4}, '{16, -5}}
  };

  gestureflow_stream_pool2x2 #(.VECTOR_BYTES(L), .MAX_WIDTH(W)) dut (
    .clk(clk), .rst_n(rst_n), .frame_start(frame_start),
    .vector_valid(vector_valid), .vector_ready(vector_ready), .vector_data(vector_data),
    .image_width(image_width), .image_height(image_height),
    .pooled_valid(pooled_valid), .pooled_ready(pooled_ready), .pooled_data(pooled_data),
    .pooled_last(pooled_last)
  );

  always #5 clk = ~clk;

  integer emitted = 0;
  integer errors = 0;

  always @(posedge clk) begin
    if (pooled_valid && pooled_ready) begin
      int ox = (emitted % (W/2));
      int oy = (emitted / (W/2));
      int expected0 = IN[2*oy][2*ox][0];
      int expected1 = IN[2*oy][2*ox][1];
      for (int dx = 0; dx < 2; dx++) for (int dy = 0; dy < 2; dy++) begin
        if (IN[2*oy+dy][2*ox+dx][0] > expected0) expected0 = IN[2*oy+dy][2*ox+dx][0];
        if (IN[2*oy+dy][2*ox+dx][1] > expected1) expected1 = IN[2*oy+dy][2*ox+dx][1];
      end
      if ($signed(pooled_data[0]) != expected0 || $signed(pooled_data[1]) != expected1) begin
        $display("MISMATCH emitted=%0d ox=%0d oy=%0d got=(%0d,%0d) exp=(%0d,%0d)",
          emitted, ox, oy, $signed(pooled_data[0]), $signed(pooled_data[1]), expected0, expected1);
        errors = errors + 1;
      end
      emitted = emitted + 1;
    end
  end

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    frame_start = 1'b1;
    @(negedge clk);
    frame_start = 1'b0;
    for (int y = 0; y < H; y++) begin
      for (int x = 0; x < W; x++) begin
        while (!vector_ready) @(negedge clk);
        vector_data[0] = IN[y][x][0];
        vector_data[1] = IN[y][x][1];
        vector_valid = 1'b1;
        @(negedge clk);
        vector_valid = 1'b0;
      end
    end
    for (int w = 0; w < 100 && emitted < (H/2)*(W/2); w++) @(negedge clk);
    if (emitted != (H/2)*(W/2) || errors != 0) $fatal(1, "pool failed emitted=%0d errors=%0d", emitted, errors);
    $display("GESTUREFLOW_STREAM_POOL2X2_PASS emitted=%0d", emitted);
    $finish;
  end
endmodule
