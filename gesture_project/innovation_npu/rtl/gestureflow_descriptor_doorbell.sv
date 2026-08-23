// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Small 7020-only descriptor queue.  It is intentionally not a scalar CPU,
// RVV frontend, ROB, or VME command processor.  PS writes up to four compact
// layer/tile descriptors, then rings one doorbell.  The PL emits descriptors
// autonomously to a reusable backend and exposes completion/fault counters.
`timescale 1ns/1ps
module gestureflow_descriptor_doorbell #(
  parameter int DEPTH = 4
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [31:0] s_axi_awaddr,
  input  logic s_axi_awvalid,
  output logic s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0] s_axi_wstrb,
  input  logic s_axi_wvalid,
  output logic s_axi_wready,
  output logic [1:0] s_axi_bresp,
  output logic s_axi_bvalid,
  input  logic s_axi_bready,
  input  logic [31:0] s_axi_araddr,
  input logic s_axi_arvalid,
  output logic s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0] s_axi_rresp,
  output logic s_axi_rvalid,
  input logic s_axi_rready,
  output logic desc_valid,
  input logic desc_ready,
  input logic backend_done,
  input logic backend_fault,
  output logic [31:0] desc_input_addr,
  output logic [31:0] desc_output_addr,
  output logic [31:0] desc_weight_addr,
  output logic [15:0] desc_width,
  output logic [15:0] desc_height,
  output logic [15:0] desc_cin,
  output logic [15:0] desc_cout,
  output logic [7:0] desc_flags,
  output logic busy,
  output logic done,
  output logic fault,
  output logic [31:0] issued_count,
  output logic [31:0] completed_count
);
  localparam logic [11:0] MAGIC=12'h000, VERSION=12'h004, CONTROL=12'h008,
    STATUS=12'h00c, DESC_INDEX=12'h010, INPUT_ADDR=12'h014,
    OUTPUT_ADDR=12'h018, WEIGHT_ADDR=12'h01c, SHAPE=12'h020,
    FLAGS=12'h024, COUNTS=12'h028;
  localparam logic [31:0] MAGIC_VALUE = 32'h47464442;
  localparam int IW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

  logic [IW-1:0] write_index, read_index;
  logic [IW:0] queued, descriptor_count;
  logic valid_mem [0:DEPTH-1];
  logic [31:0] input_mem [0:DEPTH-1], output_mem [0:DEPTH-1], weight_mem [0:DEPTH-1];
  logic [15:0] width_mem [0:DEPTH-1], height_mem [0:DEPTH-1];
  logic [15:0] cin_mem [0:DEPTH-1], cout_mem [0:DEPTH-1];
  logic [7:0] flags_mem [0:DEPTH-1];
  logic [31:0] awaddr, wdata, araddr;
  logic [3:0] wstrb;
  logic aw_seen, w_seen;
  logic armed, backend_active, finish_pending;

  assign s_axi_awready = !aw_seen && !s_axi_bvalid;
  assign s_axi_wready = !w_seen && !s_axi_bvalid;
  assign s_axi_arready = !s_axi_rvalid;
  assign busy = armed || (queued != 0) || backend_active;
  assign desc_valid = armed && (queued != 0) && !backend_active;
  assign desc_input_addr = input_mem[read_index];
  assign desc_output_addr = output_mem[read_index];
  assign desc_weight_addr = weight_mem[read_index];
  assign desc_width = width_mem[read_index];
  assign desc_height = height_mem[read_index];
  assign desc_cin = cin_mem[read_index];
  assign desc_cout = cout_mem[read_index];
  assign desc_flags = flags_mem[read_index];

  function automatic logic [IW-1:0] inc_index(input logic [IW-1:0] value);
    if (value == IW'(DEPTH-1)) inc_index = '0;
    else inc_index = value + 1'b1;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      awaddr <= 0; wdata <= 0; wstrb <= 0; araddr <= 0;
      aw_seen <= 0; w_seen <= 0; s_axi_bvalid <= 0; s_axi_bresp <= 0;
      s_axi_rvalid <= 0; s_axi_rresp <= 0; s_axi_rdata <= 0;
      write_index <= 0; read_index <= 0; queued <= 0; descriptor_count <= 0; armed <= 0;
      backend_active <= 0; finish_pending <= 0;
      done <= 0; fault <= 0; issued_count <= 0; completed_count <= 0;
      for (int i = 0; i < DEPTH; i++) valid_mem[i] <= 1'b0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin awaddr <= s_axi_awaddr; aw_seen <= 1; end
      if (s_axi_wvalid && s_axi_wready) begin wdata <= s_axi_wdata; wstrb <= s_axi_wstrb; w_seen <= 1; end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;

      if (desc_valid && desc_ready) begin
        read_index <= inc_index(read_index);
        queued <= queued - 1'b1;
        issued_count <= issued_count + 1'b1;
        backend_active <= 1'b1;
        finish_pending <= (queued == 1);
      end

      if (backend_done) begin
        if (!backend_active) begin
          fault <= 1'b1;
        end else begin
          backend_active <= 1'b0;
          completed_count <= completed_count + 1'b1;
          if (backend_fault) begin
            fault <= 1'b1;
            armed <= 1'b0;
            queued <= '0;
          end else if (finish_pending) begin
            armed <= 1'b0;
            done <= 1'b1;
          end
          finish_pending <= 1'b0;
        end
      end

      if (aw_seen && w_seen && !s_axi_bvalid) begin
        case (awaddr[11:0])
          DESC_INDEX: if (wdata < DEPTH) write_index <= wdata[IW-1:0]; else fault <= 1;
          INPUT_ADDR: if (!armed) input_mem[write_index] <= wdata; else fault <= 1;
          OUTPUT_ADDR: if (!armed) output_mem[write_index] <= wdata; else fault <= 1;
          WEIGHT_ADDR: if (!armed) weight_mem[write_index] <= wdata; else fault <= 1;
          SHAPE: if (!armed) begin width_mem[write_index] <= wdata[15:0]; height_mem[write_index] <= wdata[31:16]; end else fault <= 1;
          FLAGS: if (!armed) begin
            cin_mem[write_index] <= wdata[15:0]; cout_mem[write_index] <= wdata[31:16];
            flags_mem[write_index] <= wstrb[0] ? wdata[7:0] : flags_mem[write_index];
            if (!valid_mem[write_index]) begin
              valid_mem[write_index] <= 1'b1;
              descriptor_count <= descriptor_count + 1'b1;
            end
          end else fault <= 1;
          CONTROL: begin
            if (wdata[0]) begin
              armed <= 0; queued <= 0; descriptor_count <= 0; read_index <= 0; done <= 0; fault <= 0;
              backend_active <= 0; finish_pending <= 0;
              for (int i = 0; i < DEPTH; i++) valid_mem[i] <= 1'b0;
            end
            if (wdata[1]) begin
              if (armed || queued != 0) fault <= 1;
              else if (descriptor_count == 0) fault <= 1;
              else begin armed <= 1; read_index <= 0; queued <= descriptor_count; done <= 0; end
            end
          end
          default: begin end
        endcase
        s_axi_bvalid <= 1; s_axi_bresp <= 0; aw_seen <= 0; w_seen <= 0;
      end

      if (s_axi_arvalid && s_axi_arready) begin
        araddr <= s_axi_araddr;
        case (s_axi_araddr[11:0])
          MAGIC: s_axi_rdata <= MAGIC_VALUE;
          VERSION: s_axi_rdata <= 32'h00010000;
          STATUS: s_axi_rdata <= {28'd0, fault, done, busy, (queued != 0)};
          DESC_INDEX: s_axi_rdata <= {{(32-IW){1'b0}}, write_index};
          COUNTS: s_axi_rdata <= completed_count;
          default: s_axi_rdata <= 32'hdeadbeef;
        endcase
        s_axi_rvalid <= 1; s_axi_rresp <= 0;
      end
    end
  end

endmodule
