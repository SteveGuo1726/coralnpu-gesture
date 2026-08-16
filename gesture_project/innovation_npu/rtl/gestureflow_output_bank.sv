// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// A tile-local INT8 output store. One address holds all sixteen output lanes
// produced for a spatial position, allowing later DMA/pooling stages to move
// vectors instead of issuing sixteen AXI-Lite result reads.
`timescale 1ns/1ps
module gestureflow_output_bank #(
  parameter int ADDR_W = 8,
  parameter int DATA_W = 128
) (
  input  logic clk,
  input  logic write_enable,
  input  logic [ADDR_W-1:0] write_addr,
  input  logic [DATA_W-1:0] write_data,
  input  logic read_enable,
  input  logic [ADDR_W-1:0] read_addr,
  output logic [DATA_W-1:0] read_data
);
  logic [DATA_W-1:0] storage [0:(1<<ADDR_W)-1];

  always_ff @(posedge clk) begin
    if (write_enable) storage[write_addr] <= write_data;
    if (read_enable) read_data <= storage[read_addr];
  end
endmodule
