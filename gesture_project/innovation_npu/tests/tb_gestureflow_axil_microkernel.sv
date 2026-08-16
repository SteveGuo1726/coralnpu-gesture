// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_axil_microkernel;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [31:0] awaddr, wdata, araddr;
  logic [2:0] awprot, arprot;
  logic awvalid, wvalid, bready, arvalid, rready;
  logic [3:0] wstrb;
  logic awready, wready, bvalid, arready, rvalid;
  logic [1:0] bresp, rresp;
  logic [31:0] rdata;

  localparam [31:0] MAGIC = 32'h000, VERSION = 32'h004, CONTROL = 32'h008,
                    STATUS = 32'h00c, WCTRL = 32'h010, WDATA = 32'h014,
                    BIDX = 32'h018, BDATA = 32'h01c, ACTRL = 32'h020,
                    ADATA = 32'h024, RESULT_IDX = 32'h028,
                    RESULT_DATA = 32'h02c, CYCLES = 32'h030,
                    ACT_STAGE_ADDR = 32'h034, ACT_STAGE_DATA = 32'h038;

  always #5 clk = ~clk;

  gestureflow_axil_microkernel dut (
    .aclk(clk), .aresetn(rst_n),
    .s_axi_awaddr(awaddr), .s_axi_awprot(awprot), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arprot(arprot), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
  );

  task automatic axil_write(input logic [31:0] addr, input logic [31:0] data);
    begin
      @(negedge clk);
      awaddr <= addr; awprot <= '0; awvalid <= 1'b1;
      wdata <= data; wstrb <= 4'hf; wvalid <= 1'b1;
      while (!(awready && wready)) @(negedge clk);
      @(negedge clk);
      awvalid <= 1'b0; wvalid <= 1'b0;
      bready <= 1'b1;
      while (!bvalid) @(negedge clk);
      @(negedge clk);
      bready <= 1'b0;
    end
  endtask

  task automatic axil_read(input logic [31:0] addr, output logic [31:0] data);
    begin
      @(negedge clk);
      araddr <= addr; arprot <= '0; arvalid <= 1'b1;
      while (!arready) @(negedge clk);
      @(negedge clk);
      arvalid <= 1'b0; rready <= 1'b1;
      while (!rvalid) @(negedge clk);
      data = rdata;
      @(negedge clk);
      rready <= 1'b0;
    end
  endtask

  logic [31:0] value;
  integer oc;
  initial begin
    awaddr = '0; wdata = '0; araddr = '0; awprot = '0; arprot = '0;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0; wstrb = 0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    axil_read(MAGIC, value); if (value != 32'h47464e50) $fatal(1, "bad magic %h", value);
    axil_read(VERSION, value); if (value != 32'h00010001) $fatal(1, "bad version %h", value);

    // Bias each output lane with its lane number. Load every 4x4 tap/group
    // with four ones. Feeding all-one activations produces 16 groups * 4 = 64.
    for (oc = 0; oc < 16; oc = oc + 1) begin
      axil_write(BIDX, oc);
      axil_write(BDATA, oc);
      for (int tap = 0; tap < 16; tap++) begin
        for (int group = 0; group < 16; group++) begin
          axil_write(WCTRL, oc | (tap << 4) | (group << 8));
          axil_write(WDATA, 32'h01010101);
        end
      end
    end

    for (int tap = 0; tap < 16; tap++) begin
      for (int group = 0; group < 16; group++) begin
        axil_write(ACT_STAGE_ADDR, (tap << 4) | group);
        axil_write(ACT_STAGE_DATA, 32'h01010101);
      end
    end
    axil_write(CONTROL, 32'h2);
    axil_write(CONTROL, 32'h5);

    for (int wait_cycle = 0; wait_cycle < 100; wait_cycle++) begin
      axil_read(STATUS, value);
      if (value[3]) break;
      if (wait_cycle == 99) $fatal(1, "transaction never completed status=%h", value);
    end
    axil_read(STATUS, value); if (value[4]) $fatal(1, "protocol fault status=%h", value);
    axil_read(CYCLES, value); if (value == 0) $fatal(1, "cycle counter did not run");
    for (oc = 0; oc < 16; oc++) begin
      axil_write(RESULT_IDX, oc);
      axil_read(RESULT_DATA, value);
      if ($signed(value) != (1024 + oc)) $fatal(1, "lane %0d result=%0d expected=%0d", oc, $signed(value), 1024 + oc);
    end
    axil_read(RESULT_IDX, value); if (value != 16'hffff) $fatal(1, "bad result mask %h", value);
    if (dut.cycles >= 1000) $fatal(1, "staged execution did not remove host feed gap cycles=%0d", dut.cycles);
    $display("GESTUREFLOW_AXIL_MICROKERNEL_STAGED_PASS cycles=%0d lane0=%0d lane15=%0d", dut.cycles, dut.result_psum[0], dut.result_psum[15]);
    $finish;
  end
endmodule
