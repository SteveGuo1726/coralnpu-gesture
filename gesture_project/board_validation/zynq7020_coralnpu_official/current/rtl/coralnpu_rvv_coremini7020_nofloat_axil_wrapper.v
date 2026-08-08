// PROJECT_LOCAL_MOD: 7020 board shell wrapper for running project-local
// RvvCoreMini7020NoFloatAxi through a 32-bit AXI-Lite control path from the
// Zynq PS. This is not upstream RTL.
`timescale 1ns / 1ps

module coralnpu_rvv_coremini7020_nofloat_axil_wrapper (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.ACLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET aresetn, FREQ_HZ 25000000" *)
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
    input  wire        s_axi_rready
);

  localparam [31:0] LOCAL_MAGIC_ADDR    = 32'h0004_0000;
  localparam [31:0] LOCAL_STATUS_ADDR   = 32'h0004_0004;
  localparam [31:0] LOCAL_VERSION_ADDR  = 32'h0004_0008;
  localparam [31:0] LOCAL_MAGIC_VALUE   = 32'h4352_4C4E;
  localparam [31:0] LOCAL_VERSION_VALUE = 32'h0001_0000;

  localparam [1:0] WR_IDLE = 2'd0;
  localparam [1:0] WR_CORE = 2'd1;
  localparam [1:0] WR_RESP = 2'd2;

  localparam [1:0] RD_IDLE = 2'd0;
  localparam [1:0] RD_CORE = 2'd1;
  localparam [1:0] RD_RESP = 2'd2;

  reg [1:0] write_state;
  reg [1:0] read_state;

  reg [31:0] wr_addr_reg;
  reg [31:0] wr_data_reg;
  reg [3:0]  wr_strb_reg;
  reg        wr_addr_seen;
  reg        wr_data_seen;
  reg        wr_core_aw_sent;
  reg        wr_core_w_sent;

  reg [31:0] rd_addr_reg;
  reg        rd_core_ar_sent;

  wire [31:0] wr_offset_addr = {12'd0, wr_addr_reg[19:0]};
  wire [31:0] rd_offset_addr = {12'd0, rd_addr_reg[19:0]};
  wire [31:0] ar_offset_addr = {12'd0, s_axi_araddr[19:0]};
  wire [1:0] wr_lane = wr_addr_reg[3:2];
  wire [31:0] wr_aligned_addr = {12'd0, wr_addr_reg[19:4], 4'b0000};
  wire [127:0] wr_shifted_data = ({96'd0, wr_data_reg} << (wr_lane * 32));
  wire [15:0]  wr_shifted_strb = ({12'd0, wr_strb_reg} << (wr_lane * 4));
  wire [31:0] rd_aligned_addr = {12'd0, rd_addr_reg[19:4], 4'b0000};
  wire wr_is_local = (wr_offset_addr == LOCAL_MAGIC_ADDR) ||
                     (wr_offset_addr == LOCAL_STATUS_ADDR) ||
                     (wr_offset_addr == LOCAL_VERSION_ADDR);

  reg [31:0] local_read_data;
  reg [31:0] rd_core_word;

  wire         core_slave_aw_ready;
  wire         core_slave_w_ready;
  wire [5:0]   core_slave_b_id;
  wire [1:0]   core_slave_b_resp;
  wire         core_slave_b_valid;
  wire         core_slave_ar_ready;
  wire [127:0] core_slave_r_data;
  wire [5:0]   core_slave_r_id;
  wire [1:0]   core_slave_r_resp;
  wire         core_slave_r_last;
  wire         core_slave_r_valid;

  reg  core_slave_aw_valid;
  reg  core_slave_w_valid;
  reg  core_slave_b_ready;
  reg  core_slave_ar_valid;
  reg  core_slave_r_ready;

  wire core_halted;
  wire core_fault;
  wire core_wfi;

  always @(*) begin
    case (rd_offset_addr)
      LOCAL_MAGIC_ADDR:   local_read_data = LOCAL_MAGIC_VALUE;
      LOCAL_STATUS_ADDR:  local_read_data = {29'd0, core_fault, core_wfi, core_halted};
      LOCAL_VERSION_ADDR: local_read_data = LOCAL_VERSION_VALUE;
      default:            local_read_data = 32'hDEAD_BEEF;
    endcase
  end

  always @(*) begin
    case (rd_addr_reg[3:2])
      2'd0: rd_core_word = core_slave_r_data[31:0];
      2'd1: rd_core_word = core_slave_r_data[63:32];
      2'd2: rd_core_word = core_slave_r_data[95:64];
      default: rd_core_word = core_slave_r_data[127:96];
    endcase
  end

  always @(*) begin
    s_axi_awready = (write_state == WR_IDLE) && !wr_addr_seen;
    s_axi_wready  = (write_state == WR_IDLE) && !wr_data_seen;
    s_axi_arready = (read_state == RD_IDLE);

    core_slave_aw_valid = (write_state == WR_CORE) && !wr_core_aw_sent;
    core_slave_w_valid  = (write_state == WR_CORE) && !wr_core_w_sent;
    core_slave_b_ready  = (write_state == WR_CORE) && wr_core_aw_sent && wr_core_w_sent;
    core_slave_ar_valid = (read_state == RD_CORE) && !rd_core_ar_sent;
    core_slave_r_ready  = (read_state == RD_CORE) && rd_core_ar_sent;
  end

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      write_state      <= WR_IDLE;
      read_state       <= RD_IDLE;
      wr_addr_reg      <= 32'd0;
      wr_data_reg      <= 32'd0;
      wr_strb_reg      <= 4'd0;
      wr_addr_seen     <= 1'b0;
      wr_data_seen     <= 1'b0;
      wr_core_aw_sent  <= 1'b0;
      wr_core_w_sent   <= 1'b0;
      rd_addr_reg      <= 32'd0;
      rd_core_ar_sent  <= 1'b0;
      s_axi_bvalid     <= 1'b0;
      s_axi_bresp      <= 2'b00;
      s_axi_rvalid     <= 1'b0;
      s_axi_rresp      <= 2'b00;
      s_axi_rdata      <= 32'd0;
    end else begin
      if ((write_state == WR_IDLE) && s_axi_awvalid && s_axi_awready) begin
        wr_addr_reg  <= s_axi_awaddr;
        wr_addr_seen <= 1'b1;
      end
      if ((write_state == WR_IDLE) && s_axi_wvalid && s_axi_wready) begin
        wr_data_reg  <= s_axi_wdata;
        wr_strb_reg  <= s_axi_wstrb;
        wr_data_seen <= 1'b1;
      end

      case (write_state)
        WR_IDLE: begin
          if (wr_addr_seen && wr_data_seen) begin
            if (wr_is_local) begin
              s_axi_bresp  <= 2'b00;
              s_axi_bvalid <= 1'b1;
              write_state  <= WR_RESP;
            end else begin
              wr_core_aw_sent <= 1'b0;
              wr_core_w_sent  <= 1'b0;
              write_state     <= WR_CORE;
            end
          end
        end

        WR_CORE: begin
          if (core_slave_aw_valid && core_slave_aw_ready) begin
            wr_core_aw_sent <= 1'b1;
          end
          if (core_slave_w_valid && core_slave_w_ready) begin
            wr_core_w_sent <= 1'b1;
          end
          if (core_slave_b_ready && core_slave_b_valid) begin
            s_axi_bresp  <= core_slave_b_resp;
            s_axi_bvalid <= 1'b1;
            write_state  <= WR_RESP;
          end
        end

        WR_RESP: begin
          if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid    <= 1'b0;
            s_axi_bresp     <= 2'b00;
            wr_addr_seen    <= 1'b0;
            wr_data_seen    <= 1'b0;
            wr_core_aw_sent <= 1'b0;
            wr_core_w_sent  <= 1'b0;
            write_state     <= WR_IDLE;
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
            if ((ar_offset_addr == LOCAL_MAGIC_ADDR) ||
                (ar_offset_addr == LOCAL_STATUS_ADDR) ||
                (ar_offset_addr == LOCAL_VERSION_ADDR)) begin
              s_axi_rdata  <= local_read_data;
              s_axi_rresp  <= 2'b00;
              s_axi_rvalid <= 1'b1;
              read_state   <= RD_RESP;
            end else begin
              rd_core_ar_sent <= 1'b0;
              read_state      <= RD_CORE;
            end
          end
        end

        RD_CORE: begin
          if (core_slave_ar_valid && core_slave_ar_ready) begin
            rd_core_ar_sent <= 1'b1;
          end
          if (core_slave_r_ready && core_slave_r_valid) begin
            s_axi_rdata  <= rd_core_word;
            s_axi_rresp  <= core_slave_r_resp;
            s_axi_rvalid <= 1'b1;
            read_state   <= RD_RESP;
          end
        end

        RD_RESP: begin
          if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid    <= 1'b0;
            s_axi_rresp     <= 2'b00;
            rd_core_ar_sent <= 1'b0;
            read_state      <= RD_IDLE;
          end
        end

        default: begin
          read_state <= RD_IDLE;
        end
      endcase
    end
  end

  RvvCoreMini7020NoFloatAxi u_rvv_core_mini_axi (
      .io_aclk(aclk),
      .io_aresetn(aresetn),
      .io_axi_slave_write_addr_ready(core_slave_aw_ready),
      .io_axi_slave_write_addr_valid(core_slave_aw_valid),
      .io_axi_slave_write_addr_bits_addr(wr_aligned_addr),
      .io_axi_slave_write_addr_bits_prot(s_axi_awprot),
      .io_axi_slave_write_addr_bits_id(6'd0),
      .io_axi_slave_write_addr_bits_len(8'd0),
      .io_axi_slave_write_addr_bits_size(3'd2),
      .io_axi_slave_write_addr_bits_burst(2'b01),
      .io_axi_slave_write_addr_bits_lock(1'b0),
      .io_axi_slave_write_addr_bits_cache(4'd0),
      .io_axi_slave_write_addr_bits_qos(4'd0),
      .io_axi_slave_write_addr_bits_region(4'd0),
      .io_axi_slave_write_data_ready(core_slave_w_ready),
      .io_axi_slave_write_data_valid(core_slave_w_valid),
      .io_axi_slave_write_data_bits_data(wr_shifted_data),
      .io_axi_slave_write_data_bits_last(1'b1),
      .io_axi_slave_write_data_bits_strb(wr_shifted_strb),
      .io_axi_slave_write_resp_ready(core_slave_b_ready),
      .io_axi_slave_write_resp_valid(core_slave_b_valid),
      .io_axi_slave_write_resp_bits_id(core_slave_b_id),
      .io_axi_slave_write_resp_bits_resp(core_slave_b_resp),
      .io_axi_slave_read_addr_ready(core_slave_ar_ready),
      .io_axi_slave_read_addr_valid(core_slave_ar_valid),
      .io_axi_slave_read_addr_bits_addr(rd_aligned_addr),
      .io_axi_slave_read_addr_bits_prot(s_axi_arprot),
      .io_axi_slave_read_addr_bits_id(6'd0),
      .io_axi_slave_read_addr_bits_len(8'd0),
      .io_axi_slave_read_addr_bits_size(3'd2),
      .io_axi_slave_read_addr_bits_burst(2'b01),
      .io_axi_slave_read_addr_bits_lock(1'b0),
      .io_axi_slave_read_addr_bits_cache(4'd0),
      .io_axi_slave_read_addr_bits_qos(4'd0),
      .io_axi_slave_read_addr_bits_region(4'd0),
      .io_axi_slave_read_data_ready(core_slave_r_ready),
      .io_axi_slave_read_data_valid(core_slave_r_valid),
      .io_axi_slave_read_data_bits_data(core_slave_r_data),
      .io_axi_slave_read_data_bits_id(core_slave_r_id),
      .io_axi_slave_read_data_bits_resp(core_slave_r_resp),
      .io_axi_slave_read_data_bits_last(core_slave_r_last),
      .io_axi_master_write_addr_ready(1'b1),
      .io_axi_master_write_addr_valid(),
      .io_axi_master_write_addr_bits_addr(),
      .io_axi_master_write_addr_bits_prot(),
      .io_axi_master_write_addr_bits_id(),
      .io_axi_master_write_addr_bits_len(),
      .io_axi_master_write_addr_bits_size(),
      .io_axi_master_write_addr_bits_burst(),
      .io_axi_master_write_addr_bits_lock(),
      .io_axi_master_write_addr_bits_cache(),
      .io_axi_master_write_addr_bits_qos(),
      .io_axi_master_write_addr_bits_region(),
      .io_axi_master_write_data_ready(1'b1),
      .io_axi_master_write_data_valid(),
      .io_axi_master_write_data_bits_data(),
      .io_axi_master_write_data_bits_last(),
      .io_axi_master_write_data_bits_strb(),
      .io_axi_master_write_resp_ready(),
      .io_axi_master_write_resp_valid(1'b0),
      .io_axi_master_write_resp_bits_id(6'd0),
      .io_axi_master_write_resp_bits_resp(2'b00),
      .io_axi_master_read_addr_ready(1'b1),
      .io_axi_master_read_addr_valid(),
      .io_axi_master_read_addr_bits_addr(),
      .io_axi_master_read_addr_bits_prot(),
      .io_axi_master_read_addr_bits_id(),
      .io_axi_master_read_addr_bits_len(),
      .io_axi_master_read_addr_bits_size(),
      .io_axi_master_read_addr_bits_burst(),
      .io_axi_master_read_addr_bits_lock(),
      .io_axi_master_read_addr_bits_cache(),
      .io_axi_master_read_addr_bits_qos(),
      .io_axi_master_read_addr_bits_region(),
      .io_axi_master_read_data_ready(),
      .io_axi_master_read_data_valid(1'b0),
      .io_axi_master_read_data_bits_data(128'd0),
      .io_axi_master_read_data_bits_id(6'd0),
      .io_axi_master_read_data_bits_resp(2'b00),
      .io_axi_master_read_data_bits_last(1'b1),
      .io_halted(core_halted),
      .io_fault(core_fault),
      .io_wfi(core_wfi),
      .io_irq(1'b0),
      .io_boot_addr(32'd0),
      .io_timer_irq(1'b0),
      .io_software_irq(1'b0),
      .io_dm_req_ready(),
      .io_dm_req_valid(1'b0),
      .io_dm_req_bits_address(32'd0),
      .io_dm_req_bits_data(1'b0),
      .io_dm_req_bits_op(2'd0),
      .io_dm_rsp_ready(1'b0),
      .io_dm_rsp_valid(),
      .io_dm_rsp_bits_data(),
      .io_dm_rsp_bits_op(),
      .io_te(1'b0)
  );

endmodule
