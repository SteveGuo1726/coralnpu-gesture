// PROJECT_LOCAL_MOD: Accelerator-only AXI-Lite wrapper around the project-local
// RVV/CoralNPU execution side. This wrapper intentionally excludes the scalar
// core and lets the Zynq PS drive the accelerator through memory-mapped
// registers.
`timescale 1ns / 1ps
`include "rvv_lsu_axi_bridge_unit_stride_e32.sv"
`include "coralnpu_stage3b_tensor_engine.sv"

module coralnpu_rvv_accel_lane1_axil_wrapper (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.ACLK, ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET aresetn, FREQ_HZ 25000000" *)
    input  wire        aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.ARESETN, POLARITY ACTIVE_LOW" *)
    input  wire        aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 32, DATA_WIDTH 32, HAS_BRESP 1, HAS_RRESP 1, HAS_WSTRB 1, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 1, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, READ_WRITE_MODE READ_WRITE" *)
    input  wire [31:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  wire [2:0]  s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire        s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output reg         s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [3:0]  s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire        s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output reg         s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output reg [1:0]   s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output reg         s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire        s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [31:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  wire [2:0]  s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire        s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output reg         s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output reg [31:0]  s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output reg [1:0]   s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output reg         s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire        s_axi_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI, PROTOCOL AXI4, ADDR_WIDTH 32, DATA_WIDTH 32, ID_WIDTH 6, HAS_BRESP 1, HAS_RRESP 1, HAS_WSTRB 1, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 1, SUPPORTS_NARROW_BURST 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, READ_WRITE_MODE READ_WRITE" *)
    output wire [31:0] m_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *)
    output wire [2:0]  m_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)
    output wire        m_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
    input  wire        m_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *)
    output wire [5:0]  m_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *)
    output wire [7:0]  m_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *)
    output wire [2:0]  m_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *)
    output wire [1:0]  m_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *)
    output wire        m_axi_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *)
    output wire [3:0]  m_axi_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWQOS" *)
    output wire [3:0]  m_axi_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREGION" *)
    output wire [3:0]  m_axi_awregion,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
    output wire [31:0] m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
    output wire [3:0]  m_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)
    output wire        m_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
    output wire        m_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
    input  wire        m_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
    output wire        m_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
    input  wire        m_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID" *)
    input  wire [5:0]  m_axi_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
    input  wire [1:0]  m_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)
    output wire [31:0] m_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *)
    output wire [2:0]  m_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
    output wire        m_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
    input  wire        m_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *)
    output wire [5:0]  m_axi_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)
    output wire [7:0]  m_axi_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)
    output wire [2:0]  m_axi_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)
    output wire [1:0]  m_axi_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *)
    output wire        m_axi_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *)
    output wire [3:0]  m_axi_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARQOS" *)
    output wire [3:0]  m_axi_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREGION" *)
    output wire [3:0]  m_axi_arregion,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
    output wire        m_axi_rready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
    input  wire        m_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
    input  wire [31:0] m_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID" *)
    input  wire [5:0]  m_axi_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
    input  wire [1:0]  m_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)
    input  wire        m_axi_rlast
);

  localparam [11:0] REG_MAGIC          = 12'h000;
  localparam [11:0] REG_VERSION        = 12'h004;
  localparam [11:0] REG_CONTROL        = 12'h008;
  localparam [11:0] REG_STATUS         = 12'h00C;
  localparam [11:0] REG_CFG0           = 12'h010;
  localparam [11:0] REG_INST_PC        = 12'h014;
  localparam [11:0] REG_INST_ENC       = 12'h018;
  localparam [11:0] REG_RS0            = 12'h01C;
  localparam [11:0] REG_RS1            = 12'h020;
  localparam [11:0] REG_FRS0           = 12'h024;
  localparam [11:0] REG_RD0            = 12'h040;
  localparam [11:0] REG_ASYNC_RD       = 12'h044;
  localparam [11:0] REG_ASYNC_FRD      = 12'h048;
  localparam [11:0] REG_CONFIG0        = 12'h04C;
  localparam [11:0] REG_CONFIG1        = 12'h050;
  localparam [11:0] REG_MTYPE          = 12'h054;
  localparam [11:0] REG_TRAP_PC        = 12'h058;
  localparam [11:0] REG_TRAP_ENC       = 12'h05C;
  localparam [11:0] REG_ROB_VALID      = 12'h060;
  localparam [11:0] REG_ROB_DATA0      = 12'h064;
  localparam [11:0] REG_ROB_DATA1      = 12'h068;
  localparam [11:0] REG_ROB_DATA2      = 12'h06C;
  localparam [11:0] REG_ROB_DATA3      = 12'h070;
  localparam [11:0] REG_ROB_META0      = 12'h074;
  localparam [11:0] REG_ROB_META1      = 12'h078;
  localparam [11:0] REG_VXSAT          = 12'h07C;
  localparam [11:0] REG_DEBUG0         = 12'h080;
  // PROJECT_LOCAL_MOD: persistent per-command LSU path counters.  Software
  // clears them through CONTROL[1] before issuing one instruction, then reads
  // them after completion or timeout.  They are intentionally part of the
  // board IP contract, not a one-shot simulation probe.
  localparam [11:0] REG_LSU_EVT0        = 12'h084;
  localparam [11:0] REG_LSU_EVT1        = 12'h088;
  localparam [11:0] REG_LSU_EVT2        = 12'h08C;
  localparam [11:0] REG_LSU_EVT3        = 12'h090;
  localparam [11:0] REG_LSU_EVT4        = 12'h094;
  // PROJECT_LOCAL_MOD: sticky internal LSU/ROB progression map. This is a
  // board-facing diagnostic register, retained to distinguish an AXI return
  // from an instruction actually completing inside the RVV backend.
  localparam [11:0] REG_LSU_EVT5        = 12'h098;
  // PROJECT_LOCAL_MOD: {reserved[31:20], top context count[19:18], bridge
  // word count[17:16], accepted mask[15:0]}. Keeping both counts in the
  // existing diagnostic CSR distinguishes an issue-context problem from a
  // bridge-capture problem without changing the data path.
  localparam [11:0] REG_LSU_EVT6        = 12'h09C;
  // PROJECT_LOCAL_MOD: isolated tensor-engine register window. It does not
  // alter the proven RVV instruction or LSU interfaces.
  localparam [11:0] REG_TENSOR_CTRL      = 12'h0A0;
  localparam [11:0] REG_TENSOR_STATUS    = 12'h0A4;
  localparam [11:0] REG_TENSOR_MEM_ADDR  = 12'h0A8;
  localparam [11:0] REG_TENSOR_MEM_DATA  = 12'h0AC;
  localparam [11:0] REG_TENSOR_MEM_KIND  = 12'h0B0;
  localparam [11:0] REG_TENSOR_MEM_READ  = 12'h0B4;

  localparam [31:0] MAGIC_VALUE        = 32'h4352_5656;  // "CRVV"
  localparam [31:0] VERSION_VALUE      = 32'h0001_0000;

  localparam [1:0] WR_IDLE = 2'd0;
  localparam [1:0] WR_RESP = 2'd1;
  localparam [1:0] RD_IDLE = 2'd0;
  localparam [1:0] RD_RESP = 2'd1;

  reg [1:0] write_state;
  reg [1:0] read_state;
  reg [31:0] wr_addr_reg;
  reg [31:0] wr_data_reg;
  reg [3:0]  wr_strb_reg;
  reg        wr_addr_seen;
  reg        wr_data_seen;
  reg [31:0] rd_addr_reg;

  reg [6:0]  cfg_vstart_reg;
  reg [1:0]  cfg_vxrm_reg;
  reg        cfg_vxsat_reg;
  reg [2:0]  cfg_frm_reg;
  reg [31:0] inst_pc_reg;
  reg [1:0]  inst_opcode_reg;
  reg [24:0] inst_bits_reg;
  reg [31:0] rs0_reg;
  reg [31:0] rs1_reg;
  reg [31:0] frs0_reg;
  reg        issue_pending;
  reg        lsu_ctx_valid;
  reg        lsu_ctx_is_store;
  reg        lsu_ctx_supported;
  reg [1:0]  lsu_ctx_elem_count;
  reg [31:0] lsu_ctx_base_addr;
  reg [15:0] tensor_mem_addr_reg;
  reg [31:0] tensor_mem_data_reg;
  reg [2:0]  tensor_mem_kind_reg;
  reg        tensor_start_reg;
  reg        tensor_mem_we_reg;
  reg        tensor_mem_re_reg;
  reg        tensor_done_sticky;

  reg        sticky_rd0_valid;
  reg [4:0]  sticky_rd0_addr;
  reg [31:0] sticky_rd0_data;
  reg        sticky_async_rd_valid;
  reg [4:0]  sticky_async_rd_addr;
  reg [31:0] sticky_async_rd_data;
  reg        sticky_async_frd_valid;
  reg [4:0]  sticky_async_frd_addr;
  reg [31:0] sticky_async_frd_data;
  reg        sticky_config_valid;
  reg [7:0]  sticky_config_vl;
  reg [6:0]  sticky_config_vstart;
  reg        sticky_config_ma;
  reg        sticky_config_ta;
  reg [1:0]  sticky_config_xrm;
  reg [2:0]  sticky_config_sew;
  reg [2:0]  sticky_config_lmul;
  reg [2:0]  sticky_config_lmul_orig;
  reg        sticky_config_vill;
  reg [31:0] sticky_config_mtype;
  reg        sticky_trap_valid;
  reg [31:0] sticky_trap_pc;
  reg [1:0]  sticky_trap_opcode;
  reg [24:0] sticky_trap_bits;
  reg        sticky_rob_valid;
  reg        sticky_rob_w_valid;
  reg [4:0]  sticky_rob_w_index;
  reg [127:0] sticky_rob_w_data;
  reg        sticky_rob_w_type;
  reg [15:0] sticky_rob_vd_type;
  reg        sticky_rob_trap_flag;
  reg        sticky_rob_vcsr_vl;
  reg        sticky_rob_vcsr_vstart;
  reg        sticky_rob_vcsr_ma;
  reg        sticky_rob_vcsr_ta;
  reg        sticky_rob_vcsr_xrm;
  reg        sticky_rob_vcsr_sew;
  reg        sticky_rob_vcsr_lmul;
  reg        sticky_rob_vcsr_lmul_orig;
  reg        sticky_rob_vcsr_vill;
  reg [15:0] sticky_rob_vxsaturate;
  reg [31:0] sticky_rob_uop_pc;
  reg        sticky_rob_last_uop_valid;
  reg        sticky_wr_vxsat_valid;
  reg        sticky_wr_vxsat;

  // PROJECT_LOCAL_MOD: each counter is 16 bits because CONTROL[1] establishes
  // a fresh observation window for every issued PS command.
  reg [15:0] lsu_evt_issue_count;
  reg [15:0] lsu_evt_rvv_req_count;
  reg [15:0] lsu_evt_ar_count;
  reg [15:0] lsu_evt_r_count;
  reg [15:0] lsu_evt_aw_count;
  reg [15:0] lsu_evt_w_count;
  reg [15:0] lsu_evt_b_count;
  reg [15:0] lsu_evt_rsp_count;
  reg [15:0] lsu_evt_rob_count;
  reg [15:0] lsu_evt_internal_sticky;

  wire       inst_0_ready;
  reg        inst_0_valid_reg;
  wire       issue_fire = issue_pending && inst_0_ready;
  wire       lsu_bridge_busy;
  wire [1:0] lsu_debug_req_word_count;
  wire [15:0] lsu_debug_req_mask;
  wire       lsu_fault_sticky;
  wire       tensor_busy;
  wire       tensor_done;
  wire       tensor_fault;
  wire [31:0] tensor_mem_rdata;
  wire       rvv2lsu_0_valid;
  wire       rvv2lsu_0_bits_idx_valid;
  wire [4:0] rvv2lsu_0_bits_idx_bits_addr;
  wire [127:0] rvv2lsu_0_bits_idx_bits_data;
  wire       rvv2lsu_0_bits_vregfile_valid;
  wire [4:0] rvv2lsu_0_bits_vregfile_bits_addr;
  wire [127:0] rvv2lsu_0_bits_vregfile_bits_data;
  wire       rvv2lsu_0_bits_mask_valid;
  wire [15:0] rvv2lsu_0_bits_mask_bits;
  wire       rvv2lsu_0_ready;
  wire       lsu2rvv_0_valid;
  wire [4:0] lsu2rvv_0_bits_addr;
  wire [127:0] lsu2rvv_0_bits_data;
  wire       lsu2rvv_0_bits_last;
  wire       lsu2rvv_0_ready;

  wire       rd_0_valid;
  wire [4:0] rd_0_bits_addr;
  wire [31:0] rd_0_bits_data;
  wire       async_rd_valid;
  wire [4:0] async_rd_bits_addr;
  wire [31:0] async_rd_bits_data;
  wire       async_frd_valid;
  wire [4:0] async_frd_bits_addr;
  wire [31:0] async_frd_bits_data;
  wire       vcsr_valid;
  wire [6:0] vcsr_vstart;
  wire [1:0] vcsr_xrm;
  wire       vcsr_vxsat;
  wire       configStateValid;
  wire [7:0] configVl;
  wire [6:0] configVstart;
  wire       configMa;
  wire       configTa;
  wire [1:0] configXrm;
  wire [2:0] configSew;
  wire [2:0] configLmul;
  wire [2:0] configLmulOrig;
  wire       configVill;
  wire [31:0] configMtype;
  wire       rvv_idle;
  wire [3:0] queue_capacity;
  wire       trap_valid;
  wire [31:0] trap_bits_pc;
  wire [1:0] trap_bits_opcode;
  wire [24:0] trap_bits_bits;
  wire       rd_rob2rt_o_0_valid;
  wire       rd_rob2rt_o_0_w_valid;
  wire [4:0] rd_rob2rt_o_0_w_index;
  wire [127:0] rd_rob2rt_o_0_w_data;
  wire       rd_rob2rt_o_0_w_type;
  wire [15:0] rd_rob2rt_o_0_vd_type;
  wire       rd_rob2rt_o_0_trap_flag;
  wire       rd_rob2rt_o_0_vector_csr_vl;
  wire       rd_rob2rt_o_0_vector_csr_vstart;
  wire       rd_rob2rt_o_0_vector_csr_ma;
  wire       rd_rob2rt_o_0_vector_csr_ta;
  wire       rd_rob2rt_o_0_vector_csr_xrm;
  wire       rd_rob2rt_o_0_vector_csr_sew;
  wire       rd_rob2rt_o_0_vector_csr_lmul;
  wire       rd_rob2rt_o_0_vector_csr_lmul_orig;
  wire       rd_rob2rt_o_0_vector_csr_vill;
  wire [15:0] rd_rob2rt_o_0_vxsaturate;
  wire [31:0] rd_rob2rt_o_0_uop_pc;
  wire       rd_rob2rt_o_0_last_uop_valid;
  wire       wr_vxsat_valid_o;
  wire       wr_vxsat_o;

  // PROJECT_LOCAL_MOD: rd_rob2rt_o is an RVVI/testbench-only mirror and is
  // intentionally undriven in this FPGA build because TB_SUPPORT is absent.
  // Board software must instead observe the functional ROB-to-retire path.
  wire       backend_rd_rob2rt_valid =
      u_rvv_accel.core.backend.rd_valid_rob2rt[0];
  wire       backend_rd_rob2rt_w_valid =
      u_rvv_accel.core.backend.rd_rob2rt[0].w_valid;
  wire [4:0] backend_rd_rob2rt_w_index =
      u_rvv_accel.core.backend.rd_rob2rt[0].w_index;
  wire [127:0] backend_rd_rob2rt_w_data =
      u_rvv_accel.core.backend.rd_rob2rt[0].w_data;
  wire       backend_rd_rob2rt_w_type =
      u_rvv_accel.core.backend.rd_rob2rt[0].w_type;
  wire [15:0] backend_rd_rob2rt_vd_type =
      u_rvv_accel.core.backend.rd_rob2rt[0].vd_type;
  wire       backend_rd_rob2rt_trap_flag =
      u_rvv_accel.core.backend.rd_rob2rt[0].trap_flag;
  wire       backend_rd_rob2rt_vcsr_vl =
      u_rvv_accel.core.backend.rd_rob2rt[0].vector_csr.vl;
  wire       backend_rd_rob2rt_vcsr_vstart =
      u_rvv_accel.core.backend.rd_rob2rt[0].vector_csr.vstart;
  wire       backend_rd_rob2rt_vcsr_ma =
      u_rvv_accel.core.backend.rd_rob2rt[0].vector_csr.ma;
  wire       backend_rd_rob2rt_vcsr_ta =
      u_rvv_accel.core.backend.rd_rob2rt[0].vector_csr.ta;
  wire [1:0] backend_rd_rob2rt_vcsr_xrm =
      u_rvv_accel.core.backend.rd_rob2rt[0].vector_csr.xrm;
  wire [2:0] backend_rd_rob2rt_vcsr_sew =
      u_rvv_accel.core.backend.rd_rob2rt[0].vector_csr.sew;
  wire [2:0] backend_rd_rob2rt_vcsr_lmul =
      u_rvv_accel.core.backend.rd_rob2rt[0].vector_csr.lmul;
  wire [2:0] backend_rd_rob2rt_vcsr_lmul_orig =
      u_rvv_accel.core.backend.rd_rob2rt[0].vector_csr.lmul_orig;
  wire       backend_rd_rob2rt_vcsr_vill =
      u_rvv_accel.core.backend.rd_rob2rt[0].vector_csr.vill;
  wire [15:0] backend_rd_rob2rt_vxsaturate =
      u_rvv_accel.core.backend.rd_rob2rt[0].vxsaturate;

  // PROJECT_LOCAL_MOD: event definitions are handshake based, so a count
  // means a transfer actually crossed that interface rather than merely being
  // requested combinationally.
  wire lsu_evt_rvv_req_fire = rvv2lsu_0_valid && rvv2lsu_0_ready;
  wire lsu_evt_ar_fire = m_axi_arvalid && m_axi_arready;
  wire lsu_evt_r_fire = m_axi_rvalid && m_axi_rready;
  wire lsu_evt_aw_fire = m_axi_awvalid && m_axi_awready;
  wire lsu_evt_w_fire = m_axi_wvalid && m_axi_wready;
  wire lsu_evt_b_fire = m_axi_bvalid && m_axi_bready;
  wire lsu_evt_rsp_fire = lsu2rvv_0_valid && lsu2rvv_0_ready;

  // PROJECT_LOCAL_MOD: observe the project-local RVV backend at named
  // boundaries. These are sticky rather than cycle counters because the PS
  // reads them after a command has timed out or retired. Bit assignment:
  // [0] LSU RS push, [1] ROB uop push, [2] LSU map-info push,
  // [3] map-info visible, [4] LSU-result FIFO push, [5] LSU-result visible,
  // [6] remap result valid, [7] remap result accepted by arbiter,
  // [8] map-info pop, [9] LSU-result pop, [10] arbiter result to ROB,
  // [11] ROB result to retire.
  wire [15:0] lsu_evt_internal_now = {
      4'd0,
      backend_rd_rob2rt_valid,
      u_rvv_accel.core.backend.res_valid_arb2rob[0],
      u_rvv_accel.core.backend.pop_lsu_res[0],
      u_rvv_accel.core.backend.pop_mapinfo[0],
      u_rvv_accel.core.backend.res_valid_lsu[0] &&
          u_rvv_accel.core.backend.res_ready_lsu[0],
      u_rvv_accel.core.backend.res_valid_lsu[0],
      u_rvv_accel.core.backend.lsu_res_valid[0],
      u_rvv_accel.core.backend.uop_lsu_valid[0] &&
          u_rvv_accel.core.backend.uop_lsu_ready_rvv2lsu[0],
      u_rvv_accel.core.backend.mapinfo_valid[0],
      u_rvv_accel.core.backend.mapinfo_valid_dp2lsu[0],
      u_rvv_accel.core.backend.uop_valid_dp2rob[0],
      u_rvv_accel.core.backend.rs_valid_dp2lsu[0]
  };

  wire [31:0] status_word = {
      13'd0,
      lsu_ctx_valid,
      lsu_ctx_supported,
      lsu_ctx_is_store,
      lsu_fault_sticky,
      lsu_bridge_busy,
      issue_pending,
      sticky_wr_vxsat_valid,
      sticky_rob_valid,
      sticky_trap_valid,
      sticky_config_valid,
      sticky_async_frd_valid,
      sticky_async_rd_valid,
      sticky_rd0_valid,
      wr_vxsat_valid_o,
      trap_valid,
      configStateValid,
      vcsr_valid,
      rvv_idle,
      inst_0_ready
  };

  coralnpu_stage3b_tensor_engine u_stage3b_tensor_engine (
      .clk(aclk), .rstn(aresetn), .start(tensor_start_reg),
      .busy(tensor_busy), .done(tensor_done), .fault(tensor_fault),
      .mem_we(tensor_mem_we_reg), .mem_re(tensor_mem_re_reg),
      .mem_kind(tensor_mem_kind_reg),
      .mem_addr(tensor_mem_addr_reg), .mem_wdata(tensor_mem_data_reg),
      .mem_rdata(tensor_mem_rdata)
  );

  function automatic [31:0] decode_read_data(input [11:0] addr);
    begin
      case (addr)
      REG_MAGIC:    decode_read_data = MAGIC_VALUE;
      REG_VERSION:  decode_read_data = VERSION_VALUE;
      REG_CONTROL:  decode_read_data = {31'd0, issue_pending};
      REG_STATUS:   decode_read_data = status_word;
      REG_CFG0:     decode_read_data = {19'd0, cfg_frm_reg, cfg_vxsat_reg, cfg_vxrm_reg, cfg_vstart_reg};
      REG_INST_PC:  decode_read_data = inst_pc_reg;
      REG_INST_ENC: decode_read_data = {5'd0, inst_bits_reg, inst_opcode_reg};
      REG_RS0:      decode_read_data = rs0_reg;
      REG_RS1:      decode_read_data = rs1_reg;
      REG_FRS0:     decode_read_data = frs0_reg;
      REG_RD0:      decode_read_data = {sticky_rd0_valid, 2'd0, sticky_rd0_addr, sticky_rd0_data[23:0]};
      REG_ASYNC_RD: decode_read_data = {sticky_async_rd_valid, 2'd0, sticky_async_rd_addr, sticky_async_rd_data[23:0]};
      REG_ASYNC_FRD: decode_read_data = {sticky_async_frd_valid, 2'd0, sticky_async_frd_addr, sticky_async_frd_data[23:0]};
      REG_CONFIG0:  decode_read_data = {3'd0, sticky_config_vill, sticky_config_lmul_orig, sticky_config_lmul, sticky_config_sew, sticky_config_xrm, sticky_config_ta, sticky_config_ma, sticky_config_vstart, sticky_config_vl};
      REG_CONFIG1:  decode_read_data = {18'd0, vcsr_vxsat, 4'd0, vcsr_xrm, vcsr_vstart};
      REG_MTYPE:    decode_read_data = sticky_config_mtype;
      REG_TRAP_PC:  decode_read_data = sticky_trap_pc;
      REG_TRAP_ENC: decode_read_data = {5'd0, sticky_trap_bits, sticky_trap_opcode};
      REG_ROB_VALID: decode_read_data = {
          12'd0,
          sticky_rob_last_uop_valid,
          sticky_rob_trap_flag,
          sticky_rob_w_type,
          sticky_rob_w_valid,
          sticky_rob_valid,
          sticky_rob_vcsr_vill,
          sticky_rob_vcsr_lmul_orig,
          sticky_rob_vcsr_lmul,
          sticky_rob_vcsr_sew,
          sticky_rob_vcsr_xrm,
          sticky_rob_vcsr_ta,
          sticky_rob_vcsr_ma,
          sticky_rob_vcsr_vstart,
          sticky_rob_vcsr_vl,
          sticky_rob_w_index
      };
      REG_ROB_DATA0: decode_read_data = sticky_rob_w_data[31:0];
      REG_ROB_DATA1: decode_read_data = sticky_rob_w_data[63:32];
      REG_ROB_DATA2: decode_read_data = sticky_rob_w_data[95:64];
      REG_ROB_DATA3: decode_read_data = sticky_rob_w_data[127:96];
      REG_ROB_META0: decode_read_data = {sticky_rob_vd_type, sticky_rob_vxsaturate};
      REG_ROB_META1: decode_read_data = sticky_rob_uop_pc;
      REG_VXSAT:     decode_read_data = {30'd0, sticky_wr_vxsat, sticky_wr_vxsat_valid};
      REG_DEBUG0:    decode_read_data = {
          19'd0,
          lsu_ctx_valid,
          lsu_ctx_supported,
          lsu_ctx_is_store,
          lsu_fault_sticky,
          lsu_bridge_busy,
          issue_pending,
          inst_0_valid_reg,
          inst_0_ready,
          rvv_idle,
          queue_capacity
      };
      REG_LSU_EVT0: decode_read_data = {lsu_evt_issue_count, lsu_evt_rvv_req_count};
      REG_LSU_EVT1: decode_read_data = {lsu_evt_ar_count, lsu_evt_r_count};
      REG_LSU_EVT2: decode_read_data = {lsu_evt_aw_count, lsu_evt_w_count};
      REG_LSU_EVT3: decode_read_data = {lsu_evt_b_count, lsu_evt_rsp_count};
      REG_LSU_EVT4: decode_read_data = {16'd0, lsu_evt_rob_count};
      REG_LSU_EVT5: decode_read_data = {16'd0, lsu_evt_internal_sticky};
      REG_LSU_EVT6: decode_read_data = {
          12'd0, lsu_ctx_elem_count, lsu_debug_req_word_count,
          lsu_debug_req_mask
      };
      REG_TENSOR_CTRL: decode_read_data = {31'd0, tensor_start_reg};
      REG_TENSOR_STATUS: decode_read_data = {29'd0, tensor_done_sticky, tensor_fault, tensor_busy};
      REG_TENSOR_MEM_ADDR: decode_read_data = {16'd0, tensor_mem_addr_reg};
      REG_TENSOR_MEM_DATA: decode_read_data = tensor_mem_data_reg;
      REG_TENSOR_MEM_KIND: decode_read_data = {29'd0, tensor_mem_kind_reg};
      REG_TENSOR_MEM_READ: decode_read_data = tensor_mem_rdata;
      default:       decode_read_data = 32'hDEAD_BEEF;
      endcase
    end
  endfunction

  always @(*) begin
    s_axi_awready = (write_state == WR_IDLE) && !wr_addr_seen;
    s_axi_wready  = (write_state == WR_IDLE) && !wr_data_seen;
    s_axi_arready = (read_state == RD_IDLE);
  end

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      write_state <= WR_IDLE;
      read_state <= RD_IDLE;
      wr_addr_reg <= 32'd0;
      wr_data_reg <= 32'd0;
      wr_strb_reg <= 4'd0;
      wr_addr_seen <= 1'b0;
      wr_data_seen <= 1'b0;
      rd_addr_reg <= 32'd0;
      s_axi_bvalid <= 1'b0;
      s_axi_bresp <= 2'b00;
      s_axi_rvalid <= 1'b0;
      s_axi_rresp <= 2'b00;
      s_axi_rdata <= 32'd0;
      cfg_vstart_reg <= 7'd0;
      cfg_vxrm_reg <= 2'd0;
      cfg_vxsat_reg <= 1'b0;
      cfg_frm_reg <= 3'd0;
      inst_pc_reg <= 32'd0;
      inst_opcode_reg <= 2'd0;
      inst_bits_reg <= 25'd0;
      rs0_reg <= 32'd0;
      rs1_reg <= 32'd0;
      frs0_reg <= 32'd0;
      issue_pending <= 1'b0;
      lsu_ctx_valid <= 1'b0;
      lsu_ctx_is_store <= 1'b0;
      lsu_ctx_supported <= 1'b0;
      lsu_ctx_elem_count <= 2'd0;
      lsu_ctx_base_addr <= 32'd0;
      tensor_mem_addr_reg <= 16'd0;
      tensor_mem_data_reg <= 32'd0;
      tensor_mem_kind_reg <= 3'd0;
      tensor_start_reg <= 1'b0;
      tensor_mem_we_reg <= 1'b0;
      tensor_mem_re_reg <= 1'b0;
      tensor_done_sticky <= 1'b0;
      inst_0_valid_reg <= 1'b0;
      sticky_rd0_valid <= 1'b0;
      sticky_rd0_addr <= 5'd0;
      sticky_rd0_data <= 32'd0;
      sticky_async_rd_valid <= 1'b0;
      sticky_async_rd_addr <= 5'd0;
      sticky_async_rd_data <= 32'd0;
      sticky_async_frd_valid <= 1'b0;
      sticky_async_frd_addr <= 5'd0;
      sticky_async_frd_data <= 32'd0;
      sticky_config_valid <= 1'b0;
      sticky_config_vl <= 8'd0;
      sticky_config_vstart <= 7'd0;
      sticky_config_ma <= 1'b0;
      sticky_config_ta <= 1'b0;
      sticky_config_xrm <= 2'd0;
      sticky_config_sew <= 3'd0;
      sticky_config_lmul <= 3'd0;
      sticky_config_lmul_orig <= 3'd0;
      sticky_config_vill <= 1'b0;
      sticky_config_mtype <= 32'd0;
      sticky_trap_valid <= 1'b0;
      sticky_trap_pc <= 32'd0;
      sticky_trap_opcode <= 2'd0;
      sticky_trap_bits <= 25'd0;
      sticky_rob_valid <= 1'b0;
      sticky_rob_w_valid <= 1'b0;
      sticky_rob_w_index <= 5'd0;
      sticky_rob_w_data <= 128'd0;
      sticky_rob_w_type <= 1'b0;
      sticky_rob_vd_type <= 16'd0;
      sticky_rob_trap_flag <= 1'b0;
      sticky_rob_vcsr_vl <= 1'b0;
      sticky_rob_vcsr_vstart <= 1'b0;
      sticky_rob_vcsr_ma <= 1'b0;
      sticky_rob_vcsr_ta <= 1'b0;
      sticky_rob_vcsr_xrm <= 1'b0;
      sticky_rob_vcsr_sew <= 1'b0;
      sticky_rob_vcsr_lmul <= 1'b0;
      sticky_rob_vcsr_lmul_orig <= 1'b0;
      sticky_rob_vcsr_vill <= 1'b0;
      sticky_rob_vxsaturate <= 16'd0;
      sticky_rob_uop_pc <= 32'd0;
      sticky_rob_last_uop_valid <= 1'b0;
      sticky_wr_vxsat_valid <= 1'b0;
      sticky_wr_vxsat <= 1'b0;
      lsu_evt_issue_count <= 16'd0;
      lsu_evt_rvv_req_count <= 16'd0;
      lsu_evt_ar_count <= 16'd0;
      lsu_evt_r_count <= 16'd0;
      lsu_evt_aw_count <= 16'd0;
      lsu_evt_w_count <= 16'd0;
      lsu_evt_b_count <= 16'd0;
      lsu_evt_rsp_count <= 16'd0;
      lsu_evt_rob_count <= 16'd0;
      lsu_evt_internal_sticky <= 16'd0;
    end else begin
      // PROJECT_LOCAL_MOD: keep valid asserted throughout the whole pending
      // window so the RVV front-end can eventually raise inst_ready and
      // consume the instruction.
      inst_0_valid_reg <= issue_pending;
      tensor_start_reg <= 1'b0;
      tensor_mem_we_reg <= 1'b0;
      tensor_mem_re_reg <= 1'b0;
      if (tensor_done) begin
        tensor_done_sticky <= 1'b1;
      end

      if ((write_state == WR_IDLE) && s_axi_awvalid && s_axi_awready) begin
        wr_addr_reg <= s_axi_awaddr;
        wr_addr_seen <= 1'b1;
      end
      if ((write_state == WR_IDLE) && s_axi_wvalid && s_axi_wready) begin
        wr_data_reg <= s_axi_wdata;
        wr_strb_reg <= s_axi_wstrb;
        wr_data_seen <= 1'b1;
      end

      case (write_state)
        WR_IDLE: begin
          if (wr_addr_seen && wr_data_seen) begin
            case (wr_addr_reg[11:0])
              REG_CONTROL: begin
                if (wr_data_reg[0]) begin
                  issue_pending <= 1'b1;
                end
                if (wr_data_reg[1]) begin
                  sticky_rd0_valid <= 1'b0;
                  sticky_async_rd_valid <= 1'b0;
                  sticky_async_frd_valid <= 1'b0;
                  sticky_config_valid <= 1'b0;
                  sticky_trap_valid <= 1'b0;
                  sticky_rob_valid <= 1'b0;
                  sticky_wr_vxsat_valid <= 1'b0;
                  lsu_evt_issue_count <= 16'd0;
                  lsu_evt_rvv_req_count <= 16'd0;
                  lsu_evt_ar_count <= 16'd0;
                  lsu_evt_r_count <= 16'd0;
                  lsu_evt_aw_count <= 16'd0;
                  lsu_evt_w_count <= 16'd0;
                  lsu_evt_b_count <= 16'd0;
                  lsu_evt_rsp_count <= 16'd0;
                  lsu_evt_rob_count <= 16'd0;
                  lsu_evt_internal_sticky <= 16'd0;
                end
              end
              REG_CFG0: begin
                cfg_vstart_reg <= wr_data_reg[6:0];
                cfg_vxrm_reg <= wr_data_reg[8:7];
                cfg_vxsat_reg <= wr_data_reg[9];
                cfg_frm_reg <= wr_data_reg[12:10];
              end
              REG_INST_PC: begin
                inst_pc_reg <= wr_data_reg;
              end
              REG_INST_ENC: begin
                inst_opcode_reg <= wr_data_reg[1:0];
                inst_bits_reg <= wr_data_reg[26:2];
              end
              REG_RS0: begin
                rs0_reg <= wr_data_reg;
              end
              REG_RS1: begin
                rs1_reg <= wr_data_reg;
              end
              REG_FRS0: begin
                frs0_reg <= wr_data_reg;
              end
              REG_TENSOR_CTRL: begin
                if (wr_data_reg[0] && !tensor_busy) begin
                  tensor_start_reg <= 1'b1;
                  tensor_done_sticky <= 1'b0;
                end
              end
              REG_TENSOR_MEM_ADDR: begin
                tensor_mem_addr_reg <= wr_data_reg[15:0];
              end
              REG_TENSOR_MEM_DATA: begin
                tensor_mem_data_reg <= wr_data_reg;
              end
              REG_TENSOR_MEM_KIND: begin
                tensor_mem_kind_reg <= wr_data_reg[2:0];
                // PROJECT_LOCAL_MOD: explicit read command. The engine uses
                // this pulse to keep tensor BRAM reads independent of a
                // continuously held memory-kind register value.
                if ((wr_data_reg[2:0] == 3'd5) || (wr_data_reg[2:0] == 3'd6)) begin
                  tensor_mem_re_reg <= 1'b1;
                end
              end
              REG_TENSOR_MEM_READ: begin
                if (!tensor_busy) begin
                  tensor_mem_we_reg <= 1'b1;
                end
              end
              default: begin
              end
            endcase

            s_axi_bvalid <= 1'b1;
            s_axi_bresp <= 2'b00;
            write_state <= WR_RESP;
          end
        end

        WR_RESP: begin
          if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            wr_addr_seen <= 1'b0;
            wr_data_seen <= 1'b0;
            write_state <= WR_IDLE;
          end
        end

        default: begin
          write_state <= WR_IDLE;
        end
      endcase

      case (read_state)
        RD_IDLE: begin
          if (s_axi_arvalid && s_axi_arready) begin
            rd_addr_reg <= s_axi_araddr;
            s_axi_rdata <= decode_read_data(s_axi_araddr[11:0]);
            s_axi_rresp <= 2'b00;
            s_axi_rvalid <= 1'b1;
            read_state <= RD_RESP;
          end
        end

        RD_RESP: begin
          if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            read_state <= RD_IDLE;
          end
        end

        default: begin
          read_state <= RD_IDLE;
        end
      endcase

      if (issue_fire) begin
        lsu_evt_issue_count <= lsu_evt_issue_count + 16'd1;
        issue_pending <= 1'b0;
        inst_0_valid_reg <= 1'b0;
        if (inst_opcode_reg != 2'd2) begin
          lsu_ctx_valid <= 1'b1;
          lsu_ctx_is_store <= (inst_opcode_reg == 2'd1);
          // PROJECT_LOCAL_MOD: issue and LSU request are decoupled. Latch
          // the vector length with the address/type context so a later core
          // configuration update cannot shrink a queued VL=2 transfer.
          lsu_ctx_elem_count <= sticky_config_vl[1:0];
          lsu_ctx_base_addr <= rs0_reg;
          lsu_ctx_supported <=
              (inst_bits_reg[24:22] == 3'b000) &&
              (inst_bits_reg[17:13] == 5'b00000) &&
              (inst_bits_reg[7:5] == 3'b110) &&
              (sticky_config_sew == 3'd2) &&
              (sticky_config_vl >= 8'd1) &&
              (sticky_config_vl <= 8'd2) &&
              !sticky_config_vill;
        end else begin
          lsu_ctx_valid <= 1'b0;
          lsu_ctx_is_store <= 1'b0;
          lsu_ctx_supported <= 1'b0;
          lsu_ctx_elem_count <= 2'd0;
          lsu_ctx_base_addr <= 32'd0;
        end
      end

      if (rd_0_valid) begin
        sticky_rd0_valid <= 1'b1;
        sticky_rd0_addr <= rd_0_bits_addr;
        sticky_rd0_data <= rd_0_bits_data;
      end

      if (async_rd_valid) begin
        sticky_async_rd_valid <= 1'b1;
        sticky_async_rd_addr <= async_rd_bits_addr;
        sticky_async_rd_data <= async_rd_bits_data;
      end

      if (async_frd_valid) begin
        sticky_async_frd_valid <= 1'b1;
        sticky_async_frd_addr <= async_frd_bits_addr;
        sticky_async_frd_data <= async_frd_bits_data;
      end

      if (configStateValid) begin
        sticky_config_valid <= 1'b1;
        sticky_config_vl <= configVl;
        sticky_config_vstart <= configVstart;
        sticky_config_ma <= configMa;
        sticky_config_ta <= configTa;
        sticky_config_xrm <= configXrm;
        sticky_config_sew <= configSew;
        sticky_config_lmul <= configLmul;
        sticky_config_lmul_orig <= configLmulOrig;
        sticky_config_vill <= configVill;
        sticky_config_mtype <= configMtype;
      end

      if (trap_valid) begin
        sticky_trap_valid <= 1'b1;
        sticky_trap_pc <= trap_bits_pc;
        sticky_trap_opcode <= trap_bits_opcode;
        sticky_trap_bits <= trap_bits_bits;
      end

      if (backend_rd_rob2rt_valid) begin
        lsu_evt_rob_count <= lsu_evt_rob_count + 16'd1;
        sticky_rob_valid <= 1'b1;
        sticky_rob_w_valid <= backend_rd_rob2rt_w_valid;
        sticky_rob_w_index <= backend_rd_rob2rt_w_index;
        sticky_rob_w_data <= backend_rd_rob2rt_w_data;
        sticky_rob_w_type <= backend_rd_rob2rt_w_type;
        sticky_rob_vd_type <= backend_rd_rob2rt_vd_type;
        sticky_rob_trap_flag <= backend_rd_rob2rt_trap_flag;
        sticky_rob_vcsr_vl <= backend_rd_rob2rt_vcsr_vl;
        sticky_rob_vcsr_vstart <= backend_rd_rob2rt_vcsr_vstart;
        sticky_rob_vcsr_ma <= backend_rd_rob2rt_vcsr_ma;
        sticky_rob_vcsr_ta <= backend_rd_rob2rt_vcsr_ta;
        sticky_rob_vcsr_xrm <= backend_rd_rob2rt_vcsr_xrm;
        sticky_rob_vcsr_sew <= backend_rd_rob2rt_vcsr_sew;
        sticky_rob_vcsr_lmul <= backend_rd_rob2rt_vcsr_lmul;
        sticky_rob_vcsr_lmul_orig <= backend_rd_rob2rt_vcsr_lmul_orig;
        sticky_rob_vcsr_vill <= backend_rd_rob2rt_vcsr_vill;
        sticky_rob_vxsaturate <= backend_rd_rob2rt_vxsaturate;
        // These two RVVI fields do not exist in the FPGA build; preserve the
        // CSR ABI with defined zero values rather than sampling test-only nets.
        sticky_rob_uop_pc <= 32'd0;
        sticky_rob_last_uop_valid <= 1'b0;
      end

      if (wr_vxsat_valid_o) begin
        sticky_wr_vxsat_valid <= 1'b1;
        sticky_wr_vxsat <= wr_vxsat_o;
      end

      if (lsu_evt_rvv_req_fire) begin
        lsu_evt_rvv_req_count <= lsu_evt_rvv_req_count + 16'd1;
      end
      if (lsu_evt_ar_fire) begin
        lsu_evt_ar_count <= lsu_evt_ar_count + 16'd1;
      end
      if (lsu_evt_r_fire) begin
        lsu_evt_r_count <= lsu_evt_r_count + 16'd1;
      end
      if (lsu_evt_aw_fire) begin
        lsu_evt_aw_count <= lsu_evt_aw_count + 16'd1;
      end
      if (lsu_evt_w_fire) begin
        lsu_evt_w_count <= lsu_evt_w_count + 16'd1;
      end
      if (lsu_evt_b_fire) begin
        lsu_evt_b_count <= lsu_evt_b_count + 16'd1;
      end
      if (lsu_evt_rsp_fire) begin
        lsu_evt_rsp_count <= lsu_evt_rsp_count + 16'd1;
      end
      lsu_evt_internal_sticky <= lsu_evt_internal_sticky | lsu_evt_internal_now;
    end
  end

  rvv_lsu_axi_bridge_unit_stride_e32 u_lsu_bridge (
      .aclk(aclk),
      .aresetn(aresetn),
      .ctx_valid(lsu_ctx_valid),
      .ctx_is_store(lsu_ctx_is_store),
      .ctx_supported(lsu_ctx_supported),
      // PROJECT_LOCAL_MOD: preserve the issued active element count. The LSU
      // mask remains one bit per element and must not be reinterpreted as
      // four mask bits per e32 word by the board AXI bridge.
      .ctx_elem_count(lsu_ctx_elem_count),
      .ctx_base_addr(lsu_ctx_base_addr),
      .rvv2lsu_valid(rvv2lsu_0_valid),
      .rvv2lsu_idx_valid(rvv2lsu_0_bits_idx_valid),
      .rvv2lsu_idx_addr(rvv2lsu_0_bits_idx_bits_addr),
      .rvv2lsu_idx_data(rvv2lsu_0_bits_idx_bits_data),
      .rvv2lsu_vregfile_valid(rvv2lsu_0_bits_vregfile_valid),
      .rvv2lsu_vregfile_addr(rvv2lsu_0_bits_vregfile_bits_addr),
      .rvv2lsu_vregfile_data(rvv2lsu_0_bits_vregfile_bits_data),
      .rvv2lsu_v0_valid(rvv2lsu_0_bits_mask_valid),
      .rvv2lsu_v0_data(rvv2lsu_0_bits_mask_bits),
      .rvv2lsu_ready(rvv2lsu_0_ready),
      .lsu2rvv_valid(lsu2rvv_0_valid),
      .lsu2rvv_addr(lsu2rvv_0_bits_addr),
      .lsu2rvv_data(lsu2rvv_0_bits_data),
      .lsu2rvv_last(lsu2rvv_0_bits_last),
      .lsu2rvv_ready(lsu2rvv_0_ready),
      .fault_sticky(lsu_fault_sticky),
      .busy(lsu_bridge_busy),
      .debug_req_word_count(lsu_debug_req_word_count),
      .debug_req_mask(lsu_debug_req_mask),
      .m_axi_awvalid(m_axi_awvalid),
      .m_axi_awready(m_axi_awready),
      .m_axi_awaddr(m_axi_awaddr),
      .m_axi_awprot(m_axi_awprot),
      .m_axi_awid(m_axi_awid),
      .m_axi_awlen(m_axi_awlen),
      .m_axi_awsize(m_axi_awsize),
      .m_axi_awburst(m_axi_awburst),
      .m_axi_awlock(m_axi_awlock),
      .m_axi_awcache(m_axi_awcache),
      .m_axi_awqos(m_axi_awqos),
      .m_axi_awregion(m_axi_awregion),
      .m_axi_wvalid(m_axi_wvalid),
      .m_axi_wready(m_axi_wready),
      .m_axi_wdata(m_axi_wdata),
      .m_axi_wstrb(m_axi_wstrb),
      .m_axi_wlast(m_axi_wlast),
      .m_axi_bready(m_axi_bready),
      .m_axi_bvalid(m_axi_bvalid),
      .m_axi_bid(m_axi_bid),
      .m_axi_bresp(m_axi_bresp),
      .m_axi_arvalid(m_axi_arvalid),
      .m_axi_arready(m_axi_arready),
      .m_axi_araddr(m_axi_araddr),
      .m_axi_arprot(m_axi_arprot),
      .m_axi_arid(m_axi_arid),
      .m_axi_arlen(m_axi_arlen),
      .m_axi_arsize(m_axi_arsize),
      .m_axi_arburst(m_axi_arburst),
      .m_axi_arlock(m_axi_arlock),
      .m_axi_arcache(m_axi_arcache),
      .m_axi_arqos(m_axi_arqos),
      .m_axi_arregion(m_axi_arregion),
      .m_axi_rready(m_axi_rready),
      .m_axi_rvalid(m_axi_rvalid),
      .m_axi_rdata(m_axi_rdata),
      .m_axi_rid(m_axi_rid),
      .m_axi_rresp(m_axi_rresp),
      .m_axi_rlast(m_axi_rlast)
  );

  RvvCoreWrapper u_rvv_accel (
      .clk(aclk),
      .rstn(aresetn),
      .vstart(cfg_vstart_reg),
      .vxrm(cfg_vxrm_reg),
      .vxsat(cfg_vxsat_reg),
      .frm(cfg_frm_reg),
      .inst_0_valid(inst_0_valid_reg),
      .inst_0_bits_pc(inst_pc_reg),
      .inst_0_bits_opcode(inst_opcode_reg),
      .inst_0_bits_bits(inst_bits_reg),
      .rs_0_valid(inst_0_valid_reg),
      .rs_0_data(rs0_reg),
      .rs_1_valid(inst_0_valid_reg),
      .rs_1_data(rs1_reg),
      .frs_0(frs0_reg),
      .inst_0_ready(inst_0_ready),
      .rd_0_valid(rd_0_valid),
      .rd_0_bits_addr(rd_0_bits_addr),
      .rd_0_bits_data(rd_0_bits_data),
      .async_rd_valid(async_rd_valid),
      .async_rd_bits_addr(async_rd_bits_addr),
      .async_rd_bits_data(async_rd_bits_data),
      .async_rd_ready(1'b1),
      .async_frd_valid(async_frd_valid),
      .async_frd_bits_addr(async_frd_bits_addr),
      .async_frd_bits_data(async_frd_bits_data),
      .async_frd_ready(1'b1),
      .rvv2lsu_0_valid(rvv2lsu_0_valid),
      .rvv2lsu_0_bits_idx_valid(rvv2lsu_0_bits_idx_valid),
      .rvv2lsu_0_bits_idx_bits_addr(rvv2lsu_0_bits_idx_bits_addr),
      .rvv2lsu_0_bits_idx_bits_data(rvv2lsu_0_bits_idx_bits_data),
      .rvv2lsu_0_bits_vregfile_valid(rvv2lsu_0_bits_vregfile_valid),
      .rvv2lsu_0_bits_vregfile_bits_addr(rvv2lsu_0_bits_vregfile_bits_addr),
      .rvv2lsu_0_bits_vregfile_bits_data(rvv2lsu_0_bits_vregfile_bits_data),
      .rvv2lsu_0_bits_mask_valid(rvv2lsu_0_bits_mask_valid),
      .rvv2lsu_0_bits_mask_bits(rvv2lsu_0_bits_mask_bits),
      .rvv2lsu_0_ready(rvv2lsu_0_ready),
      .rvv2lsu_1_valid(),
      .rvv2lsu_1_bits_idx_valid(),
      .rvv2lsu_1_bits_idx_bits_addr(),
      .rvv2lsu_1_bits_idx_bits_data(),
      .rvv2lsu_1_bits_vregfile_valid(),
      .rvv2lsu_1_bits_vregfile_bits_addr(),
      .rvv2lsu_1_bits_vregfile_bits_data(),
      .rvv2lsu_1_bits_mask_valid(),
      .rvv2lsu_1_bits_mask_bits(),
      .rvv2lsu_1_ready(1'b1),
      .lsu2rvv_0_valid(lsu2rvv_0_valid),
      .lsu2rvv_0_bits_addr(lsu2rvv_0_bits_addr),
      .lsu2rvv_0_bits_data(lsu2rvv_0_bits_data),
      .lsu2rvv_0_bits_last(lsu2rvv_0_bits_last),
      .lsu2rvv_0_ready(lsu2rvv_0_ready),
      .lsu2rvv_1_valid(1'b0),
      .lsu2rvv_1_bits_addr(5'd0),
      .lsu2rvv_1_bits_data(128'd0),
      .lsu2rvv_1_bits_last(1'b0),
      .lsu2rvv_1_ready(),
      .vcsr_valid(vcsr_valid),
      .vcsr_vstart(vcsr_vstart),
      .vcsr_xrm(vcsr_xrm),
      .vcsr_vxsat(vcsr_vxsat),
      .vcsr_ready(1'b1),
      .configStateValid(configStateValid),
      .configVl(configVl),
      .configVstart(configVstart),
      .configMa(configMa),
      .configTa(configTa),
      .configXrm(configXrm),
      .configSew(configSew),
      .configLmul(configLmul),
      .configLmulOrig(configLmulOrig),
      .configVill(configVill),
      .configMtype(configMtype),
      .rvv_idle(rvv_idle),
      .queue_capacity(queue_capacity),
      .rd_rob2rt_o_0_valid(rd_rob2rt_o_0_valid),
      .rd_rob2rt_o_0_w_valid(rd_rob2rt_o_0_w_valid),
      .rd_rob2rt_o_0_w_index(rd_rob2rt_o_0_w_index),
      .rd_rob2rt_o_0_w_data(rd_rob2rt_o_0_w_data),
      .rd_rob2rt_o_0_w_type(rd_rob2rt_o_0_w_type),
      .rd_rob2rt_o_0_vd_type(rd_rob2rt_o_0_vd_type),
      .rd_rob2rt_o_0_trap_flag(rd_rob2rt_o_0_trap_flag),
      .rd_rob2rt_o_0_vector_csr_vl(rd_rob2rt_o_0_vector_csr_vl),
      .rd_rob2rt_o_0_vector_csr_vstart(rd_rob2rt_o_0_vector_csr_vstart),
      .rd_rob2rt_o_0_vector_csr_ma(rd_rob2rt_o_0_vector_csr_ma),
      .rd_rob2rt_o_0_vector_csr_ta(rd_rob2rt_o_0_vector_csr_ta),
      .rd_rob2rt_o_0_vector_csr_xrm(rd_rob2rt_o_0_vector_csr_xrm),
      .rd_rob2rt_o_0_vector_csr_sew(rd_rob2rt_o_0_vector_csr_sew),
      .rd_rob2rt_o_0_vector_csr_lmul(rd_rob2rt_o_0_vector_csr_lmul),
      .rd_rob2rt_o_0_vector_csr_lmul_orig(rd_rob2rt_o_0_vector_csr_lmul_orig),
      .rd_rob2rt_o_0_vector_csr_vill(rd_rob2rt_o_0_vector_csr_vill),
      .rd_rob2rt_o_0_vxsaturate(rd_rob2rt_o_0_vxsaturate),
      .rd_rob2rt_o_0_uop_pc(rd_rob2rt_o_0_uop_pc),
      .rd_rob2rt_o_0_last_uop_valid(rd_rob2rt_o_0_last_uop_valid),
      .trap_valid(trap_valid),
      .trap_bits_pc(trap_bits_pc),
      .trap_bits_opcode(trap_bits_opcode),
      .trap_bits_bits(trap_bits_bits),
      .wr_vxsat_valid_o(wr_vxsat_valid_o),
      .wr_vxsat_o(wr_vxsat_o)
  );

endmodule
