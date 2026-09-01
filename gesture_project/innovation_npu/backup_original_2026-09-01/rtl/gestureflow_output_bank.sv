// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// A tile-local INT8 output store. One address holds all sixteen output lanes
// produced for a spatial position. It is a single-bank, two-port (one write +
// one read) memory so Vivado infers true block RAM instead of expanding a
// three-port packed array into LUTs. The layer chain instantiates two banks
// for relay/pool ping-pong rather than multiplexing a third port here.
`timescale 1ns/1ps

module gestureflow_output_bank_slice #(
  parameter int ADDR_W = 12,
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
  (* ram_style = "block" *) logic [DATA_W-1:0] storage [0:(1<<ADDR_W)-1];

  always_ff @(posedge clk) begin
    if (write_enable) storage[write_addr] <= write_data;
    if (read_enable) read_data <= storage[read_addr];
  end
endmodule

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
  localparam int SLICE_ADDR_W = (ADDR_W > 12) ? 12 : ADDR_W;
  localparam int SLICE_DEPTH = 1 << SLICE_ADDR_W;
  localparam int SLICE_COUNT = (1 << ADDR_W) / SLICE_DEPTH;
  localparam int SLICE_SEL_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT);

  logic [SLICE_SEL_W-1:0] read_slice_q;
  logic [SLICE_SEL_W-1:0] write_slice_sel, read_slice_sel;
  logic [SLICE_ADDR_W-1:0] write_local_addr, read_local_addr;
  logic [DATA_W-1:0] slice_read_data [0:SLICE_COUNT-1];

  initial begin
    if (ADDR_W < 1) $error("ADDR_W must be at least one");
  end

  if (ADDR_W > SLICE_ADDR_W) begin : gen_slice_select
    assign write_slice_sel = write_addr[ADDR_W-1:SLICE_ADDR_W];
    assign read_slice_sel = read_addr[ADDR_W-1:SLICE_ADDR_W];
  end else begin : gen_single_slice_select
    assign write_slice_sel = '0;
    assign read_slice_sel = '0;
  end

  assign write_local_addr = write_addr[SLICE_ADDR_W-1:0];
  assign read_local_addr = read_addr[SLICE_ADDR_W-1:0];

  always_ff @(posedge clk) begin
    if (read_enable) read_slice_q <= SLICE_SEL_W'(read_slice_sel);
  end

  always_comb begin
    read_data = '0;
    for (int slice = 0; slice < SLICE_COUNT; slice++) begin
      if (read_slice_q == SLICE_SEL_W'(slice)) read_data = slice_read_data[slice];
    end
  end

  genvar slice_index;
  generate
    for (slice_index = 0; slice_index < SLICE_COUNT; slice_index++) begin : gen_slice
      gestureflow_output_bank_slice #(.ADDR_W(SLICE_ADDR_W), .DATA_W(DATA_W)) slice_mem (
        .clk(clk),
        .write_enable(write_enable && (write_slice_sel == SLICE_SEL_W'(slice_index))),
        .write_addr(write_local_addr),
        .write_data(write_data),
        .read_enable(read_enable && (read_slice_sel == SLICE_SEL_W'(slice_index))),
        .read_addr(read_local_addr),
        .read_data(slice_read_data[slice_index])
      );
    end
  endgenerate
endmodule
