// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_hp0_rgb_loader;
  logic clk=0, rst_n=0, start=0, clear=0, pixel_ready=0;
  logic [31:0] source_addr=32'h1000, araddr;
  logic [15:0] byte_count=24, bytes_read;
  logic [13:0] pixel_count=8, pixels_emitted;
  logic busy, done, fault, frame_start, pixel_valid;
  logic signed [2:0][7:0] pixel_rgb;
  logic [5:0] arid, rid; logic [7:0] arlen; logic [2:0] arsize, arprot;
  logic [1:0] arburst, rresp; logic arlock, arvalid, arready, rlast, rvalid, rready;
  logic [3:0] arcache, arqos, arregion; logic [63:0] rdata;
  logic [63:0] memory [0:2]; logic active; logic [1:0] beat_index, beats_left;
  integer received;
  logic ready_phase=0;
  always #5 clk=~clk;
  gestureflow_hp0_rgb_loader dut (.*,
    .m_axi_araddr(araddr), .m_axi_arid(arid), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
    .m_axi_arburst(arburst), .m_axi_arlock(arlock), .m_axi_arcache(arcache),
    .m_axi_arprot(arprot), .m_axi_arqos(arqos), .m_axi_arregion(arregion),
    .m_axi_arvalid(arvalid), .m_axi_arready(arready), .m_axi_rid(rid),
    .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid), .m_axi_rready(rready));
  assign arready=!active;
  always_ff @(posedge clk) begin
    if(!rst_n) begin active<=0; beat_index<=0; beats_left<=0; rvalid<=0; rlast<=0; rdata<=0; rid<=0; rresp<=0; end
    else if(!active && arvalid && arready) begin
      if(araddr!=32'h1000 || arlen!=2 || arsize!=3 || arburst!=1) $fatal(1,"bad AXI request");
      active<=1; beat_index<=0; beats_left<=3; rid<=arid; rdata<=memory[0]; rlast<=0; rvalid<=1;
    end else if(active && rvalid && rready) begin
      if(beats_left==1) begin active<=0; rvalid<=0; rlast<=0; end
      else begin beat_index<=beat_index+1; beats_left<=beats_left-1; rdata<=memory[beat_index+1]; rlast<=(beats_left==2); end
    end
  end
  // Exercise recoverable downstream backpressure without permanently
  // suppressing the next RGB pixel after a successful transfer.
  always @(negedge clk) begin ready_phase <= ~ready_phase; pixel_ready <= ready_phase; end
  always_ff @(posedge clk) if(rst_n && pixel_valid && pixel_ready) begin
    if(($signed(pixel_rgb[0]) != (received - 128)) ||
       ($signed(pixel_rgb[1]) != (received + 1 - 128)) ||
       ($signed(pixel_rgb[2]) != (received + 2 - 128))) $fatal(1,"pixel %0d mismatch",received);
    received <= received+3;
  end
  initial begin
    for(int i=0;i<3;i++) for(int b=0;b<8;b++) memory[i][b*8 +: 8] = i*8+b;
    received=0;
    repeat(3) @(negedge clk); rst_n=1; @(negedge clk); start=1; @(negedge clk); start=0;
    for(int t=0;t<500;t++) begin @(negedge clk); if(done) break; if(fault) $fatal(1,"loader fault"); end
    if(!done || received!=24 || pixels_emitted!=8 || bytes_read!=24) $fatal(1,"loader incomplete done=%b bytes=%0d pixels=%0d received=%0d",done,bytes_read,pixels_emitted,received);
    $display("GESTUREFLOW_HP0_RGB_LOADER_PASS bytes=%0d pixels=%0d",bytes_read,pixels_emitted); $finish;
  end
endmodule
