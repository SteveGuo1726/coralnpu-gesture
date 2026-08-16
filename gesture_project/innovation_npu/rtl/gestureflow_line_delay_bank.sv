// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// One simple-dual-port synchronous line-delay RAM. Separate read/write ports
// permit the next raster pixel to issue a read while the preceding pixel
// advances through the vertical delay chain. Payload contents are never reset.
`timescale 1ns/1ps
module gestureflow_line_delay_bank #(
  parameter int ADDR_W = 7
) (
  input  logic clk,
  input  logic write_enable,
  input  logic [ADDR_W-1:0] write_addr,
  input  logic signed [7:0] write_data,
  input  logic read_enable,
  input  logic [ADDR_W-1:0] read_addr,
  output logic signed [7:0] read_data
);
  (* ram_style = "block" *) logic signed [7:0] memory [0:(1<<ADDR_W)-1];

  always_ff @(posedge clk) begin
    if (write_enable) begin
      memory[write_addr] <= write_data;
    end
    if (read_enable) begin
      read_data <= memory[read_addr];
    end
  end
endmodule
