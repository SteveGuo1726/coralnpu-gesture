// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_conv4x4_cin_stream;
logic clk=0,rst_n=0,frame_start=0,pixel_valid=0,pixel_ready,weight_write_valid=0,output_valid,output_ready=1,busy,protocol_error;
logic signed [7:0][7:0] pixel_data; logic [0:0] weight_write_oc; logic [3:0] weight_write_tap; logic [0:0] weight_write_ic_group; logic signed [3:0][7:0] weight_write_data; logic signed [1:0][31:0] bias; logic [1:0] output_lane_enable=2'b01,output_lane_enable_valid; logic signed [1:0][31:0] output_psum;
gestureflow_conv4x4_cin_stream #(.IMAGE_WIDTH(4),.INPUT_CHANNELS(8),.OUT_LANES(2)) dut(.*); always #5 clk=~clk;
task automatic w(input int t,input int g); begin @(negedge clk); weight_write_valid=1;weight_write_oc=0;weight_write_tap=4'(t);weight_write_ic_group=1'(g);weight_write_data='{default:8'sd1};@(negedge clk);weight_write_valid=0;end endtask
initial begin pixel_data='0;weight_write_oc=0;weight_write_tap=0;weight_write_ic_group=0;weight_write_data='0;bias='0;bias[0]=7;repeat(3)@(negedge clk);rst_n=1;for(int t=0;t<16;t++)for(int g=0;g<2;g++)w(t,g);@(negedge clk);frame_start=1;@(negedge clk);frame_start=0;for(int p=0;p<16;p++)begin while(!pixel_ready)@(negedge clk);pixel_data='{default:8'sd1};pixel_valid=1;@(negedge clk);pixel_valid=0;end for(int n=0;n<200&&!output_valid;n++)@(negedge clk);if(!output_valid||output_psum[0]!==32'sd135||output_lane_enable_valid!==2'b01||protocol_error)$fatal(1,"Cin8 got %0d",output_psum[0]);$display("GESTUREFLOW_CONV4X4_CIN_STREAM_PASS psum=%0d",output_psum[0]);$finish;end
endmodule
