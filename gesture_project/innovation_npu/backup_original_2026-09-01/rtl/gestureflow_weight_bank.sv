// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// One physical output-channel weight bank for GestureFlow-NPU. Keeping this
// RAM in its own module prevents Vivado from flattening a variable-indexed
// two-dimensional array into flip-flops. A tile instantiates one bank per
// output lane, preserving one packed weight word per lane on every cycle.
`timescale 1ns/1ps
module gestureflow_weight_bank #(
  parameter int ADDR_W = 8,
  parameter int DATA_W = 32
) (
  input  logic clk,
  input  logic write_enable,
  input  logic [ADDR_W-1:0] write_addr,
  input  logic [DATA_W-1:0] write_data,
  input  logic read_enable,
  input  logic [ADDR_W-1:0] read_addr,
  output logic [DATA_W-1:0] read_data
);

  localparam int DEPTH = 1 << ADDR_W;

  // Payload SRAM is intentionally not reset. The command/DMA layer must load
  // every used word before start_valid. Resetting all words blocks BRAM
  // inference or consumes an unnecessary reset pass through the tile.
  (* ram_style = "block" *) logic [DATA_W-1:0] memory [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (write_enable) begin
      memory[write_addr] <= write_data;
    end
    if (read_enable) begin
      read_data <= memory[read_addr];
    end
  end

endmodule
