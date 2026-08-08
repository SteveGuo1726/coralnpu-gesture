// PROJECT_LOCAL_MOD: AXI4 burst mover for the real stage3b tensor engine.
//
// This is deliberately independent of the RVV LSU command path.  The board
// wrapper grants the two masters exclusive, phase-based access to HP0: DMA
// loads model tensors before the 3x3 engine starts and stores pool3 before
// the RVV postprocess begins.  That makes the dataflow deterministic while
// removing AXI-Lite's per-word staging overhead.
`timescale 1ns / 1ps

module coralnpu_stage3b_axi_dma (
    input  wire        clk,
    input  wire        rstn,

    input  wire        start_load,
    input  wire        start_store,
    input  wire [31:0] input_base_addr,
    input  wire [31:0] weight_base_addr,
    input  wire [31:0] bias_base_addr,
    input  wire [31:0] multiplier_base_addr,
    input  wire [31:0] shift_base_addr,
    input  wire [31:0] pool_base_addr,
    output wire        busy,
    output reg         done,
    output reg         fault,

    // Direct, phase-exclusive ports into coralnpu_stage3b_tensor_engine.
    output wire        stage_we,
    output wire [2:0]  stage_kind,
    output wire [15:0] stage_addr,
    output wire [31:0] stage_wdata,
    output wire        pool_re,
    output wire [10:0] pool_addr,
    input  wire [63:0] pool_rdata,

    // 32-bit AXI4 master.  HP0 and the existing LSU bridge use this width.
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [31:0] m_axi_awaddr,
    output wire [2:0]  m_axi_awprot,
    output wire [5:0]  m_axi_awid,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awlock,
    output wire [3:0]  m_axi_awcache,
    output wire [3:0]  m_axi_awqos,
    output wire [3:0]  m_axi_awregion,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_bready,
    input  wire        m_axi_bvalid,
    input  wire [5:0]  m_axi_bid,
    input  wire [1:0]  m_axi_bresp,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    output wire [31:0] m_axi_araddr,
    output wire [2:0]  m_axi_arprot,
    output wire [5:0]  m_axi_arid,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arlock,
    output wire [3:0]  m_axi_arcache,
    output wire [3:0]  m_axi_arqos,
    output wire [3:0]  m_axi_arregion,
    output wire        m_axi_rready,
    input  wire        m_axi_rvalid,
    input  wire [31:0] m_axi_rdata,
    input  wire [5:0]  m_axi_rid,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast
);
  localparam [4:0] ST_IDLE         = 5'd0;
  localparam [4:0] ST_LOAD_PREP    = 5'd1;
  localparam [4:0] ST_LOAD_AR      = 5'd2;
  localparam [4:0] ST_LOAD_R       = 5'd3;
  localparam [4:0] ST_STORE_PREP   = 5'd4;
  localparam [4:0] ST_STORE_AW     = 5'd5;
  localparam [4:0] ST_STORE_FETCH  = 5'd6;
  localparam [4:0] ST_STORE_WAIT   = 5'd7;
  localparam [4:0] ST_STORE_W_LO   = 5'd8;
  localparam [4:0] ST_STORE_W_HI   = 5'd9;
  localparam [4:0] ST_STORE_B      = 5'd10;

  localparam [13:0] INPUT_WORDS      = 14'd9216;
  localparam [13:0] WEIGHT_WORDS     = 14'd9216;
  localparam [13:0] CHANNEL_WORDS    = 14'd64;
  // PROJECT_LOCAL_MOD: expand every signed pool3 byte to one signed e32
  // DDR word.  The RVV LSU already proves e32 unit-stride loads on the board;
  // this removes the PS-side 9,216-word expansion loop without requiring an
  // unverified e8 unpack instruction sequence in the VLEN=64 configuration.
  localparam [13:0] POOL_WORDS       = 14'd9216;
  localparam [8:0]  MAX_BURST_WORDS  = 9'd256;

  reg [4:0]  state;
  reg [2:0]  load_kind_q;
  reg [13:0] segment_offset_q;
  reg [8:0]  burst_words_q;
  reg [8:0]  burst_index_q;
  reg [31:0] burst_addr_q;
  reg [13:0] store_offset_q;

  function automatic [13:0] segment_words;
    input [2:0] kind;
    begin
      case (kind)
        3'd0: segment_words = INPUT_WORDS;
        3'd1: segment_words = WEIGHT_WORDS;
        default: segment_words = CHANNEL_WORDS;
      endcase
    end
  endfunction

  function automatic [31:0] segment_base;
    input [2:0] kind;
    begin
      case (kind)
        3'd0: segment_base = input_base_addr;
        3'd1: segment_base = weight_base_addr;
        3'd2: segment_base = bias_base_addr;
        3'd3: segment_base = multiplier_base_addr;
        default: segment_base = shift_base_addr;
      endcase
    end
  endfunction

  wire load_r_fire = (state == ST_LOAD_R) && m_axi_rvalid;
  wire load_last_beat = (burst_index_q + 9'd1) == burst_words_q;
  wire [13:0] load_remaining = segment_words(load_kind_q) - segment_offset_q;
  wire [13:0] store_remaining = POOL_WORDS - store_offset_q;
  wire [13:0] store_element_index = store_offset_q +
      {{5{1'b0}}, burst_index_q};
  wire [2:0] pool_byte_index = store_element_index[2:0];
  wire signed [7:0] pool_selected_i8 =
      pool_rdata[(pool_byte_index * 8) +: 8];
  wire store_last_beat = (burst_index_q + 9'd1) == burst_words_q;

  assign busy = (state != ST_IDLE);
  assign stage_we = load_r_fire;
  assign stage_kind = load_kind_q;
  assign stage_addr = {{2{1'b0}}, segment_offset_q} +
      {{7{1'b0}}, burst_index_q};
  assign stage_wdata = m_axi_rdata;
  assign pool_re = (state == ST_STORE_FETCH);
  assign pool_addr = store_element_index[13:3];

  assign m_axi_awvalid = (state == ST_STORE_AW);
  assign m_axi_awaddr = burst_addr_q;
  assign m_axi_awprot = 3'b000;
  assign m_axi_awid = 6'd1;
  assign m_axi_awlen = burst_words_q[7:0] - 8'd1;
  assign m_axi_awsize = 3'd2;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awlock = 1'b0;
  assign m_axi_awcache = 4'b0011;
  assign m_axi_awqos = 4'b0000;
  assign m_axi_awregion = 4'b0000;
  assign m_axi_wvalid = (state == ST_STORE_W_LO);
  assign m_axi_wdata = {{24{pool_selected_i8[7]}}, pool_selected_i8};
  assign m_axi_wstrb = 4'hf;
  assign m_axi_wlast = (state == ST_STORE_W_LO) && store_last_beat;
  assign m_axi_bready = (state == ST_STORE_B);

  assign m_axi_arvalid = (state == ST_LOAD_AR);
  assign m_axi_araddr = burst_addr_q;
  assign m_axi_arprot = 3'b000;
  assign m_axi_arid = 6'd1;
  assign m_axi_arlen = burst_words_q[7:0] - 8'd1;
  assign m_axi_arsize = 3'd2;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arlock = 1'b0;
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arqos = 4'b0000;
  assign m_axi_arregion = 4'b0000;
  assign m_axi_rready = (state == ST_LOAD_R);

  // The DMA counters feed stage3b BRAM addresses.  Keep their reset
  // synchronous so reset assertion cannot asynchronously toggle a RAM
  // address/control pin, matching the 7-series BRAM-safe engine discipline.
  always @(posedge clk) begin
    if (!rstn) begin
      state <= ST_IDLE;
      load_kind_q <= 3'd0;
      segment_offset_q <= 14'd0;
      burst_words_q <= 9'd0;
      burst_index_q <= 9'd0;
      burst_addr_q <= 32'd0;
      store_offset_q <= 14'd0;
      done <= 1'b0;
      fault <= 1'b0;
    end else begin
      done <= 1'b0;
      case (state)
        ST_IDLE: begin
          fault <= 1'b0;
          if (start_load) begin
            load_kind_q <= 3'd0;
            segment_offset_q <= 14'd0;
            state <= ST_LOAD_PREP;
          end else if (start_store) begin
            store_offset_q <= 14'd0;
            state <= ST_STORE_PREP;
          end
        end

        ST_LOAD_PREP: begin
          if ((segment_words(load_kind_q) - segment_offset_q) > 14'd256)
            burst_words_q <= MAX_BURST_WORDS;
          else
            burst_words_q <= load_remaining[8:0];
          burst_index_q <= 9'd0;
          burst_addr_q <= segment_base(load_kind_q) +
              {{16{1'b0}}, segment_offset_q, 2'b00};
          state <= ST_LOAD_AR;
        end

        ST_LOAD_AR: begin
          if (m_axi_arvalid && m_axi_arready) state <= ST_LOAD_R;
        end

        ST_LOAD_R: begin
          if (load_r_fire) begin
            if (m_axi_rresp != 2'b00) fault <= 1'b1;
            if (load_last_beat) begin
              if (!m_axi_rlast) fault <= 1'b1;
              if ((segment_offset_q + {{5{1'b0}}, burst_words_q}) ==
                  segment_words(load_kind_q)) begin
                if (load_kind_q == 3'd4) begin
                  done <= 1'b1;
                  state <= ST_IDLE;
                end else begin
                  load_kind_q <= load_kind_q + 3'd1;
                  segment_offset_q <= 14'd0;
                  state <= ST_LOAD_PREP;
                end
              end else begin
                segment_offset_q <= segment_offset_q +
                    {{5{1'b0}}, burst_words_q};
                state <= ST_LOAD_PREP;
              end
            end else begin
              if (m_axi_rlast) fault <= 1'b1;
              burst_index_q <= burst_index_q + 9'd1;
            end
          end
        end

        ST_STORE_PREP: begin
          if ((POOL_WORDS - store_offset_q) > 14'd256)
            burst_words_q <= MAX_BURST_WORDS;
          else
            burst_words_q <= store_remaining[8:0];
          burst_index_q <= 9'd0;
          burst_addr_q <= pool_base_addr +
              {{16{1'b0}}, store_offset_q, 2'b00};
          state <= ST_STORE_AW;
        end

        ST_STORE_AW: begin
          if (m_axi_awvalid && m_axi_awready) state <= ST_STORE_FETCH;
        end

        ST_STORE_FETCH: state <= ST_STORE_WAIT;
        ST_STORE_WAIT: state <= ST_STORE_W_LO;

        ST_STORE_W_LO: begin
          if (m_axi_wvalid && m_axi_wready) begin
            if (store_last_beat) state <= ST_STORE_B;
            else begin
              burst_index_q <= burst_index_q + 9'd1;
              state <= ST_STORE_FETCH;
            end
          end
        end

        ST_STORE_B: begin
          if (m_axi_bvalid && m_axi_bready) begin
            if (m_axi_bresp != 2'b00) fault <= 1'b1;
            if ((store_offset_q + {{5{1'b0}}, burst_words_q}) == POOL_WORDS) begin
              done <= 1'b1;
              state <= ST_IDLE;
            end else begin
              store_offset_q <= store_offset_q +
                  {{5{1'b0}}, burst_words_q};
              state <= ST_STORE_PREP;
            end
          end
        end

        default: begin
          fault <= 1'b1;
          state <= ST_IDLE;
        end
      endcase
    end
  end
endmodule
