// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// A vectorized form of the original 8-bit line-delay bank. One address now
// stores every channel of one NHWC pixel, so the three physical line stores
// scale with vector width rather than with the number of scalar channels.
`timescale 1ns/1ps
module gestureflow_line_delay_vector_bank #(
  parameter int ADDR_W = 7,
  parameter int DATA_WIDTH = 128
) (
  input logic clk,
  input logic write_enable,
  input logic [ADDR_W-1:0] write_addr,
  input logic signed [DATA_WIDTH-1:0] write_data,
  input logic read_enable,
  input logic [ADDR_W-1:0] read_addr,
  output logic signed [DATA_WIDTH-1:0] read_data
);
  (* ram_style = "block" *) logic signed [DATA_WIDTH-1:0] memory [0:(1<<ADDR_W)-1];

  always_ff @(posedge clk) begin
    if (write_enable) memory[write_addr] <= write_data;
    if (read_enable) read_data <= memory[read_addr];
  end
endmodule
