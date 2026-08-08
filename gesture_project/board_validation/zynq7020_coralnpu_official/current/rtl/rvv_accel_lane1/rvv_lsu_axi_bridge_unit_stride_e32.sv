// PROJECT_LOCAL_MOD: LSU-to-AXI bridge for the accelerator-only lane1 wrapper.
// The implemented board configuration is VLEN=64, so this bridge supports
// unit-stride e32 transfers of one or two elements as a single AXI burst. It
// deliberately rejects wider transfers; a future VLEN=128 build must widen
// this bridge and be requalified on hardware rather than silently truncating.
`timescale 1ns / 1ps

module rvv_lsu_axi_bridge_unit_stride_e32 (
    input  wire         aclk,
    input  wire         aresetn,

    // Latched instruction context from the PS issue path.
    input  wire         ctx_valid,
    input  wire         ctx_is_store,
    input  wire         ctx_supported,
    input  wire [1:0]   ctx_elem_count,
    input  wire [31:0]  ctx_base_addr,

    // RVV LSU side from the core.
    input  wire         rvv2lsu_valid,
    input  wire         rvv2lsu_idx_valid,
    input  wire [4:0]   rvv2lsu_idx_addr,
    input  wire [127:0] rvv2lsu_idx_data,
    input  wire         rvv2lsu_vregfile_valid,
    input  wire [4:0]   rvv2lsu_vregfile_addr,
    input  wire [127:0] rvv2lsu_vregfile_data,
    input  wire         rvv2lsu_v0_valid,
    input  wire [15:0]  rvv2lsu_v0_data,
    output wire         rvv2lsu_ready,

    output reg          lsu2rvv_valid,
    output reg  [4:0]   lsu2rvv_addr,
    output reg  [127:0] lsu2rvv_data,
    output reg          lsu2rvv_last,
    input  wire         lsu2rvv_ready,

    output reg          fault_sticky,
    output wire         busy,
    // PROJECT_LOCAL_MOD: board-facing snapshot of the accepted LSU request.
    // It is diagnostic only and does not participate in the data path.
    output wire [1:0]   debug_req_word_count,
    output wire [15:0]  debug_req_mask,

    // AXI master, 32-bit narrow access.
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,
    output wire [31:0]  m_axi_awaddr,
    output wire [2:0]   m_axi_awprot,
    output wire [5:0]   m_axi_awid,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire         m_axi_awlock,
    output wire [3:0]   m_axi_awcache,
    output wire [3:0]   m_axi_awqos,
    output wire [3:0]   m_axi_awregion,

    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    output wire [31:0]  m_axi_wdata,
    output wire [3:0]   m_axi_wstrb,
    output wire         m_axi_wlast,

    output wire         m_axi_bready,
    input  wire         m_axi_bvalid,
    input  wire [5:0]   m_axi_bid,
    input  wire [1:0]   m_axi_bresp,

    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    output wire [31:0]  m_axi_araddr,
    output wire [2:0]   m_axi_arprot,
    output wire [5:0]   m_axi_arid,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arlock,
    output wire [3:0]   m_axi_arcache,
    output wire [3:0]   m_axi_arqos,
    output wire [3:0]   m_axi_arregion,

    output wire         m_axi_rready,
    input  wire         m_axi_rvalid,
    input  wire [31:0]  m_axi_rdata,
    input  wire [5:0]   m_axi_rid,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast
);

  localparam [2:0] ST_IDLE         = 3'd0;
  localparam [2:0] ST_LD_AR        = 3'd1;
  localparam [2:0] ST_LD_R         = 3'd2;
  localparam [2:0] ST_ST_AW_W      = 3'd3;
  localparam [2:0] ST_ST_B         = 3'd4;
  localparam [2:0] ST_RESP_TO_CORE = 3'd5;

  reg [2:0]   state;
  reg [31:0]  req_addr;
  reg [4:0]   req_vreg_addr;
  reg [127:0] req_vreg_data;
  reg [15:0]  req_mask;
  reg [1:0]   req_word_count;
  reg [1:0]   read_word_index;
  reg [1:0]   write_word_index;
  reg [127:0] read_data_accum;
  reg         req_is_store;
  reg         req_supported;
  reg         store_aw_done;
  reg         store_w_done;

  // PROJECT_LOCAL_MOD: an RVV mask has one bit per vector element, not one
  // bit per byte. The e32/VL=2 board mode therefore consumes mask bits 0 and
  // 1. Transfer length is taken from the latched vector-length context, so a
  // valid second element cannot be silently dropped when mask[4] is clear.
  wire req_mask_active = |req_mask[1:0];
  wire accept_req = rvv2lsu_valid && rvv2lsu_ready;
  wire store_aw_fire = (state == ST_ST_AW_W) && req_mask_active && !store_aw_done && m_axi_awready;
  wire store_w_fire = (state == ST_ST_AW_W) && req_mask_active && !store_w_done && m_axi_wready;
  wire write_last_beat = (write_word_index + 2'd1) == req_word_count;
  wire read_last_beat = (read_word_index + 2'd1) == req_word_count;

  assign busy = (state != ST_IDLE) || lsu2rvv_valid;
  assign debug_req_word_count = req_word_count;
  assign debug_req_mask = req_mask;
  assign rvv2lsu_ready = (state == ST_IDLE) && !lsu2rvv_valid;

  assign m_axi_awvalid  = (state == ST_ST_AW_W) && req_mask_active && !store_aw_done;
  assign m_axi_awaddr   = req_addr;
  assign m_axi_awprot   = 3'b000;
  assign m_axi_awid     = 6'd0;
  assign m_axi_awlen    = {6'd0, req_word_count} - 8'd1;
  assign m_axi_awsize   = 3'd2;
  assign m_axi_awburst  = 2'b01;
  assign m_axi_awlock   = 1'b0;
  assign m_axi_awcache  = 4'b0011;
  assign m_axi_awqos    = 4'b0000;
  assign m_axi_awregion = 4'b0000;

  assign m_axi_wvalid   = (state == ST_ST_AW_W) && req_mask_active && !store_w_done;
  assign m_axi_wdata    = (write_word_index == 2'd0) ? req_vreg_data[31:0] :
                         req_vreg_data[63:32];
  assign m_axi_wstrb    = (write_word_index == 2'd0) ?
                         {4{req_mask[0]}} : {4{req_mask[1]}};
  assign m_axi_wlast    = write_last_beat;

  assign m_axi_bready   = (state == ST_ST_B);

  assign m_axi_arvalid  = (state == ST_LD_AR);
  assign m_axi_araddr   = req_addr;
  assign m_axi_arprot   = 3'b000;
  assign m_axi_arid     = 6'd0;
  assign m_axi_arlen    = {6'd0, req_word_count} - 8'd1;
  assign m_axi_arsize   = 3'd2;
  assign m_axi_arburst  = 2'b01;
  assign m_axi_arlock   = 1'b0;
  assign m_axi_arcache  = 4'b0011;
  assign m_axi_arqos    = 4'b0000;
  assign m_axi_arregion = 4'b0000;

  assign m_axi_rready   = (state == ST_LD_R);

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      state <= ST_IDLE;
      req_addr <= 32'd0;
      req_vreg_addr <= 5'd0;
      req_vreg_data <= 128'd0;
      req_mask <= 16'd0;
      req_word_count <= 2'd1;
      read_word_index <= 2'd0;
      write_word_index <= 2'd0;
      read_data_accum <= 128'd0;
      req_is_store <= 1'b0;
      req_supported <= 1'b0;
      store_aw_done <= 1'b0;
      store_w_done <= 1'b0;
      lsu2rvv_valid <= 1'b0;
      lsu2rvv_addr <= 5'd0;
      lsu2rvv_data <= 128'd0;
      lsu2rvv_last <= 1'b0;
      fault_sticky <= 1'b0;
    end else begin
      if (lsu2rvv_valid && lsu2rvv_ready) begin
        lsu2rvv_valid <= 1'b0;
        lsu2rvv_addr <= 5'd0;
        lsu2rvv_data <= 128'd0;
        lsu2rvv_last <= 1'b0;
        state <= ST_IDLE;
      end

      case (state)
        ST_IDLE: begin
          store_aw_done <= 1'b0;
          store_w_done <= 1'b0;
          if (accept_req) begin
            req_addr <= ctx_base_addr;
            req_vreg_addr <= rvv2lsu_vregfile_addr;
            req_vreg_data <= rvv2lsu_vregfile_data;
            req_mask <= rvv2lsu_v0_data;
            req_word_count <= ctx_elem_count;
            read_word_index <= 2'd0;
            write_word_index <= 2'd0;
            read_data_accum <= 128'd0;
            req_is_store <= ctx_is_store;
            req_supported <= ctx_supported;

            if (!ctx_valid || !ctx_supported ||
                ((ctx_elem_count != 2'd1) && (ctx_elem_count != 2'd2)) ||
                rvv2lsu_idx_valid ||
                (|rvv2lsu_v0_data[15:8])) begin
              fault_sticky <= 1'b1;
              lsu2rvv_valid <= 1'b1;
              lsu2rvv_addr <= rvv2lsu_vregfile_addr;
              lsu2rvv_data <= 128'd0;
              lsu2rvv_last <= ctx_is_store;
              state <= ST_RESP_TO_CORE;
            end else if (ctx_is_store) begin
              if (|rvv2lsu_v0_data[3:0]) begin
                state <= ST_ST_AW_W;
              end else begin
                // Masked-off store degenerates to a clean completion.
                lsu2rvv_valid <= 1'b1;
                lsu2rvv_addr <= rvv2lsu_vregfile_addr;
                lsu2rvv_data <= 128'd0;
                lsu2rvv_last <= 1'b1;
                state <= ST_RESP_TO_CORE;
              end
            end else begin
              state <= ST_LD_AR;
            end
          end
        end

        ST_LD_AR: begin
          if (m_axi_arvalid && m_axi_arready) begin
            state <= ST_LD_R;
          end
        end

        ST_LD_R: begin
          if (m_axi_rvalid && m_axi_rready) begin
            if (m_axi_rresp != 2'b00) begin
              fault_sticky <= 1'b1;
            end
            if (read_last_beat) begin
              if (!m_axi_rlast) begin
                fault_sticky <= 1'b1;
              end
              lsu2rvv_valid <= 1'b1;
              lsu2rvv_addr <= req_vreg_addr;
              if (req_word_count == 2'd1) begin
                lsu2rvv_data <= {96'd0, m_axi_rdata};
              end else begin
                lsu2rvv_data <= {64'd0, m_axi_rdata, read_data_accum[31:0]};
              end
              lsu2rvv_last <= 1'b0;
              state <= ST_RESP_TO_CORE;
            end else begin
              if (m_axi_rlast) begin
                fault_sticky <= 1'b1;
              end
              read_data_accum[31:0] <= m_axi_rdata;
              read_word_index <= read_word_index + 2'd1;
            end
          end
        end

        ST_ST_AW_W: begin
          if (store_aw_fire) begin
            store_aw_done <= 1'b1;
          end
          if (store_w_fire) begin
            if (write_last_beat) begin
              store_w_done <= 1'b1;
            end else begin
              write_word_index <= write_word_index + 2'd1;
            end
          end
          if ((store_aw_done || store_aw_fire) &&
              (store_w_done || (store_w_fire && write_last_beat))) begin
            state <= ST_ST_B;
          end
        end

        ST_ST_B: begin
          if (m_axi_bvalid && m_axi_bready) begin
            if (m_axi_bresp != 2'b00) begin
              fault_sticky <= 1'b1;
            end
            lsu2rvv_valid <= 1'b1;
            lsu2rvv_addr <= req_vreg_addr;
            lsu2rvv_data <= 128'd0;
            lsu2rvv_last <= 1'b1;
            state <= ST_RESP_TO_CORE;
          end
        end

        ST_RESP_TO_CORE: begin
        end

        default: begin
          state <= ST_IDLE;
        end
      endcase
    end
  end
endmodule
