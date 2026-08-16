// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_conv4x4_rgb_same_layer;
  logic clk=0,rst_n=0,frame_start=0,pixel_valid=0,pixel_ready;
  logic signed [2:0][7:0] pixel_rgb;
  logic weight_write_valid=0; logic [0:0] weight_write_oc; logic [3:0] weight_write_tap;
  logic signed [3:0][7:0] weight_write_data; logic signed [1:0][31:0] bias;
  logic [1:0] output_lane_enable=2'b01; logic frame_input_done,layer_fault;
  logic requant_enable=0,requant_relu_enable=0; logic signed [7:0] output_zero_point=0;
  logic signed [1:0][31:0] requant_multiplier; logic [1:0][5:0] requant_right_shift;
  logic output_write_valid; logic [0:0] output_write_addr; logic signed [1:0][7:0] output_write_data;
  logic output_read_enable=0; logic [0:0] output_read_addr=0; logic [15:0] output_read_data;
  integer writes=0;
  gestureflow_conv4x4_rgb_same_layer #(.IMAGE_WIDTH(1),.IMAGE_HEIGHT(1),.OUT_LANES(2),.OUTPUT_ADDR_W(1)) dut(.*);
  always #5 clk=~clk;
  always @(posedge clk) if(output_write_valid) begin
    if(output_write_addr!==0 || output_write_data[0]!==8'sd5 || output_write_data[1]!==0) $fatal(1,"bad layer output addr=%0d data=%0d,%0d",output_write_addr,output_write_data[0],output_write_data[1]);
    writes=writes+1;
  end
  initial begin
    pixel_rgb='0;weight_write_oc=0;weight_write_tap=0;weight_write_data='0;bias='0;requant_multiplier='0;requant_right_shift='0;
    repeat(3)@(negedge clk);rst_n=1;
    for(int tap=0;tap<16;tap++) begin
      @(negedge clk);weight_write_valid=1;weight_write_tap=4'(tap);weight_write_data='0;
      if(tap==5) weight_write_data[0]=1;
      @(negedge clk);weight_write_valid=0;
    end
    @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;
    while(!pixel_ready)@(negedge clk);pixel_rgb[0]=5;pixel_valid=1;@(negedge clk);pixel_valid=0;
    for(int n=0;n<300&&writes==0;n++)@(negedge clk);
    if(writes!=1||layer_fault)$fatal(1,"layer incomplete writes=%0d fault=%b",writes,layer_fault);
    $display("GESTUREFLOW_CONV4X4_RGB_SAME_LAYER_PASS writes=%0d",writes);$finish;
  end
endmodule
