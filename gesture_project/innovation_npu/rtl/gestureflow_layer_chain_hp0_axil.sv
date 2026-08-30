// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// One reusable 7020 layer engine.  The same 16-output x 4-input DSP tile,
// window cache, INT32 accumulator, requantizer, output bank and HP0 writer
// execute either the RGB first layer (3 active lanes) or the signed 16-channel
// body layer.  The PS changes only the descriptor and resident weights between
// the two runs; it never copies the intermediate activation back through the
// ARM.  This is the first single-bitstream layer-handoff baseline, not Google
// CoralNPU RTL.
`timescale 1ns/1ps
module gestureflow_layer_chain_hp0_axil #(
  parameter int IMAGE_WIDTH = 96,
  parameter int IMAGE_HEIGHT = 96,
  parameter int OUTPUTS = IMAGE_WIDTH * IMAGE_HEIGHT,
  parameter int OUT_LANES = 16,
  // Quantization is a tail operation, while convolution is the throughput
  // driver. One lane keeps the 7020 tail compact and removes the wide
  // variable-shift fanout from the routed critical path.
  parameter int REQUANT_PARALLEL_LANES = 1,
  parameter int OUTPUT_ADDR_W = 14,
  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // The 7020 production baseline only needs RGB and 16-Cin body layers.
  // Wide loaders and GAP/FC remain available as an explicit expansion build,
  // but must not consume resources in the real two-layer baseline.
  parameter int MAX_INPUT_CHANNELS = 16,
  parameter bit ENABLE_WIDE_MODES = 1'b0,
  parameter bit ENABLE_POSTPROCESS = 1'b0,
  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // On-chip relay/pool-relay is a separate innovation track. It requires a
  // second full-frame ping-pong bank, which pushes the 7020 BRAM budget and
  // forces the MAC weight banks into LUT-RAM. The deployed store-to-DDR path
  // needs only one two-port bank, so relay is parameterized out for the board
  // build and kept for the Verilator relay regressions.
  parameter bit ENABLE_RELAY = 1'b1
) (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.ACLK, ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET aresetn" *) input wire aclk,
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.ARESETN, POLARITY ACTIVE_LOW" *) input wire aresetn,
  input wire [31:0] s_axi_awaddr, input wire [2:0] s_axi_awprot, input wire s_axi_awvalid, output logic s_axi_awready,
  input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb, input wire s_axi_wvalid, output logic s_axi_wready,
  output logic [1:0] s_axi_bresp, output logic s_axi_bvalid, input wire s_axi_bready,
  input wire [31:0] s_axi_araddr, input wire [2:0] s_axi_arprot, input wire s_axi_arvalid, output logic s_axi_arready,
  output logic [31:0] s_axi_rdata, output logic [1:0] s_axi_rresp, output logic s_axi_rvalid, input wire s_axi_rready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *) output logic [31:0] m_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *) output logic [5:0] m_axi_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *) output logic [7:0] m_axi_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *) output logic [2:0] m_axi_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *) output logic [1:0] m_axi_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *) output logic m_axi_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *) output logic [3:0] m_axi_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *) output logic [2:0] m_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARQOS" *) output logic [3:0] m_axi_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREGION" *) output logic [3:0] m_axi_arregion,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *) output logic m_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *) input wire m_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID" *) input wire [5:0] m_axi_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *) input wire [63:0] m_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *) input wire [1:0] m_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *) input wire m_axi_rlast,
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI, PROTOCOL AXI4, ADDR_WIDTH 32, DATA_WIDTH 64, ID_WIDTH 6, HAS_BRESP 1, HAS_RRESP 1, HAS_BURST 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, READ_WRITE_MODE READ_WRITE, MAX_BURST_LENGTH 16" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *) input wire m_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *) output logic m_axi_rready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *) output logic [31:0] m_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *) output logic [5:0] m_axi_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *) output logic [7:0] m_axi_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *) output logic [2:0] m_axi_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *) output logic [1:0] m_axi_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *) output logic m_axi_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *) output logic [3:0] m_axi_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *) output logic [2:0] m_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWQOS" *) output logic [3:0] m_axi_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREGION" *) output logic [3:0] m_axi_awregion,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *) output logic m_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *) input wire m_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *) output logic [63:0] m_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *) output logic [7:0] m_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *) output logic m_axi_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *) output logic m_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *) input wire m_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID" *) input wire [5:0] m_axi_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *) input wire [1:0] m_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *) input wire m_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *) output logic m_axi_bready
);
  localparam logic [11:0] MAGIC=12'h000, VERSION=12'h004, CONTROL=12'h008, STATUS=12'h00c,
    QCFG=12'h010, WCTRL=12'h014, WDATA=12'h018, BIDX=12'h01c, BDATA=12'h020,
    RQIDX=12'h024, RQMULT=12'h028, RQSHIFT=12'h02c, CYCLES=12'h034,
    INPUT_PIXELS=12'h038, OUTPUT_VECTORS=12'h03c, OUTPUT_FNV1A=12'h040,
    DMA_SOURCE=12'h044, DMA_BYTES=12'h048, DMA_PIXELS=12'h04c, DMA_STATUS=12'h050,
    STORE_DESTINATION=12'h054, STORE_BYTES=12'h058, STORE_CONTROL=12'h05c,
    STORE_STATUS=12'h060, LAYER_MODE=12'h064, JOB_WIDTH=12'h068,
    JOB_HEIGHT=12'h06c, OUTPUT_LANE_MASK=12'h070, STORE_STRIDE=12'h074,
    STORE_VALID_BYTES=12'h078, RELAY_CONTROL=12'h07c,
    POST_GAP_MULT=12'h080, POST_GAP_SHIFT=12'h084,
    POST_QCFG=12'h088, POST_GAP_FNV1A=12'h08c, POST_FC_FNV1A=12'h090,
    POST_CLASS=12'h094, POST_CYCLES=12'h098, POST_PROGRESS=12'h09c,
    POST_DEBUG_GAP_SUM0=12'h0a0, POST_DEBUG_GAP_SUM6=12'h0a4,
    POST_DEBUG_FC0=12'h0a8, POST_DEBUG_FC1=12'h0ac, POST_DEBUG_FC2=12'h0b0,
    POST_DEBUG_FC3=12'h0b4, POST_DEBUG_FC4=12'h0b8, POST_DEBUG_FC5=12'h0bc;
  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // Weight residency ABI.  The legacy AXI-Lite programming path remains
  // valid when WEIGHT_KEY is never written; keyed mode requires a commit
  // before CONTROL.start and exposes measurable hit/miss/write statistics.
  localparam logic [11:0] WEIGHT_KEY=12'h0c0, WEIGHT_RESIDENT_KEY=12'h0c4,
    WEIGHT_WRITE_COUNT=12'h0c8, WEIGHT_HIT_COUNT=12'h0cc,
    WEIGHT_BYTES=12'h0d0, WEIGHT_STATUS=12'h0d4, WEIGHT_COMMIT=12'h0d8,
    WEIGHT_MISS_COUNT=12'h0dc, WEIGHT_DMA_SOURCE=12'h0e0,
    WEIGHT_DMA_BYTES=12'h0e4, WEIGHT_DMA_CFG=12'h0e8,
    WEIGHT_DMA_CONTROL=12'h0ec, WEIGHT_DMA_STATUS=12'h0f0,
    WEIGHT_DMA_BYTES_READ=12'h0f4, WEIGHT_DMA_WRITE_COUNT=12'h0f8,
    WEIGHT_BANK_SELECT=12'h0fc, PARAM_BANK_SELECT=12'h150,
    WEIGHT_READ_BANK_SELECT=12'h15c,
    DESC_SELECT=12'h100, DESC_MODE=12'h104, DESC_JOB_SHAPE=12'h108,
    DESC_DMA_SOURCE=12'h10c, DESC_DMA_BYTES=12'h110, DESC_DMA_PIXELS=12'h114,
    DESC_STORE_DESTINATION=12'h118, DESC_STORE_BYTES=12'h11c,
    DESC_STORE_CONTROL=12'h120, DESC_STORE_STRIDE=12'h124,
    DESC_STORE_VALID_BYTES=12'h128, DESC_QCFG=12'h12c,
    DESC_LANE_MASK=12'h130, DESC_COUNT=12'h134, DESC_CONTROL=12'h138,
    DESC_STATUS=12'h13c, DESC_ISSUED=12'h140, DESC_COMPLETED=12'h144,
    DESC_WEIGHT_BANK=12'h148, DESC_PARAM_BANK=12'h14c, DESC_TASK_CYCLES=12'h154,
    DESC_RELAY_CONTROL=12'h158;
  localparam logic [31:0] FNV_OFFSET=32'h811c9dc5, FNV_PRIME=32'h01000193;
  // The physical tile has four input lanes and a parameterized output width.
  // The 32-output build widens output-channel parallelism without spilling
  // partial sums to DDR; mode 3 only widens ingress/window storage so all
  // 12 Cin groups of a 48-channel layer remain locally accumulated.
  localparam int PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT;
  localparam int CTRL_LANES = (OUT_LANES > 18) ? OUT_LANES : 18;

  logic [31:0] awaddr, wdata; logic [3:0] wstrb; logic aw_seen, w_seen;
  logic running, done, fault;
  logic [2:0] layer_mode;
  logic dma_start, dma_clear, store_start, store_clear, store_enable, store_pool_2x2;
  logic [31:0] dma_source_addr, dma_bytes;
  logic [13:0] dma_pixels;
  logic [31:0] store_destination, store_bytes;
  logic [15:0] job_width, job_height;
  logic [31:0] store_stride_bytes;
  logic [5:0] store_valid_bytes;
  logic [31:0] layer_cycles;
  logic weight_write_valid, ps_weight_write_valid, weight_dma_write_valid;
  logic [4:0] ps_weight_write_oc; logic [3:0] ps_weight_write_tap;
  logic [4:0] ps_weight_write_ic_group;
  logic signed [3:0][7:0] ps_weight_write_data;
  logic [31:0] weight_key, weight_resident_key, weight_write_count;
  logic [31:0] weight_hit_count, weight_miss_count, weight_bytes;
  logic weight_keyed_mode, weight_resident_valid, weight_key_hit;
  logic [4:0] weight_write_oc; logic [3:0] weight_write_tap;
  logic [$clog2(CTRL_LANES)-1:0] bias_index, requant_index;
  logic [4:0] weight_write_ic_group;
  logic signed [3:0][7:0] weight_write_data;
  localparam int STREAM_WEIGHT_GROUP_W = (MAX_INPUT_CHANNELS <= 4) ? 1 : $clog2(MAX_INPUT_CHANNELS / 4);
  logic [STREAM_WEIGHT_GROUP_W-1:0] stream_weight_write_ic_group;
  logic weight_dma_start, weight_dma_clear, weight_dma_busy, weight_dma_done, weight_dma_fault;
  logic [31:0] weight_dma_source, weight_dma_bytes, weight_dma_bytes_read, weight_dma_write_count;
  logic [4:0] weight_dma_taps, weight_dma_groups; logic [5:0] weight_dma_outputs;
  logic [31:0] weight_dma_araddr; logic [5:0] weight_dma_arid; logic [7:0] weight_dma_arlen;
  logic [2:0] weight_dma_arsize; logic [1:0] weight_dma_arburst; logic weight_dma_arlock, weight_dma_arvalid, weight_dma_rready;
  logic [3:0] weight_dma_arcache, weight_dma_arqos, weight_dma_arregion; logic [2:0] weight_dma_arprot;
  localparam int WEIGHT_DMA_OC_W = (OUT_LANES <= 1) ? 1 : $clog2(OUT_LANES);
  logic [WEIGHT_DMA_OC_W-1:0] weight_dma_oc; logic [3:0] weight_dma_tap; logic [4:0] weight_dma_ic_group;
  logic signed [3:0][7:0] weight_dma_data;
  logic signed [CTRL_LANES-1:0][31:0] bias, requant_multiplier;
  logic [CTRL_LANES-1:0][5:0] requant_right_shift;
  logic [OUT_LANES-1:0] output_lane_enable;
  logic weight_bank_select, weight_read_bank_select;
  logic [31:0] bias_bank [0:1][0:CTRL_LANES-1];
  logic [31:0] requant_multiplier_bank [0:1][0:CTRL_LANES-1];
  logic [5:0] requant_right_shift_bank [0:1][0:CTRL_LANES-1];
  logic [0:0] param_bank_select;
  logic signed [MAX_INPUT_CHANNELS-1:0][7:0] input_zero_point, selected_pixel;
  logic requant_enable, requant_relu_enable; logic signed [7:0] output_zero_point;
  logic post_start, post_clear, post_busy, post_done, post_fault;
  logic signed [31:0] post_gap_multiplier;
  logic [5:0] post_gap_right_shift;
  logic signed [7:0] post_gap_input_zero_point, post_gap_output_zero_point, post_fc_output_zero_point;
  logic [31:0] post_gap_fnv1a, post_fc_fnv1a, post_cycles;
  logic signed [31:0] post_debug_gap_sum0, post_debug_gap_sum6;
  logic signed [17:0][7:0] post_debug_fc_value;
  logic [4:0] post_predicted_class, post_fc_values_done;
  logic [6:0] post_gap_values_done;

  logic rgb_busy, rgb_done, rgb_fault, rgb_frame_start, rgb_pixel_valid, rgb_pixel_ready;
  logic signed [2:0][7:0] rgb_pixel; logic [13:0] rgb_pixels_emitted; logic [15:0] rgb_bytes_read;
  logic relay_enable, relay_read_bank_select, output_write_bank_select, relay_pool_2x2;
  logic relay_mode, relay_stream_mode, relay_pool_mode;
  logic relay_busy, relay_done, relay_fault, relay_frame_start, relay_pixel_valid, relay_pixel_ready;
  logic signed [15:0][7:0] relay_pixel;
  logic [13:0] relay_pixels_emitted;
  logic relay_pool_busy, relay_pool_done, relay_pool_fault, relay_pool_frame_start, relay_pool_pixel_valid, relay_pool_pixel_ready;
  logic signed [15:0][7:0] relay_pool_pixel;
  logic [13:0] relay_pool_pixels_emitted;
  logic tensor_busy, tensor_done, tensor_fault, tensor_frame_start, tensor_pixel_valid, tensor_pixel_ready;
  logic signed [15:0][7:0] tensor_pixel; logic [13:0] tensor_pixels_emitted; logic [31:0] tensor_bytes_read;
  logic tensor32_busy, tensor32_done, tensor32_fault, tensor32_frame_start, tensor32_pixel_valid, tensor32_pixel_ready;
  logic signed [31:0][7:0] tensor32_pixel; logic [13:0] tensor32_pixels_emitted; logic [31:0] tensor32_bytes_read;
  logic tensor48_busy, tensor48_done, tensor48_fault, tensor48_frame_start, tensor48_pixel_valid, tensor48_pixel_ready;
  logic signed [47:0][7:0] tensor48_pixel; logic [13:0] tensor48_pixels_emitted; logic [31:0] tensor48_bytes_read;
  logic [31:0] rgb_araddr, tensor_araddr, tensor32_araddr, tensor48_araddr; logic [5:0] rgb_arid, tensor_arid, tensor32_arid, tensor48_arid;
  logic [7:0] rgb_arlen, tensor_arlen, tensor32_arlen, tensor48_arlen; logic [2:0] rgb_arsize, tensor_arsize, tensor32_arsize, tensor48_arsize;
  logic [1:0] rgb_arburst, tensor_arburst, tensor32_arburst, tensor48_arburst; logic rgb_arlock, rgb_arvalid, rgb_rready;
  logic tensor_arlock, tensor_arvalid, tensor_rready, tensor32_arlock, tensor32_arvalid, tensor32_rready, tensor48_arlock, tensor48_arvalid, tensor48_rready;
  logic [3:0] rgb_arcache, tensor_arcache, tensor32_arcache, tensor48_arcache, rgb_arqos, tensor_arqos, tensor32_arqos, tensor48_arqos, rgb_arregion, tensor_arregion, tensor32_arregion, tensor48_arregion;
  logic [2:0] rgb_arprot, tensor_arprot, tensor32_arprot, tensor48_arprot;
  logic [31:0] post_araddr; logic [5:0] post_arid; logic [7:0] post_arlen; logic [2:0] post_arsize;
  logic [1:0] post_arburst; logic post_arlock, post_arvalid, post_rready;
  logic [3:0] post_arcache, post_arqos, post_arregion; logic [2:0] post_arprot;
  logic [5:0] unused_rgb_rid, unused_tensor_rid;
  logic [63:0] unused_rgb_rdata, unused_tensor_rdata; logic [1:0] unused_rgb_rresp, unused_tensor_rresp;
  logic unused_rgb_rlast, unused_tensor_rlast;
  logic frame_start, pixel_valid, pixel_ready;
  logic signed [MAX_INPUT_CHANNELS-1:0][7:0] pixel_data;
  logic wide48_mode, pointwise_mode;
  logic [13:0] input_pixels; logic dma_busy, dma_done, dma_fault; logic [31:0] dma_bytes_read;
  logic output_valid, output_ready, protocol_error; logic signed [OUT_LANES-1:0][31:0] output_psum;
  logic [OUT_LANES-1:0] output_lane_enable_valid; logic [15:0] output_row, output_column;
  logic frame_input_done;
  logic quant_valid, quant_ready, quant_fault; logic signed [OUT_LANES-1:0][7:0] quant_data;
  logic [15:0] quant_row, quant_column; logic [13:0] output_write_addr;
  logic output_write_valid; logic signed [OUT_LANES-1:0][7:0] output_write_data;
  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // The relay and hash compatibility paths remain 16-lane wide, while the
  // DDR writer follows OUT_LANES so a 32-lane experiment cannot truncate its
  // upper half before the AXI writer sees it.
  logic [OUT_LANES*8-1:0] output_read_data;
  logic [127:0] relay_bank_read_data, hash_vector;
  logic [4:0] hash_byte_index;
  logic [31:0] hash_value, completed_hash; logic hash_active, last_output_seen; logic [13:0] output_vectors;
  logic store_busy, store_done, store_fault; logic [13:0] store_vectors_written;
  logic [31:0] store_bytes_written; logic [13:0] output_read_addr; logic output_read_enable;
  logic [13:0] relay_bank_read_addr; logic relay_bank_read_enable;
  logic [13:0] relay_pool_read_addr;
  logic relay_pool_read_enable;
  logic relay_pool_bank_owner;
  logic bank0_read_enable, bank1_read_enable;
  logic [OUTPUT_ADDR_W-1:0] bank0_read_addr, bank1_read_addr;
  logic [OUT_LANES*8-1:0] bank0_read_data, bank1_read_data;
  logic [OUT_LANES*8-1:0] relay_pool_read_data;
  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // Four compact execution descriptors let PS submit a layer/tile batch with
  // one doorbell. They deliberately reuse the existing resident weight bank;
  // weight DMA remains a separate model-load operation until bias/requant
  // metadata is added to the model descriptor format.
  localparam int DESC_DEPTH = 4;
  typedef enum logic [2:0] {DESC_IDLE, DESC_LOAD, DESC_START, DESC_WAIT} desc_state_t;
  desc_state_t desc_state;
  logic descriptor_active;
  logic [1:0] desc_select, desc_read_index;
  logic [2:0] desc_count;
  logic [31:0] desc_issued, desc_completed;
  logic [2:0] desc_mode_mem [0:DESC_DEPTH-1];
  logic [15:0] desc_width_mem [0:DESC_DEPTH-1], desc_height_mem [0:DESC_DEPTH-1];
  logic [31:0] desc_dma_source_mem [0:DESC_DEPTH-1], desc_dma_bytes_mem [0:DESC_DEPTH-1];
  logic [13:0] desc_dma_pixels_mem [0:DESC_DEPTH-1];
  logic [31:0] desc_store_destination_mem [0:DESC_DEPTH-1], desc_store_bytes_mem [0:DESC_DEPTH-1];
  logic desc_store_enable_mem [0:DESC_DEPTH-1], desc_store_pool_mem [0:DESC_DEPTH-1];
  logic [31:0] desc_store_stride_mem [0:DESC_DEPTH-1];
  logic [5:0] desc_store_valid_mem [0:DESC_DEPTH-1];
  logic [31:0] desc_qcfg_mem [0:DESC_DEPTH-1];
  logic [OUT_LANES-1:0] desc_lane_mask_mem [0:DESC_DEPTH-1];
  logic [3:0] desc_relay_control_mem [0:DESC_DEPTH-1];
  logic [1:0] desc_weight_bank_mem [0:DESC_DEPTH-1];
  logic [1:0] desc_param_bank_mem [0:DESC_DEPTH-1];
  logic [31:0] desc_task_cycles_mem [0:DESC_DEPTH-1];
  logic backend_complete, backend_fault;

  function automatic logic [31:0] fnv_step(input logic [31:0] current, input logic [7:0] byte_value);
    fnv_step = (current ^ {24'd0, byte_value}) * FNV_PRIME;
  endfunction
  assign wide48_mode = ENABLE_WIDE_MODES && ((layer_mode == 3) || (layer_mode == 5));
  assign pointwise_mode = (layer_mode == 5);
  assign relay_mode = ENABLE_RELAY && relay_enable && (layer_mode == 1);
  assign relay_stream_mode = relay_mode && !relay_pool_2x2;
  assign relay_pool_mode = relay_mode && relay_pool_2x2;
  assign backend_complete = (store_done && store_enable && running) ||
                            (post_done && running && layer_mode == 4) ||
                            (!store_enable && !running && done);
  assign backend_fault = protocol_error || quant_fault || dma_fault || store_fault;

  assign dma_busy = ENABLE_POSTPROCESS && (layer_mode == 4) ? post_busy :
                    relay_pool_mode ? relay_pool_busy :
                    relay_stream_mode ? relay_busy :
                    wide48_mode ? tensor48_busy :
                    ENABLE_WIDE_MODES && (layer_mode == 2) ? tensor32_busy :
                    (layer_mode == 1 ? tensor_busy : rgb_busy);
  assign dma_done = ENABLE_POSTPROCESS && (layer_mode == 4) ? post_done :
                    relay_pool_mode ? relay_pool_done :
                    relay_stream_mode ? relay_done :
                    wide48_mode ? tensor48_done :
                    ENABLE_WIDE_MODES && (layer_mode == 2) ? tensor32_done :
                    (layer_mode == 1 ? tensor_done : rgb_done);
  assign dma_fault = ENABLE_POSTPROCESS && (layer_mode == 4) ? post_fault :
                     relay_pool_mode ? relay_pool_fault :
                     relay_stream_mode ? relay_fault :
                     wide48_mode ? tensor48_fault :
                     ENABLE_WIDE_MODES && (layer_mode == 2) ? tensor32_fault :
                     (layer_mode == 1 ? tensor_fault : rgb_fault);
  assign dma_bytes_read = ENABLE_POSTPROCESS && (layer_mode == 4) ? dma_bytes :
                          relay_pool_mode ? {14'd0, relay_pool_pixels_emitted, 4'd0} :
                          relay_stream_mode ? {14'd0, relay_pixels_emitted, 4'd0} :
                          wide48_mode ? tensor48_bytes_read :
                          ENABLE_WIDE_MODES && (layer_mode == 2) ? tensor32_bytes_read :
                          (layer_mode == 1 ? tensor_bytes_read : {16'd0, rgb_bytes_read});
  assign input_pixels = ENABLE_POSTPROCESS && (layer_mode == 4) ? dma_pixels :
                        relay_pool_mode ? relay_pool_pixels_emitted :
                        relay_stream_mode ? relay_pixels_emitted :
                        wide48_mode ? tensor48_pixels_emitted :
                        ENABLE_WIDE_MODES && (layer_mode == 2) ? tensor32_pixels_emitted :
                        (layer_mode == 1 ? tensor_pixels_emitted : rgb_pixels_emitted);
  assign frame_start = relay_pool_mode ? relay_pool_frame_start :
                       relay_stream_mode ? relay_frame_start :
                       wide48_mode ? tensor48_frame_start :
                       ENABLE_WIDE_MODES && (layer_mode == 2) ? tensor32_frame_start :
                       (layer_mode == 1 ? tensor_frame_start : rgb_frame_start);
  assign pixel_valid = ENABLE_POSTPROCESS && (layer_mode == 4) ? 1'b0 :
                       relay_pool_mode ? relay_pool_pixel_valid :
                       relay_stream_mode ? relay_pixel_valid :
                       wide48_mode ? tensor48_pixel_valid :
                       ENABLE_WIDE_MODES && (layer_mode == 2) ? tensor32_pixel_valid :
                       (layer_mode == 1 ? tensor_pixel_valid : rgb_pixel_valid);
  assign relay_pixel_ready = relay_stream_mode ? pixel_ready : 1'b0;
  assign relay_pool_pixel_ready = relay_pool_mode ? pixel_ready : 1'b0;
  assign tensor_pixel_ready = ((layer_mode == 1) && !relay_mode) ? pixel_ready : 1'b0;
  assign tensor32_pixel_ready = (layer_mode == 2) ? pixel_ready : 1'b0;
  assign tensor48_pixel_ready = wide48_mode ? pixel_ready : 1'b0;
  assign rgb_pixel_ready = (layer_mode == 0) ? pixel_ready : 1'b0;
  assign weight_write_valid = ps_weight_write_valid | weight_dma_write_valid;
  always_comb begin
    if (weight_dma_write_valid) begin
      weight_write_oc = weight_dma_oc;
      weight_write_tap = weight_dma_tap;
      weight_write_ic_group = weight_dma_ic_group;
      weight_write_data = weight_dma_data;
    end else begin
      weight_write_oc = ps_weight_write_oc;
      weight_write_tap = ps_weight_write_tap;
      weight_write_ic_group = ps_weight_write_ic_group;
      weight_write_data = ps_weight_write_data;
    end
  end
  always_comb begin
    selected_pixel = '0;
    if (relay_pool_mode) begin
      for (int lane = 0; lane < 16; lane++) selected_pixel[lane] = relay_pool_pixel[lane];
      for (int lane = 16; lane < MAX_INPUT_CHANNELS; lane++) selected_pixel[lane] = input_zero_point[0];
    end else if (relay_stream_mode) begin
      for (int lane = 0; lane < 16; lane++) selected_pixel[lane] = relay_pixel[lane];
      for (int lane = 16; lane < MAX_INPUT_CHANNELS; lane++) selected_pixel[lane] = input_zero_point[0];
    end else if (layer_mode == 1) begin
      for (int lane = 0; lane < 16; lane++) selected_pixel[lane] = tensor_pixel[lane];
    end else if (ENABLE_WIDE_MODES && (layer_mode == 2)) begin
      for (int lane = 0; lane < 32; lane++) selected_pixel[lane] = tensor32_pixel[lane];
    end else if (wide48_mode) begin
      for (int lane = 0; lane < 48; lane++) selected_pixel[lane] = tensor48_pixel[lane];
    end else begin
      selected_pixel[0] = rgb_pixel[0]; selected_pixel[1] = rgb_pixel[1]; selected_pixel[2] = rgb_pixel[2];
      for (int lane = 3; lane < MAX_INPUT_CHANNELS; lane++) selected_pixel[lane] = input_zero_point[0];
    end
    if (weight_dma_busy) begin
      m_axi_araddr = weight_dma_araddr; m_axi_arid = weight_dma_arid; m_axi_arlen = weight_dma_arlen;
      m_axi_arsize = weight_dma_arsize; m_axi_arburst = weight_dma_arburst; m_axi_arlock = weight_dma_arlock;
      m_axi_arcache = weight_dma_arcache; m_axi_arprot = weight_dma_arprot; m_axi_arqos = weight_dma_arqos;
      m_axi_arregion = weight_dma_arregion; m_axi_arvalid = weight_dma_arvalid; m_axi_rready = weight_dma_rready;
    end else if (ENABLE_POSTPROCESS && (layer_mode == 4)) begin
      // Mode 4 is owned by the GAP/FC HP0 loader.  Without this explicit
      // branch the fallback below selects the RGB loader, which is not
      // started in postprocess mode and leaves the postprocess FSM stuck in
      // LOAD while its externally reported DMA byte count appears complete.
      // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL.
      m_axi_araddr = post_araddr; m_axi_arid = post_arid; m_axi_arlen = post_arlen;
      m_axi_arsize = post_arsize; m_axi_arburst = post_arburst; m_axi_arlock = post_arlock;
      m_axi_arcache = post_arcache; m_axi_arprot = post_arprot; m_axi_arqos = post_arqos;
      m_axi_arregion = post_arregion; m_axi_arvalid = post_arvalid; m_axi_rready = post_rready;
    end else if (relay_mode) begin
      m_axi_araddr = '0; m_axi_arid = '0; m_axi_arlen = '0;
      m_axi_arsize = '0; m_axi_arburst = '0; m_axi_arlock = 1'b0;
      m_axi_arcache = '0; m_axi_arprot = '0; m_axi_arqos = '0;
      m_axi_arregion = '0; m_axi_arvalid = 1'b0; m_axi_rready = 1'b0;
    end else if (wide48_mode) begin
      m_axi_araddr = tensor48_araddr; m_axi_arid = tensor48_arid; m_axi_arlen = tensor48_arlen;
      m_axi_arsize = tensor48_arsize; m_axi_arburst = tensor48_arburst; m_axi_arlock = tensor48_arlock;
      m_axi_arcache = tensor48_arcache; m_axi_arprot = tensor48_arprot; m_axi_arqos = tensor48_arqos;
      m_axi_arregion = tensor48_arregion; m_axi_arvalid = tensor48_arvalid; m_axi_rready = tensor48_rready;
    end else if (ENABLE_WIDE_MODES && (layer_mode == 2)) begin
      m_axi_araddr = tensor32_araddr; m_axi_arid = tensor32_arid; m_axi_arlen = tensor32_arlen;
      m_axi_arsize = tensor32_arsize; m_axi_arburst = tensor32_arburst; m_axi_arlock = tensor32_arlock;
      m_axi_arcache = tensor32_arcache; m_axi_arprot = tensor32_arprot; m_axi_arqos = tensor32_arqos;
      m_axi_arregion = tensor32_arregion; m_axi_arvalid = tensor32_arvalid; m_axi_rready = tensor32_rready;
    end else if (layer_mode == 1) begin
      m_axi_araddr = tensor_araddr; m_axi_arid = tensor_arid; m_axi_arlen = tensor_arlen;
      m_axi_arsize = tensor_arsize; m_axi_arburst = tensor_arburst; m_axi_arlock = tensor_arlock;
      m_axi_arcache = tensor_arcache; m_axi_arprot = tensor_arprot; m_axi_arqos = tensor_arqos;
      m_axi_arregion = tensor_arregion; m_axi_arvalid = tensor_arvalid; m_axi_rready = tensor_rready;
    end else begin
      m_axi_araddr = rgb_araddr; m_axi_arid = rgb_arid; m_axi_arlen = rgb_arlen;
      m_axi_arsize = rgb_arsize; m_axi_arburst = rgb_arburst; m_axi_arlock = rgb_arlock;
      m_axi_arcache = rgb_arcache; m_axi_arprot = rgb_arprot; m_axi_arqos = rgb_arqos;
      m_axi_arregion = rgb_arregion; m_axi_arvalid = rgb_arvalid; m_axi_rready = rgb_rready;
    end
  end
  assign pixel_data = selected_pixel;
  assign output_ready = quant_ready;

  gestureflow_hp0_rgb_loader rgb_loader (
    .clk(aclk), .rst_n(aresetn), .start(dma_start && (layer_mode == 0)), .clear(dma_clear),
    .source_addr(dma_source_addr), .byte_count(dma_bytes[15:0]), .pixel_count(dma_pixels),
    .busy(rgb_busy), .done(rgb_done), .fault(rgb_fault), .frame_start(rgb_frame_start),
    .pixel_valid(rgb_pixel_valid), .pixel_ready(rgb_pixel_ready), .pixel_rgb(rgb_pixel),
    .pixels_emitted(rgb_pixels_emitted), .bytes_read(rgb_bytes_read),
    .m_axi_araddr(rgb_araddr), .m_axi_arid(rgb_arid), .m_axi_arlen(rgb_arlen), .m_axi_arsize(rgb_arsize),
    .m_axi_arburst(rgb_arburst), .m_axi_arlock(rgb_arlock), .m_axi_arcache(rgb_arcache), .m_axi_arprot(rgb_arprot),
    .m_axi_arqos(rgb_arqos), .m_axi_arregion(rgb_arregion), .m_axi_arvalid(rgb_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(rgb_rready)
  );
  gestureflow_hp0_tensor_loader_banked #(.CHANNELS(16)) tensor_loader (
    .clk(aclk), .rst_n(aresetn), .start(dma_start && (layer_mode == 1) && !relay_mode), .clear(dma_clear),
    .source_addr(dma_source_addr), .byte_count(dma_bytes), .pixel_count(dma_pixels),
    .busy(tensor_busy), .done(tensor_done), .fault(tensor_fault), .frame_start(tensor_frame_start),
    .pixel_valid(tensor_pixel_valid), .pixel_ready(tensor_pixel_ready), .pixel_data(tensor_pixel),
    .pixels_emitted(tensor_pixels_emitted), .bytes_read(tensor_bytes_read),
    .m_axi_araddr(tensor_araddr), .m_axi_arid(tensor_arid), .m_axi_arlen(tensor_arlen), .m_axi_arsize(tensor_arsize),
    .m_axi_arburst(tensor_arburst), .m_axi_arlock(tensor_arlock), .m_axi_arcache(tensor_arcache), .m_axi_arprot(tensor_arprot),
    .m_axi_arqos(tensor_arqos), .m_axi_arregion(tensor_arregion), .m_axi_arvalid(tensor_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(tensor_rready)
  );
  generate
  if (ENABLE_RELAY) begin : gen_relay_loaders
    gestureflow_output_bank_relay_loader #(.CHANNELS(16), .ADDR_W(OUTPUT_ADDR_W), .FIFO_DEPTH(4)) relay_loader (
      .clk(aclk), .rst_n(aresetn), .start(dma_start && relay_stream_mode), .clear(dma_clear),
      .pixel_count(dma_pixels), .busy(relay_busy), .done(relay_done), .fault(relay_fault),
      .frame_start(relay_frame_start), .pixel_valid(relay_pixel_valid), .pixel_ready(relay_pixel_ready),
      .pixel_data(relay_pixel), .pixels_emitted(relay_pixels_emitted),
      .bank_read_enable(relay_bank_read_enable), .bank_read_addr(relay_bank_read_addr),
      .bank_read_data(relay_bank_read_data)
    );
    gestureflow_output_bank_pool_relay_loader #(.CHANNELS(16), .ADDR_W(OUTPUT_ADDR_W), .FIFO_DEPTH(4)) relay_pool_loader (
      .clk(aclk), .rst_n(aresetn), .start(dma_start && relay_pool_mode), .clear(dma_clear),
      .pixel_count(dma_pixels), .output_width(job_width),
      .busy(relay_pool_busy), .done(relay_pool_done), .fault(relay_pool_fault),
      .frame_start(relay_pool_frame_start), .pixel_valid(relay_pool_pixel_valid), .pixel_ready(relay_pool_pixel_ready),
      .pixel_data(relay_pool_pixel), .pixels_emitted(relay_pool_pixels_emitted),
      .bank_read_enable(relay_pool_read_enable), .bank_read_addr(relay_pool_read_addr),
      .bank_read_data(relay_pool_read_data[127:0])
    );
  end else begin : gen_no_relay_loaders
    assign relay_busy = 1'b0;
    assign relay_done = 1'b0;
    assign relay_fault = 1'b0;
    assign relay_frame_start = 1'b0;
    assign relay_pixel_valid = 1'b0;
    assign relay_pixel = '0;
    assign relay_pixels_emitted = '0;
    assign relay_pool_busy = 1'b0;
    assign relay_pool_done = 1'b0;
    assign relay_pool_fault = 1'b0;
    assign relay_pool_frame_start = 1'b0;
    assign relay_pool_pixel_valid = 1'b0;
    assign relay_pool_pixel = '0;
    assign relay_pool_pixels_emitted = '0;
    assign relay_bank_read_enable = 1'b0;
    assign relay_bank_read_addr = '0;
    assign relay_pool_read_enable = 1'b0;
    assign relay_pool_read_addr = '0;
  end
  endgenerate
  generate
  if (ENABLE_WIDE_MODES) begin : gen_wide_loaders
  gestureflow_hp0_tensor_loader_banked #(.CHANNELS(32)) tensor32_loader (
    .clk(aclk), .rst_n(aresetn), .start(dma_start && (layer_mode == 2)), .clear(dma_clear),
    .source_addr(dma_source_addr), .byte_count(dma_bytes), .pixel_count(dma_pixels),
    .busy(tensor32_busy), .done(tensor32_done), .fault(tensor32_fault), .frame_start(tensor32_frame_start),
    .pixel_valid(tensor32_pixel_valid), .pixel_ready(tensor32_pixel_ready), .pixel_data(tensor32_pixel),
    .pixels_emitted(tensor32_pixels_emitted), .bytes_read(tensor32_bytes_read),
    .m_axi_araddr(tensor32_araddr), .m_axi_arid(tensor32_arid), .m_axi_arlen(tensor32_arlen), .m_axi_arsize(tensor32_arsize),
    .m_axi_arburst(tensor32_arburst), .m_axi_arlock(tensor32_arlock), .m_axi_arcache(tensor32_arcache), .m_axi_arprot(tensor32_arprot),
    .m_axi_arqos(tensor32_arqos), .m_axi_arregion(tensor32_arregion), .m_axi_arvalid(tensor32_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(tensor32_rready)
  );
  gestureflow_hp0_tensor_loader_banked #(.CHANNELS(48)) tensor48_loader (
    .clk(aclk), .rst_n(aresetn), .start(dma_start && ((layer_mode == 3) || (layer_mode == 5))), .clear(dma_clear),
    .source_addr(dma_source_addr), .byte_count(dma_bytes), .pixel_count(dma_pixels),
    .busy(tensor48_busy), .done(tensor48_done), .fault(tensor48_fault), .frame_start(tensor48_frame_start),
    .pixel_valid(tensor48_pixel_valid), .pixel_ready(tensor48_pixel_ready), .pixel_data(tensor48_pixel),
    .pixels_emitted(tensor48_pixels_emitted), .bytes_read(tensor48_bytes_read),
    .m_axi_araddr(tensor48_araddr), .m_axi_arid(tensor48_arid), .m_axi_arlen(tensor48_arlen), .m_axi_arsize(tensor48_arsize),
    .m_axi_arburst(tensor48_arburst), .m_axi_arlock(tensor48_arlock), .m_axi_arcache(tensor48_arcache), .m_axi_arprot(tensor48_arprot),
    .m_axi_arqos(tensor48_arqos), .m_axi_arregion(tensor48_arregion), .m_axi_arvalid(tensor48_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(tensor48_rready)
  );
  end else begin : gen_no_wide_loaders
    assign tensor32_busy = 1'b0; assign tensor32_done = 1'b0; assign tensor32_fault = 1'b0;
    assign tensor32_frame_start = 1'b0; assign tensor32_pixel_valid = 1'b0;
    assign tensor32_pixel = '0; assign tensor32_pixels_emitted = '0; assign tensor32_bytes_read = '0;
    assign tensor32_araddr = '0; assign tensor32_arid = '0; assign tensor32_arlen = '0;
    assign tensor32_arsize = '0; assign tensor32_arburst = '0; assign tensor32_arlock = 1'b0;
    assign tensor32_arcache = '0; assign tensor32_arprot = '0; assign tensor32_arqos = '0;
    assign tensor32_arregion = '0; assign tensor32_arvalid = 1'b0; assign tensor32_rready = 1'b0;
    assign tensor48_busy = 1'b0; assign tensor48_done = 1'b0; assign tensor48_fault = 1'b0;
    assign tensor48_frame_start = 1'b0; assign tensor48_pixel_valid = 1'b0;
    assign tensor48_pixel = '0; assign tensor48_pixels_emitted = '0; assign tensor48_bytes_read = '0;
    assign tensor48_araddr = '0; assign tensor48_arid = '0; assign tensor48_arlen = '0;
    assign tensor48_arsize = '0; assign tensor48_arburst = '0; assign tensor48_arlock = 1'b0;
    assign tensor48_arcache = '0; assign tensor48_arprot = '0; assign tensor48_arqos = '0;
    assign tensor48_arregion = '0; assign tensor48_arvalid = 1'b0; assign tensor48_rready = 1'b0;
  end
  endgenerate
  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // Descriptor weight path.  It is idle in the legacy AXI-Lite mode and is
  // selected on the shared HP0 read channel only while this loader owns a
  // burst.  The MAC bank sees the same write protocol in either mode.
  gestureflow_hp0_weight_dma_loader #(.FIFO_BEATS(16), .MAX_TAPS(16), .MAX_GROUPS(12), .MAX_OUTPUT_LANES(OUT_LANES)) weight_dma_loader (
    .clk(aclk), .rst_n(aresetn), .start(weight_dma_start), .clear(weight_dma_clear),
    .source_addr(weight_dma_source), .byte_count(weight_dma_bytes),
    .taps_per_output(weight_dma_taps), .groups_per_tap(weight_dma_groups), .outputs_per_tile(weight_dma_outputs),
    .busy(weight_dma_busy), .done(weight_dma_done), .fault(weight_dma_fault),
    .bytes_read(weight_dma_bytes_read), .write_count(weight_dma_write_count),
    .weight_write_valid(weight_dma_write_valid), .weight_write_oc(weight_dma_oc),
    .weight_write_tap(weight_dma_tap), .weight_write_ic_group(weight_dma_ic_group),
    .weight_write_data(weight_dma_data), .m_axi_araddr(weight_dma_araddr),
    .m_axi_arid(weight_dma_arid), .m_axi_arlen(weight_dma_arlen), .m_axi_arsize(weight_dma_arsize),
    .m_axi_arburst(weight_dma_arburst), .m_axi_arlock(weight_dma_arlock),
    .m_axi_arcache(weight_dma_arcache), .m_axi_arprot(weight_dma_arprot),
    .m_axi_arqos(weight_dma_arqos), .m_axi_arregion(weight_dma_arregion),
    .m_axi_arvalid(weight_dma_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(weight_dma_rready)
  );
  generate
  if (ENABLE_POSTPROCESS) begin : gen_postprocess
  gestureflow_hp0_gap_fc #(.CHANNELS(64), .CLASSES(18), .ELEMENTS(144), .FC_GROUPS(16)) postprocess (
    .clk(aclk), .rst_n(aresetn), .start(post_start), .clear(post_clear),
    .source_addr(dma_source_addr), .byte_count(dma_bytes), .pixel_count(dma_pixels),
    .gap_multiplier(post_gap_multiplier), .gap_right_shift(post_gap_right_shift),
    .gap_input_zero_point(post_gap_input_zero_point), .gap_output_zero_point(post_gap_output_zero_point),
    .fc_output_zero_point(post_fc_output_zero_point), .fc_weight_write_valid(weight_write_valid),
    .fc_weight_write_class(weight_write_oc), .fc_weight_write_group(weight_write_ic_group[3:0]),
    .fc_weight_write_data(weight_write_data), .fc_bias(bias[17:0]),
    .fc_multiplier(requant_multiplier[17:0]), .fc_right_shift(requant_right_shift[17:0]),
    .busy(post_busy), .done(post_done), .fault(post_fault), .cycles(post_cycles),
    .gap_fnv1a(post_gap_fnv1a), .fc_fnv1a(post_fc_fnv1a), .predicted_class(post_predicted_class),
    .gap_values_done(post_gap_values_done), .fc_values_done(post_fc_values_done),
    .debug_gap_sum0(post_debug_gap_sum0), .debug_gap_sum6(post_debug_gap_sum6),
    .debug_fc_value(post_debug_fc_value),
    .m_axi_araddr(post_araddr), .m_axi_arid(post_arid), .m_axi_arlen(post_arlen), .m_axi_arsize(post_arsize),
    .m_axi_arburst(post_arburst), .m_axi_arlock(post_arlock), .m_axi_arcache(post_arcache), .m_axi_arprot(post_arprot),
    .m_axi_arqos(post_arqos), .m_axi_arregion(post_arregion), .m_axi_arvalid(post_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(post_rready)
  );
  end else begin : gen_no_postprocess
    assign post_busy = 1'b0; assign post_done = 1'b0; assign post_fault = 1'b0;
    assign post_cycles = '0; assign post_gap_fnv1a = '0; assign post_fc_fnv1a = '0;
    assign post_predicted_class = '0; assign post_gap_values_done = '0; assign post_fc_values_done = '0;
    assign post_debug_gap_sum0 = '0; assign post_debug_gap_sum6 = '0; assign post_debug_fc_value = '0;
    assign post_araddr = '0; assign post_arid = '0; assign post_arlen = '0; assign post_arsize = '0;
    assign post_arburst = '0; assign post_arlock = 1'b0; assign post_arcache = '0;
    assign post_arprot = '0; assign post_arqos = '0; assign post_arregion = '0;
    assign post_arvalid = 1'b0; assign post_rready = 1'b0;
  end
  endgenerate
  assign stream_weight_write_ic_group = STREAM_WEIGHT_GROUP_W'(weight_write_ic_group);
  gestureflow_conv4x4_cin_same_stream #(.IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT), .INPUT_CHANNELS(MAX_INPUT_CHANNELS), .OUT_LANES(OUT_LANES)) stream (
    .clk(aclk), .rst_n(aresetn), .image_width(job_width), .image_height(job_height), .pointwise_mode(pointwise_mode), .frame_start(frame_start), .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
    // RGB has 3 active input channels and therefore needs one 4-lane group;
    // the fourth lane is masked by input_lane_enable.  Body layers use the
    // full 16/32/48-channel group counts below.  PROJECT_LOCAL_SELF_RESEARCH.
    .pixel_data(pixel_data), .input_zero_point(input_zero_point),
    .input_group_count(wide48_mode ? 5'd12 : (layer_mode == 2 ? 5'd8 : (layer_mode == 1 ? 5'd4 : 5'd1))),
    .input_lane_enable(layer_mode == 0 ? 4'b0111 : 4'hf),
    .weight_write_valid(weight_write_valid), .weight_write_oc(weight_write_oc[$clog2(OUT_LANES)-1:0]), .weight_write_tap(weight_write_tap),
    .weight_write_ic_group(stream_weight_write_ic_group), .weight_write_data(weight_write_data), .weight_bank_select(weight_bank_select), .read_bank_select(weight_read_bank_select), .bias(bias[OUT_LANES-1:0]),
    .output_lane_enable(output_lane_enable), .output_valid(output_valid), .output_ready(output_ready),
    .output_psum(output_psum), .output_lane_enable_valid(output_lane_enable_valid), .output_row(output_row),
    .output_column(output_column), .busy(), .protocol_error(protocol_error), .frame_input_done(frame_input_done)
  );
  gestureflow_requant_relu #(.LANES(OUT_LANES), .PARALLEL_LANES(REQUANT_PARALLEL_LANES)) requant (
    .clk(aclk), .rst_n(aresetn), .in_valid(output_valid), .in_ready(quant_ready), .in_psum(output_psum),
    .in_lane_enable(output_lane_enable_valid), .enable(requant_enable), .relu_enable(requant_relu_enable),
    .output_zero_point(output_zero_point), .multiplier(requant_multiplier[OUT_LANES-1:0]), .right_shift(requant_right_shift[OUT_LANES-1:0]),
    .out_valid(quant_valid), .out_ready(1'b1), .out_data(quant_data), .out_lane_enable(), .config_error(quant_fault)
  );
  assign output_write_valid = quant_valid;
  assign output_write_addr = OUTPUT_ADDR_W'(int'(quant_row) * int'(job_width) + int'(quant_column));
  assign output_write_data = quant_data;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      quant_row <= '0;
      quant_column <= '0;
    end else if (output_valid && output_ready) begin
      quant_row <= output_row;
      quant_column <= output_column;
    end
  end
  assign relay_pool_bank_owner = ENABLE_RELAY && relay_pool_busy;
  generate
  if (ENABLE_RELAY) begin : gen_relay_banks
    // Two independent two-port banks. Read muxes are mutually exclusive:
    // pool mode owns the relay_read_bank_select bank, otherwise the writer reads
    // output_write_bank_select and the relay loader reads relay_read_bank_select.
    assign bank0_read_enable = relay_pool_bank_owner ?
      (relay_read_bank_select == 1'b0 ? relay_pool_read_enable : 1'b0) :
      ((output_write_bank_select == 1'b0 ? output_read_enable : 1'b0) ||
       (relay_read_bank_select == 1'b0 ? relay_bank_read_enable : 1'b0));
    assign bank0_read_addr = relay_pool_bank_owner ? relay_pool_read_addr :
      (output_write_bank_select == 1'b0 ? output_read_addr : relay_bank_read_addr);
    assign bank1_read_enable = relay_pool_bank_owner ?
      (relay_read_bank_select == 1'b1 ? relay_pool_read_enable : 1'b0) :
      ((output_write_bank_select == 1'b1 ? output_read_enable : 1'b0) ||
       (relay_read_bank_select == 1'b1 ? relay_bank_read_enable : 1'b0));
    assign bank1_read_addr = relay_pool_bank_owner ? relay_pool_read_addr :
      (output_write_bank_select == 1'b1 ? output_read_addr : relay_bank_read_addr);
    assign output_read_data = (output_write_bank_select == 1'b0) ? bank0_read_data : bank1_read_data;
    assign relay_bank_read_data = (relay_read_bank_select == 1'b0) ? bank0_read_data[127:0] : bank1_read_data[127:0];
    assign relay_pool_read_data = (relay_read_bank_select == 1'b0) ? bank0_read_data : bank1_read_data;
    gestureflow_output_bank #(.ADDR_W(OUTPUT_ADDR_W), .DATA_W(OUT_LANES*8)) bank0 (
      .clk(aclk), .write_enable(output_write_valid && (output_write_bank_select == 1'b0)),
      .write_addr(output_write_addr), .write_data(quant_data),
      .read_enable(bank0_read_enable), .read_addr(bank0_read_addr), .read_data(bank0_read_data)
    );
    gestureflow_output_bank #(.ADDR_W(OUTPUT_ADDR_W), .DATA_W(OUT_LANES*8)) bank1 (
      .clk(aclk), .write_enable(output_write_valid && (output_write_bank_select == 1'b1)),
      .write_addr(output_write_addr), .write_data(quant_data),
      .read_enable(bank1_read_enable), .read_addr(bank1_read_addr), .read_data(bank1_read_data)
    );
  end else begin : gen_single_bank
    assign bank0_read_enable = output_read_enable;
    assign bank0_read_addr = output_read_addr;
    assign bank1_read_enable = 1'b0;
    assign bank1_read_addr = '0;
    assign output_read_data = bank0_read_data;
    assign relay_bank_read_data = '0;
    assign relay_pool_read_data = '0;
    gestureflow_output_bank #(.ADDR_W(OUTPUT_ADDR_W), .DATA_W(OUT_LANES*8)) bank0 (
      .clk(aclk), .write_enable(output_write_valid),
      .write_addr(output_write_addr), .write_data(quant_data),
      .read_enable(bank0_read_enable), .read_addr(bank0_read_addr), .read_data(bank0_read_data)
    );
    assign bank1_read_data = '0;
  end
  endgenerate
  gestureflow_hp0_tensor_writer #(.VECTOR_COUNT(OUTPUTS), .VECTOR_ADDR_W(OUTPUT_ADDR_W), .VECTOR_BYTES(OUT_LANES), .INPUT_WIDTH(IMAGE_WIDTH)) store (
    .clk(aclk), .rst_n(aresetn), .start(store_start), .clear(store_clear), .destination_addr(store_destination),
    .pool_2x2(store_pool_2x2), .vector_count(dma_pixels), .input_width(job_width),
    .destination_stride_bytes(store_stride_bytes), .valid_vector_bytes(store_valid_bytes),
    .byte_count(store_bytes), .busy(store_busy), .done(store_done), .fault(store_fault), .bank_read_addr(output_read_addr),
    .bank_read_enable(output_read_enable), .bank_read_data(output_read_data), .vectors_written(store_vectors_written),
    .bytes_written(store_bytes_written), .m_axi_awaddr(m_axi_awaddr), .m_axi_awid(m_axi_awid), .m_axi_awlen(m_axi_awlen),
    .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock), .m_axi_awcache(m_axi_awcache),
    .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos), .m_axi_awregion(m_axi_awregion), .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
    .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready), .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
    .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
  );

  assign s_axi_awready = !aw_seen && !s_axi_bvalid;
  assign s_axi_wready = !w_seen && !s_axi_bvalid;
  assign s_axi_arready = !s_axi_rvalid;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      awaddr<='0; wdata<='0; wstrb<='0; aw_seen<=0; w_seen<=0; s_axi_bvalid<=0; s_axi_bresp<=0;
      s_axi_rvalid<=0; s_axi_rresp<=0; s_axi_rdata<=0; running<=0; done<=0; fault<=0; layer_mode<=0;
      dma_start<=0; dma_clear<=0; post_start<=0; post_clear<=0; store_start<=0; store_clear<=0; store_enable<=0; store_pool_2x2<=0; dma_source_addr<=0;
      dma_bytes<=0; dma_pixels<=0; store_destination<=0; store_bytes<=0; layer_cycles<=0;
      job_width<=16'(IMAGE_WIDTH); job_height<=16'(IMAGE_HEIGHT);
      store_stride_bytes<=0; store_valid_bytes<=0;
      relay_enable<=1'b0; relay_read_bank_select<=1'b0; output_write_bank_select<=1'b0; relay_pool_2x2<=1'b0;
      ps_weight_write_valid<=0; ps_weight_write_oc<=0; ps_weight_write_tap<=0; ps_weight_write_ic_group<=0; ps_weight_write_data<=0;
      weight_dma_start<=0; weight_dma_clear<=0; weight_dma_source<=0; weight_dma_bytes<=0; weight_dma_taps<=0; weight_dma_groups<=0; weight_dma_outputs<=0;
      bias<='0; bias_index<=0; input_zero_point<='0; output_zero_point<=0; output_lane_enable<='1; weight_bank_select<=0; weight_read_bank_select<=0; param_bank_select<=0;
      requant_enable<=0; requant_relu_enable<=0; requant_index<=0; requant_multiplier<='0; requant_right_shift<='0;
      post_gap_multiplier<=0; post_gap_right_shift<=0; post_gap_input_zero_point<=0; post_gap_output_zero_point<=0; post_fc_output_zero_point<=0;
      hash_active<=0; last_output_seen<=0; hash_vector<='0; hash_byte_index<=0; hash_value<=FNV_OFFSET;
      completed_hash<=FNV_OFFSET; output_vectors<=0;
      weight_key<=0; weight_resident_key<=0; weight_write_count<=0; weight_hit_count<=0;
      weight_miss_count<=0; weight_bytes<=0; weight_keyed_mode<=0; weight_resident_valid<=0; weight_key_hit<=0;
      desc_state<=DESC_IDLE; descriptor_active<=0; desc_select<=0; desc_read_index<=0; desc_count<=0;
      desc_issued<=0; desc_completed<=0;
      for (int bank_index=0; bank_index<2; bank_index++) begin
        for (int parameter_index=0; parameter_index<CTRL_LANES; parameter_index++) begin
          bias_bank[bank_index][parameter_index]<=0;
          requant_multiplier_bank[bank_index][parameter_index]<=0;
          requant_right_shift_bank[bank_index][parameter_index]<=0;
        end
      end
      for (int desc_slot=0; desc_slot<DESC_DEPTH; desc_slot++) begin
        desc_mode_mem[desc_slot]<=0; desc_width_mem[desc_slot]<=0; desc_height_mem[desc_slot]<=0;
        desc_dma_source_mem[desc_slot]<=0; desc_dma_bytes_mem[desc_slot]<=0; desc_dma_pixels_mem[desc_slot]<=0;
        desc_store_destination_mem[desc_slot]<=0; desc_store_bytes_mem[desc_slot]<=0;
        desc_store_enable_mem[desc_slot]<=0; desc_store_pool_mem[desc_slot]<=0;
        desc_store_stride_mem[desc_slot]<=0; desc_store_valid_mem[desc_slot]<=0;
        desc_qcfg_mem[desc_slot]<=0; desc_lane_mask_mem[desc_slot]<=0; desc_relay_control_mem[desc_slot]<=0;
        desc_weight_bank_mem[desc_slot]<=0; desc_param_bank_mem[desc_slot]<=0; desc_task_cycles_mem[desc_slot]<=0;
      end
    end else begin
      ps_weight_write_valid<=0; weight_dma_start<=0; weight_dma_clear<=0; dma_start<=0; dma_clear<=0; post_start<=0; post_clear<=0; store_start<=0; store_clear<=0;
      // Descriptor mode owns the existing backend only after CONTROL.doorbell.
      // LOAD clears the reusable pipeline, START launches it with the stable
      // descriptor registers from the prior cycle, and WAIT advances only on
      // a real writer/postprocess completion.
      case (desc_state)
        DESC_LOAD: begin
          layer_mode <= desc_mode_mem[desc_read_index];
          job_width <= desc_width_mem[desc_read_index];
          job_height <= desc_height_mem[desc_read_index];
          dma_source_addr <= desc_dma_source_mem[desc_read_index];
          dma_bytes <= desc_dma_bytes_mem[desc_read_index];
          dma_pixels <= desc_dma_pixels_mem[desc_read_index];
          store_destination <= desc_store_destination_mem[desc_read_index];
          store_bytes <= desc_store_bytes_mem[desc_read_index];
          store_enable <= desc_store_enable_mem[desc_read_index];
          store_pool_2x2 <= desc_store_pool_mem[desc_read_index];
          store_stride_bytes <= desc_store_stride_mem[desc_read_index];
          store_valid_bytes <= desc_store_valid_mem[desc_read_index];
          weight_bank_select <= desc_weight_bank_mem[desc_read_index][0];
          for (int parameter_index = 0; parameter_index < CTRL_LANES; parameter_index++) begin
            bias[parameter_index] <= bias_bank[desc_param_bank_mem[desc_read_index][0]][parameter_index];
            requant_multiplier[parameter_index] <= requant_multiplier_bank[desc_param_bank_mem[desc_read_index][0]][parameter_index];
            requant_right_shift[parameter_index] <= requant_right_shift_bank[desc_param_bank_mem[desc_read_index][0]][parameter_index];
          end
          input_zero_point <= {MAX_INPUT_CHANNELS{desc_qcfg_mem[desc_read_index][7:0]}};
          output_zero_point <= desc_qcfg_mem[desc_read_index][15:8];
          requant_enable <= desc_qcfg_mem[desc_read_index][16];
          requant_relu_enable <= desc_qcfg_mem[desc_read_index][17];
          output_lane_enable <= desc_lane_mask_mem[desc_read_index];
          relay_enable <= desc_relay_control_mem[desc_read_index][0];
          relay_read_bank_select <= desc_relay_control_mem[desc_read_index][1];
          output_write_bank_select <= desc_relay_control_mem[desc_read_index][2];
          relay_pool_2x2 <= desc_relay_control_mem[desc_read_index][3];
          dma_clear <= 1'b1; post_clear <= 1'b1; store_clear <= 1'b1;
          hash_active <= 1'b0; last_output_seen <= 1'b0; hash_value <= FNV_OFFSET;
          completed_hash <= FNV_OFFSET; layer_cycles <= 0; output_vectors <= 0; done <= 0;
          desc_state <= DESC_START;
        end
        DESC_START: begin
          if (weight_dma_busy || (weight_keyed_mode && !weight_resident_valid)) begin
            fault <= 1'b1; descriptor_active <= 1'b0; desc_state <= DESC_IDLE;
          end else begin
            running <= 1'b1; done <= 1'b0; fault <= 1'b0;
            if (layer_mode == 4) post_start <= 1'b1; else dma_start <= 1'b1;
            desc_issued <= desc_issued + 1'b1;
            desc_state <= DESC_WAIT;
          end
        end
        DESC_WAIT: begin
          if (backend_fault) begin
            descriptor_active <= 1'b0; desc_state <= DESC_IDLE;
          end else if (backend_complete) begin
            desc_completed <= desc_completed + 1'b1;
            desc_task_cycles_mem[desc_read_index] <= layer_cycles;
            if (desc_read_index + 1'b1 < desc_count) begin
              desc_read_index <= desc_read_index + 1'b1;
              desc_state <= DESC_LOAD;
            end else begin
              descriptor_active <= 1'b0;
              desc_state <= DESC_IDLE;
            end
          end
        end
        default: begin end
      endcase
      if (running) layer_cycles <= layer_cycles + 1'b1;
      if (protocol_error || quant_fault || dma_fault || store_fault || weight_dma_fault) fault <= 1'b1;
      if (hash_active) begin
        hash_value <= fnv_step(hash_value, hash_vector[hash_byte_index*8 +: 8]);
        if (hash_byte_index == 15) begin
          completed_hash <= fnv_step(hash_value, hash_vector[hash_byte_index*8 +: 8]); hash_active <= 0;
          if (last_output_seen) begin
            if (store_enable) store_start <= 1'b1; else begin running<=0; done<=1; end
          end
        end else hash_byte_index <= hash_byte_index + 1'b1;
      end
      if (output_write_valid) begin
        if (hash_active) fault <= 1'b1;
        hash_vector <= output_write_data[15:0]; hash_byte_index<=0; hash_active<=1; output_vectors<=output_vectors+1'b1;
        if (output_vectors == 14'(dma_pixels-1'b1)) last_output_seen<=1;
      end
      if (s_axi_awvalid && s_axi_awready) begin awaddr<=s_axi_awaddr; aw_seen<=1; end
      if (s_axi_wvalid && s_axi_wready) begin wdata<=s_axi_wdata; wstrb<=s_axi_wstrb; w_seen<=1; end
      if (aw_seen && w_seen && !s_axi_bvalid) begin
        case (awaddr[11:0])
          CONTROL: begin
            if (wdata[0]) begin
              running<=0; done<=0; fault<=0; dma_clear<=1; post_clear<=1; store_clear<=1;
              hash_active<=0; last_output_seen<=0; hash_value<=FNV_OFFSET; completed_hash<=FNV_OFFSET;
              layer_cycles<=0; output_vectors<=0; descriptor_active<=0; desc_state<=DESC_IDLE;
            end
            if (wdata[1]) begin
              if (descriptor_active || running || dma_busy || store_busy || hash_active) fault<=1;
              else if (weight_keyed_mode && !weight_resident_valid) fault<=1;
              else begin running<=1; done<=0; fault<=0; if (layer_mode == 4) post_start<=1; else dma_start<=1; hash_active<=0; last_output_seen<=0; hash_value<=FNV_OFFSET; completed_hash<=FNV_OFFSET; layer_cycles<=0; output_vectors<=0; end
            end
          end
          LAYER_MODE: if (running || dma_busy || store_busy) fault<=1; else layer_mode<=wdata[2:0];
          JOB_WIDTH: if (running || dma_busy || store_busy) fault<=1; else job_width<=wdata[15:0];
          JOB_HEIGHT: if (running || dma_busy || store_busy) fault<=1; else job_height<=wdata[15:0];
          OUTPUT_LANE_MASK: if (running || dma_busy || store_busy) fault<=1; else output_lane_enable<=wdata[OUT_LANES-1:0];
          STORE_STRIDE: if (running || store_busy) fault<=1; else store_stride_bytes<=wdata;
          STORE_VALID_BYTES: if (running || store_busy) fault<=1; else store_valid_bytes<=wdata[5:0];
          RELAY_CONTROL: if (running || dma_busy || store_busy || descriptor_active) fault<=1; else begin
            relay_enable<=wdata[0]; relay_read_bank_select<=wdata[1]; output_write_bank_select<=wdata[2]; relay_pool_2x2<=wdata[3];
          end
          QCFG: if (running || dma_busy) fault<=1; else begin input_zero_point<={MAX_INPUT_CHANNELS{wdata[7:0]}}; output_zero_point<=wdata[15:8]; requant_enable<=wdata[16]; requant_relu_enable<=wdata[17]; end
          WEIGHT_KEY: if (running || dma_busy || store_busy) fault<=1; else begin
            weight_key<=wdata; weight_keyed_mode<=1;
            weight_key_hit<=weight_resident_valid && (weight_resident_key == wdata);
            if (weight_resident_valid && (weight_resident_key == wdata)) begin
              weight_hit_count<=weight_hit_count+1'b1;
            end else begin
              weight_miss_count<=weight_miss_count+1'b1; weight_resident_valid<=0;
            end
          end
          WCTRL: if (running || dma_busy || weight_dma_busy || (weight_keyed_mode && weight_key_hit)) fault<=1; else begin ps_weight_write_oc<=wdata[4:0]; ps_weight_write_tap<=wdata[8:5]; ps_weight_write_ic_group<=wdata[13:9]; end
          WDATA: if (running || dma_busy || weight_dma_busy || (weight_keyed_mode && weight_key_hit)) fault<=1; else ps_weight_write_data<=wdata;
          BIDX: if (running || dma_busy || (weight_keyed_mode && weight_key_hit)) fault<=1; else bias_index<=wdata[4:0];
          BDATA: if (running || dma_busy || (weight_keyed_mode && weight_key_hit)) fault<=1; else begin bias[bias_index]<=wdata; bias_bank[param_bank_select][bias_index]<=wdata; end
          RQIDX: if (running || dma_busy || (weight_keyed_mode && weight_key_hit)) fault<=1; else requant_index<=wdata[4:0];
          RQMULT: if (running || dma_busy || (weight_keyed_mode && weight_key_hit)) fault<=1; else begin requant_multiplier[requant_index]<=wdata; requant_multiplier_bank[param_bank_select][requant_index]<=wdata; end
          RQSHIFT: if (running || dma_busy || (weight_keyed_mode && weight_key_hit)) fault<=1; else begin requant_right_shift[requant_index]<=wdata[5:0]; requant_right_shift_bank[param_bank_select][requant_index]<=wdata[5:0]; end
          WEIGHT_BANK_SELECT: if (running || dma_busy || store_busy || descriptor_active) fault<=1; else weight_bank_select<=wdata[0];
          WEIGHT_READ_BANK_SELECT: if (running || dma_busy || store_busy || descriptor_active) fault<=1; else weight_read_bank_select<=wdata[0];
          PARAM_BANK_SELECT: if (running || dma_busy || store_busy || descriptor_active) fault<=1; else param_bank_select<=wdata[0];
          WEIGHT_COMMIT: if (running || dma_busy || store_busy) fault<=1; else if (wdata[0]) begin
            if (!weight_keyed_mode) fault<=1;
            else if (!weight_key_hit) begin weight_resident_key<=weight_key; weight_resident_valid<=1; end
          end
          WEIGHT_DMA_SOURCE: if (running || dma_busy || weight_dma_busy || store_busy) fault<=1; else weight_dma_source<=wdata;
          WEIGHT_DMA_BYTES: if (running || dma_busy || weight_dma_busy || store_busy) fault<=1; else weight_dma_bytes<=wdata;
          WEIGHT_DMA_CFG: if (running || dma_busy || weight_dma_busy || store_busy) fault<=1; else begin weight_dma_taps<=wdata[4:0]; weight_dma_groups<=wdata[12:8]; weight_dma_outputs<=wdata[21:16]; end
          WEIGHT_DMA_CONTROL: begin
            if (wdata[0]) begin weight_dma_clear<=1; end
            if (wdata[1]) begin
              if (running || dma_busy || weight_dma_busy || store_busy || hash_active) fault<=1;
              else weight_dma_start<=1;
            end
          end
          DMA_SOURCE: if (running || dma_busy) fault<=1; else dma_source_addr<=wdata;
          DMA_BYTES: if (running || dma_busy) fault<=1; else dma_bytes<=wdata;
          DMA_PIXELS: if (running || dma_busy) fault<=1; else dma_pixels<=wdata[13:0];
          STORE_DESTINATION: if (running || store_busy) fault<=1; else store_destination<=wdata;
          STORE_BYTES: if (running || store_busy) fault<=1; else store_bytes<=wdata;
          STORE_CONTROL: if (running || store_busy) fault<=1; else begin store_enable<=wdata[0]; store_pool_2x2<=wdata[1]; end
          POST_GAP_MULT: if (running) fault<=1; else post_gap_multiplier<=wdata;
          POST_GAP_SHIFT: if (running) fault<=1; else post_gap_right_shift<=wdata[5:0];
          POST_QCFG: if (running) fault<=1; else begin post_gap_input_zero_point<=wdata[7:0]; post_gap_output_zero_point<=wdata[15:8]; post_fc_output_zero_point<=wdata[23:16]; end
          // Descriptor staging is intentionally separate from the legacy
          // registers. Commit the data by writing DESC_CONTROL.doorbell;
          // the PL then replays it without per-layer CONTROL.start writes.
          DESC_SELECT: if (descriptor_active || running) fault<=1; else desc_select<=wdata[1:0];
          DESC_MODE: if (descriptor_active || running) fault<=1; else desc_mode_mem[desc_select]<=wdata[2:0];
          DESC_JOB_SHAPE: if (descriptor_active || running) fault<=1; else begin desc_width_mem[desc_select]<=wdata[15:0]; desc_height_mem[desc_select]<=wdata[31:16]; end
          DESC_DMA_SOURCE: if (descriptor_active || running) fault<=1; else desc_dma_source_mem[desc_select]<=wdata;
          DESC_DMA_BYTES: if (descriptor_active || running) fault<=1; else desc_dma_bytes_mem[desc_select]<=wdata;
          DESC_DMA_PIXELS: if (descriptor_active || running) fault<=1; else desc_dma_pixels_mem[desc_select]<=wdata[13:0];
          DESC_STORE_DESTINATION: if (descriptor_active || running) fault<=1; else desc_store_destination_mem[desc_select]<=wdata;
          DESC_STORE_BYTES: if (descriptor_active || running) fault<=1; else desc_store_bytes_mem[desc_select]<=wdata;
          DESC_STORE_CONTROL: if (descriptor_active || running) fault<=1; else begin desc_store_enable_mem[desc_select]<=wdata[0]; desc_store_pool_mem[desc_select]<=wdata[1]; end
          DESC_STORE_STRIDE: if (descriptor_active || running) fault<=1; else desc_store_stride_mem[desc_select]<=wdata;
          DESC_STORE_VALID_BYTES: if (descriptor_active || running) fault<=1; else desc_store_valid_mem[desc_select]<=wdata[5:0];
          DESC_QCFG: if (descriptor_active || running) fault<=1; else desc_qcfg_mem[desc_select]<=wdata;
          DESC_LANE_MASK: if (descriptor_active || running) fault<=1; else desc_lane_mask_mem[desc_select]<=wdata[OUT_LANES-1:0];
          DESC_RELAY_CONTROL: if (descriptor_active || running) fault<=1; else desc_relay_control_mem[desc_select]<=wdata[3:0];
          DESC_WEIGHT_BANK: if (descriptor_active || running) fault<=1; else desc_weight_bank_mem[desc_select]<=wdata[1:0];
          DESC_PARAM_BANK: if (descriptor_active || running) fault<=1; else desc_param_bank_mem[desc_select]<=wdata[1:0];
          DESC_COUNT: if (descriptor_active || running || wdata > 32'd4) fault<=1; else desc_count<=wdata[2:0];
          DESC_CONTROL: begin
            if (wdata[0]) begin descriptor_active<=0; desc_state<=DESC_IDLE; desc_issued<=0; desc_completed<=0; done<=0; end
            if (wdata[1]) begin
              if (descriptor_active || running || dma_busy || store_busy || hash_active || weight_dma_busy || desc_count==0) fault<=1;
              else begin descriptor_active<=1; desc_read_index<=0; desc_issued<=0; desc_completed<=0; done<=0; fault<=0; desc_state<=DESC_LOAD; end
            end
          end
          default: begin end
        endcase
        if (awaddr[11:0] == WDATA && !(running || dma_busy) && !(weight_keyed_mode && weight_key_hit)) begin
          ps_weight_write_valid<=1; weight_write_count<=weight_write_count+1'b1; weight_bytes<=weight_bytes+32'd4;
        end
        s_axi_bvalid<=1; s_axi_bresp<=0; aw_seen<=0; w_seen<=0;
      end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
      if (store_done && store_enable && running) begin
        running<=0;
        if (!descriptor_active || (desc_state == DESC_WAIT && desc_read_index + 1'b1 >= desc_count)) done<=1;
        else done<=0;
      end
      if (post_done && running && layer_mode == 4) begin
        running<=0; completed_hash<=post_fc_fnv1a;
        if (!descriptor_active || (desc_state == DESC_WAIT && desc_read_index + 1'b1 >= desc_count)) done<=1;
        else done<=0;
      end
      if (s_axi_arvalid && s_axi_arready) begin
        case (s_axi_araddr[11:0])
          MAGIC: s_axi_rdata<=32'h47464e50; VERSION: s_axi_rdata<=32'h00040004;
          STATUS: s_axi_rdata<={24'd0,frame_input_done,protocol_error||quant_fault,hash_active,1'b0,dma_busy,fault,done,running};
          QCFG: s_axi_rdata<={14'd0,requant_relu_enable,requant_enable,output_zero_point,input_zero_point[0]};
          LAYER_MODE: s_axi_rdata<={29'd0,layer_mode}; JOB_WIDTH:s_axi_rdata<={16'd0,job_width}; JOB_HEIGHT:s_axi_rdata<={16'd0,job_height}; OUTPUT_LANE_MASK:s_axi_rdata<={{(32-OUT_LANES){1'b0}},output_lane_enable}; RELAY_CONTROL:s_axi_rdata<={28'd0,relay_pool_2x2,output_write_bank_select,relay_read_bank_select,relay_enable}; CYCLES:s_axi_rdata<=layer_cycles;
          INPUT_PIXELS:s_axi_rdata<={18'd0,input_pixels}; OUTPUT_VECTORS:s_axi_rdata<={18'd0,output_vectors}; OUTPUT_FNV1A:s_axi_rdata<=completed_hash;
          DMA_SOURCE:s_axi_rdata<=dma_source_addr; DMA_BYTES:s_axi_rdata<=dma_bytes; DMA_PIXELS:s_axi_rdata<={18'd0,dma_pixels};
          // Keep the established [31:3] byte-count field wide enough for a
          // 96x96x16 activation (147456 bytes); the assignment naturally
          // discards only the unused upper three bits.
          DMA_STATUS:s_axi_rdata<={dma_bytes_read[28:0],dma_fault,dma_done,dma_busy};
          STORE_DESTINATION:s_axi_rdata<=store_destination; STORE_BYTES:s_axi_rdata<=store_bytes; STORE_CONTROL:s_axi_rdata<={30'd0,store_pool_2x2,store_enable}; STORE_STRIDE:s_axi_rdata<=store_stride_bytes; STORE_VALID_BYTES:s_axi_rdata<={26'd0,store_valid_bytes};
          STORE_STATUS:s_axi_rdata<={store_bytes_written[28:0],store_fault,store_done,store_busy};
          POST_GAP_MULT:s_axi_rdata<=post_gap_multiplier; POST_GAP_SHIFT:s_axi_rdata<={26'd0,post_gap_right_shift};
          POST_QCFG:s_axi_rdata<={8'd0,post_fc_output_zero_point,post_gap_output_zero_point,post_gap_input_zero_point};
          POST_GAP_FNV1A:s_axi_rdata<=post_gap_fnv1a; POST_FC_FNV1A:s_axi_rdata<=post_fc_fnv1a;
          POST_CLASS:s_axi_rdata<={15'd0,post_fc_values_done,post_gap_values_done,post_predicted_class}; POST_CYCLES:s_axi_rdata<=post_cycles;
          POST_PROGRESS:s_axi_rdata<={17'd0,post_fc_values_done,post_gap_values_done,post_busy,post_fault,post_done};
          POST_DEBUG_GAP_SUM0:s_axi_rdata<=post_debug_gap_sum0; POST_DEBUG_GAP_SUM6:s_axi_rdata<=post_debug_gap_sum6;
          POST_DEBUG_FC0:s_axi_rdata<={{24{post_debug_fc_value[0][7]}},post_debug_fc_value[0]};
          POST_DEBUG_FC1:s_axi_rdata<={{24{post_debug_fc_value[1][7]}},post_debug_fc_value[1]};
          POST_DEBUG_FC2:s_axi_rdata<={{24{post_debug_fc_value[2][7]}},post_debug_fc_value[2]};
          POST_DEBUG_FC3:s_axi_rdata<={{24{post_debug_fc_value[3][7]}},post_debug_fc_value[3]};
          POST_DEBUG_FC4:s_axi_rdata<={{24{post_debug_fc_value[4][7]}},post_debug_fc_value[4]};
          POST_DEBUG_FC5:s_axi_rdata<={{24{post_debug_fc_value[5][7]}},post_debug_fc_value[5]};
          WEIGHT_KEY:s_axi_rdata<=weight_key; WEIGHT_RESIDENT_KEY:s_axi_rdata<=weight_resident_key;
          WEIGHT_WRITE_COUNT:s_axi_rdata<=weight_write_count; WEIGHT_HIT_COUNT:s_axi_rdata<=weight_hit_count;
          WEIGHT_BYTES:s_axi_rdata<=weight_bytes; WEIGHT_MISS_COUNT:s_axi_rdata<=weight_miss_count;
          WEIGHT_STATUS:s_axi_rdata<={27'd0,weight_key_hit,weight_keyed_mode,weight_resident_valid,weight_resident_valid && (weight_resident_key == weight_key),fault};
          WEIGHT_DMA_SOURCE:s_axi_rdata<=weight_dma_source; WEIGHT_DMA_BYTES:s_axi_rdata<=weight_dma_bytes;
          WEIGHT_DMA_CFG:s_axi_rdata<={19'd0,weight_dma_groups,3'd0,weight_dma_taps};
          WEIGHT_DMA_STATUS:s_axi_rdata<={29'd0,weight_dma_fault,weight_dma_done,weight_dma_busy};
          WEIGHT_DMA_BYTES_READ:s_axi_rdata<=weight_dma_bytes_read; WEIGHT_DMA_WRITE_COUNT:s_axi_rdata<=weight_dma_write_count;
          WEIGHT_BANK_SELECT:s_axi_rdata<={31'd0,weight_bank_select}; PARAM_BANK_SELECT:s_axi_rdata<={31'd0,param_bank_select};
          WEIGHT_READ_BANK_SELECT:s_axi_rdata<={31'd0,weight_read_bank_select};
          DESC_SELECT:s_axi_rdata<={30'd0,desc_select};
          DESC_MODE:s_axi_rdata<={29'd0,desc_mode_mem[desc_select]};
          DESC_JOB_SHAPE:s_axi_rdata<={desc_height_mem[desc_select],desc_width_mem[desc_select]};
          DESC_DMA_SOURCE:s_axi_rdata<=desc_dma_source_mem[desc_select]; DESC_DMA_BYTES:s_axi_rdata<=desc_dma_bytes_mem[desc_select];
          DESC_DMA_PIXELS:s_axi_rdata<={18'd0,desc_dma_pixels_mem[desc_select]};
          DESC_STORE_DESTINATION:s_axi_rdata<=desc_store_destination_mem[desc_select]; DESC_STORE_BYTES:s_axi_rdata<=desc_store_bytes_mem[desc_select];
          DESC_STORE_CONTROL:s_axi_rdata<={30'd0,desc_store_pool_mem[desc_select],desc_store_enable_mem[desc_select]};
          DESC_STORE_STRIDE:s_axi_rdata<=desc_store_stride_mem[desc_select]; DESC_STORE_VALID_BYTES:s_axi_rdata<={26'd0,desc_store_valid_mem[desc_select]};
          DESC_QCFG:s_axi_rdata<=desc_qcfg_mem[desc_select]; DESC_LANE_MASK:s_axi_rdata<={{(32-OUT_LANES){1'b0}},desc_lane_mask_mem[desc_select]};
          DESC_RELAY_CONTROL:s_axi_rdata<={28'd0,desc_relay_control_mem[desc_select]};
          DESC_WEIGHT_BANK:s_axi_rdata<={30'd0,desc_weight_bank_mem[desc_select]}; DESC_PARAM_BANK:s_axi_rdata<={30'd0,desc_param_bank_mem[desc_select]};
          DESC_TASK_CYCLES:s_axi_rdata<=desc_task_cycles_mem[desc_select];
          DESC_COUNT:s_axi_rdata<={29'd0,desc_count};
          DESC_STATUS:s_axi_rdata<={24'd0,desc_read_index,desc_state,descriptor_active,done,fault};
          DESC_ISSUED:s_axi_rdata<=desc_issued; DESC_COMPLETED:s_axi_rdata<=desc_completed;
          default:s_axi_rdata<=32'hdeadbeef;
        endcase
        s_axi_rvalid<=1; s_axi_rresp<=0;
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
    end
  end
endmodule
