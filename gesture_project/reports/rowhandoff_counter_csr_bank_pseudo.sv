module rowhandoff_counter_csr_bank (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        csr_read_en,
  input  logic [15:0] csr_addr,
  output logic [31:0] csr_rdata,
  input  logic        rowhandoff_valid_in,
  input  logic [5:0]  rowhandoff_row_out_y_in,
  input  logic        rowhandoff_hit_pulse,
  input  logic        rowhandoff_tail_hit_pulse,
  input  logic        rowhandoff_miss_pulse,
  input  logic        rowhandoff_invalidate_pulse,
  input  logic        rowhandoff_produce_pulse,
  input  logic        interior_row_enter_pulse,
  input  logic        right_edge_done_pulse
);

  logic [15:0] rowhandoff_hit_count_q;
  logic [15:0] rowhandoff_miss_count_q;
  logic [15:0] rowhandoff_invalidate_count_q;
  logic [15:0] rowhandoff_produce_count_q;
  logic [15:0] rowhandoff_tail_hit_count_q;
  logic [15:0] interior_row_enter_count_q;
  logic [15:0] right_edge_done_count_q;
  logic [5:0] rowhandoff_row_out_y_last_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rowhandoff_hit_count_q <= '0;
      rowhandoff_miss_count_q <= '0;
      rowhandoff_invalidate_count_q <= '0;
      rowhandoff_produce_count_q <= '0;
      rowhandoff_tail_hit_count_q <= '0;
      interior_row_enter_count_q <= '0;
      right_edge_done_count_q <= '0;
      rowhandoff_row_out_y_last_q <= '0;
    end else begin
      if (rowhandoff_hit_pulse) rowhandoff_hit_count_q <= rowhandoff_hit_count_q + 1'b1;
      if (rowhandoff_tail_hit_pulse) rowhandoff_tail_hit_count_q <= rowhandoff_tail_hit_count_q + 1'b1;
      if (rowhandoff_miss_pulse) rowhandoff_miss_count_q <= rowhandoff_miss_count_q + 1'b1;
      if (rowhandoff_invalidate_pulse) rowhandoff_invalidate_count_q <= rowhandoff_invalidate_count_q + 1'b1;
      if (rowhandoff_produce_pulse) rowhandoff_produce_count_q <= rowhandoff_produce_count_q + 1'b1;
      if (interior_row_enter_pulse) interior_row_enter_count_q <= interior_row_enter_count_q + 1'b1;
      if (right_edge_done_pulse) right_edge_done_count_q <= right_edge_done_count_q + 1'b1;
      rowhandoff_row_out_y_last_q <= rowhandoff_row_out_y_in;
    end
  end

  always_comb begin
    csr_rdata = 32'h0;
    if (csr_read_en) begin
      unique case (csr_addr)
        16'h0820: csr_rdata = {16'h0, rowhandoff_hit_count_q};
        16'h0824: csr_rdata = {16'h0, rowhandoff_miss_count_q};
        16'h0828: csr_rdata = {16'h0, rowhandoff_invalidate_count_q};
        16'h082c: csr_rdata = {16'h0, rowhandoff_produce_count_q};
        16'h0830: csr_rdata = {16'h0, rowhandoff_tail_hit_count_q};
        16'h0834: csr_rdata = {16'h0, interior_row_enter_count_q};
        16'h0838: csr_rdata = {16'h0, right_edge_done_count_q};
        16'h083c: csr_rdata = {26'h0, rowhandoff_row_out_y_last_q};
        default: csr_rdata = 32'h0;
      endcase
    end
  end

endmodule
