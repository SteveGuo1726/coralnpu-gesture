// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// One transaction-local activation store.  AXI-Lite is used only to fill it
// before start; the compute controller then consumes one packed four-INT8
// word per cycle.  The same write/read boundary will later be driven by HP0
// DMA instead of the PS control path.
`timescale 1ns/1ps
module gestureflow_activation_bank #(
  parameter int ADDR_W = 8,
  parameter int DATA_W = 32
) (
  input logic clk,
  input logic write_enable,
  input logic [ADDR_W-1:0] write_addr,
  input logic [DATA_W-1:0] write_data,
  input logic read_enable,
  input logic [ADDR_W-1:0] read_addr,
  output logic [DATA_W-1:0] read_data
);
  localparam int DEPTH = 1 << ADDR_W;

  // Payload state is intentionally not reset.  Software or a later DMA
  // front end owns initialization before CONTROL.start_staged is asserted.
  (* ram_style = "block" *) logic [DATA_W-1:0] memory [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (write_enable) memory[write_addr] <= write_data;
    if (read_enable) read_data <= memory[read_addr];
  end
endmodule
