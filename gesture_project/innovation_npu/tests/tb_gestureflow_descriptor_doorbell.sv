// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_descriptor_doorbell;
  logic clk=0, rst_n=0; always #5 clk=~clk;
  logic [31:0] awaddr,wdata,araddr,rdata; logic [3:0] wstrb=4'hf;
  logic awvalid=0,wvalid=0,arvalid=0,bready=1,rready=1,awready,wready,arready,bvalid,rvalid;
  logic [1:0] bresp,rresp; logic desc_valid,desc_ready=1,busy,done,fault;
  logic [31:0] di,do_,dw,issued,completed; logic [15:0] width,height,cin,cout; logic [7:0] flags;
  logic backend_done=0, backend_fault=0; integer backend_delay=0;
  logic s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
  logic [1:0] s_axi_bresp, s_axi_rresp;
  logic [31:0] s_axi_rdata;
  logic [31:0] desc_input_addr, desc_output_addr, desc_weight_addr;
  logic [15:0] desc_width, desc_height, desc_cin, desc_cout;
  logic [7:0] desc_flags;
  logic [31:0] issued_count, completed_count;
  assign wready = s_axi_wready;
  assign bvalid = s_axi_bvalid;
  assign arready = s_axi_arready;
  assign rvalid = s_axi_rvalid;
  assign rdata = s_axi_rdata;
  assign bresp = s_axi_bresp;
  assign rresp = s_axi_rresp;
  assign di = desc_input_addr;
  assign do_ = desc_output_addr;
  assign dw = desc_weight_addr;
  assign width = desc_width;
  assign height = desc_height;
  assign cin = desc_cin;
  assign cout = desc_cout;
  assign flags = desc_flags;
  assign issued = issued_count;
  assign completed = completed_count;
  gestureflow_descriptor_doorbell dut (
    .clk, .rst_n,
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(rready),
    .desc_valid, .desc_ready, .backend_done, .backend_fault,
    .desc_input_addr, .desc_output_addr, .desc_weight_addr,
    .desc_width, .desc_height, .desc_cin, .desc_cout, .desc_flags,
    .busy, .done, .fault, .issued_count, .completed_count
  );

  task automatic wr(input [11:0] address, input [31:0] value);
    begin
      @(posedge clk); awaddr = {{20{1'b0}}, address}; wdata = value; awvalid = 1; wvalid = 1;
      while (!(awready && wready)) @(posedge clk);
      @(posedge clk); awvalid = 0; wvalid = 0;
      while (bvalid) @(posedge clk);
    end
  endtask

  always_ff @(posedge clk) begin
    backend_done <= 0;
    if (rst_n && desc_valid && desc_ready) backend_delay <= 2;
    else if (backend_delay != 0) begin
      backend_delay <= backend_delay - 1;
      if (backend_delay == 1) backend_done <= 1;
    end
  end

  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    wr(12'h010,0); wr(12'h014,32'h1000); wr(12'h018,32'h2000); wr(12'h01c,32'h3000); wr(12'h020,{16'd96,16'd96}); wr(12'h024,{16'd16,16'd3});
    wr(12'h010,1); wr(12'h014,32'h4000); wr(12'h018,32'h5000); wr(12'h01c,32'h6000); wr(12'h020,{16'd48,16'd48}); wr(12'h024,{16'd40,16'd16});
    wr(12'h008,32'h2);
    for (int n=0;n<200;n++) begin @(posedge clk); if (desc_valid) begin $display("DESC %0d in=%08x out=%08x w=%08x", issued,di,do_,dw); end if (done && completed==2) begin $display("GESTUREFLOW_DESCRIPTOR_DOORBELL_PASS issued=%0d completed=%0d",issued,completed); $finish; end end
    $fatal(1,"descriptor timeout issued=%0d completed=%0d busy=%0d fault=%0d",issued,completed,busy,fault);
  end
endmodule
