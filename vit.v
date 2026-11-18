`timescale 1ns/1ps
`default_nettype none

module vit#(
    parameter AXI_ID_WIDTH   = 1,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 256,
    parameter ADDR_LSB       = $clog2(AXI_DATA_WIDTH/8),
    parameter [AXI_ADDR_WIDTH-1:0] DDR_TARGET_SLAVE_BASE_ADDR = 32'h8000_0000
)(
    input  wire clk,
    input  wire aresetn,

    input  wire start,
    output wire done,

    // base word addresses (256b word index, relative to DDR_TARGET_SLAVE_BASE_ADDR)
    input  wire [AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_w_word,
    input  wire [AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_in_word,
    input  wire [AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_q_word,
    input  wire [AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_b_word,
    input  wire [AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_out_word,


    // ========= AXI Master Interface =========
    output wire [AXI_ID_WIDTH-1:0]          m00_axi_awid,
    output wire [AXI_ADDR_WIDTH-1:0]        m00_axi_awaddr,
    output wire [7:0]                       m00_axi_awlen,
    output wire [2:0]                       m00_axi_awsize,
    output wire [1:0]                       m00_axi_awburst,
    output wire                             m00_axi_awlock,
    output wire [3:0]                       m00_axi_awcache,
    output wire [2:0]                       m00_axi_awprot,
    output wire [3:0]                       m00_axi_awqos,
    output wire                             m00_axi_awvalid,
    input  wire                             m00_axi_awready,
    output wire [AXI_DATA_WIDTH-1:0]        m00_axi_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0]      m00_axi_wstrb,
    output wire                             m00_axi_wlast,
    output wire                             m00_axi_wvalid,
    input  wire                             m00_axi_wready,
    input  wire [AXI_ID_WIDTH-1:0]          m00_axi_bid,
    input  wire [1:0]                       m00_axi_bresp,
    input  wire                             m00_axi_bvalid,
    output wire                             m00_axi_bready,

    output wire [AXI_ID_WIDTH-1:0]          m00_axi_arid,
    output wire [AXI_ADDR_WIDTH-1:0]        m00_axi_araddr,
    output wire [7:0]                       m00_axi_arlen,
    output wire [2:0]                       m00_axi_arsize,
    output wire [1:0]                       m00_axi_arburst,
    output wire                             m00_axi_arlock,
    output wire [3:0]                       m00_axi_arcache,
    output wire [2:0]                       m00_axi_arprot,
    output wire [3:0]                       m00_axi_arqos,
    output wire                             m00_axi_arvalid,
    input  wire                             m00_axi_arready,
    input  wire [AXI_ID_WIDTH-1:0]          m00_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0]        m00_axi_rdata,
    input  wire [1:0]                       m00_axi_rresp,
    input  wire                             m00_axi_rlast,
    input  wire                             m00_axi_rvalid,
    output wire                             m00_axi_rready
);

    // -------------------------
    // AXI Master <-> controller_top simple IF
    // -------------------------
    wire                        m_axi_read_done;
    wire                        m_axi_read_init;
    wire [AXI_ADDR_WIDTH-1:0]   m_axi_araddress;
    wire [16:0]                 m_axi_read_length;

    wire                        m_axi_write_done;
    wire                        m_axi_write_init;
    wire [AXI_ADDR_WIDTH-1:0]   m_axi_awaddress;
    wire [16:0]                 m_axi_write_length;

    // -------------------------
    // controller_top -> AXI_Master WDATA stream
    // -------------------------
    wire                        dump_wvalid;
    wire [AXI_DATA_WIDTH-1:0]   dump_wdata;
    wire                        dump_wready;

    // -------------------------
    // controller_top -> memory_controller write port (DDR->SRAM)
    // -------------------------
    wire                        mem_wr_valid;
    wire [2:0]                  mem_wr_kind;
    wire                        mem_wr_bank;
    wire [10:0]                 mem_wr_addr;
    wire [AXI_DATA_WIDTH-1:0]   mem_wr_data;

    // -------------------------
    // writeback_controller <-> memory_controller ports (RMW)
    // -------------------------
    wire         gout_rd_en;
    wire [10:0]  gout_rd_addr;
    wire [255:0] gout_rd_data;

    wire         gout_wr_valid;
    wire [10:0]  gout_wr_addr;
    wire [255:0] gout_wr_data;

    // SCOREBUF raw-score buffer (ping-pong)
    // NOTE: score_rd port is shared between controller_top(writeback) and FC2 feeder (bring-up)
    wire         score_rd_en_wb;
    wire         score_rd_bank_wb;
    wire [10:0]  score_rd_addr_wb;

    wire         score_rd_en;
    wire         score_rd_bank;
    wire [10:0]  score_rd_addr;
    wire [255:0] score_rd_data;

    wire         score_wr_valid;
    wire         score_wr_bank;
    wire [10:0]  score_wr_addr;
    wire [255:0] score_wr_data;

    wire         bias_rd_en;
    wire [5:0]   bias_rd_addr;
    wire [255:0] bias_rd_data;


    // quant constants
    wire         quant_rd_en;
    wire [5:0]   quant_rd_addr;
    wire [255:0] quant_rd_data;
    // -------------------------
    // PE feeder <-> memory_controller read ports
    //  - [FIX] in_rd_bank 
    // -------------------------
    wire         in_rd_en;
    wire [10:0]  in_rd_addr;
    wire [255:0] in_rd_data;

    // Global IN read (FC2 residual add) from writeback_controller via controller_top
    wire         gin_rd_en;
    wire [10:0]  gin_rd_addr;
    wire [255:0] gin_rd_data;

    wire         w_rd_en;
    wire         w_rd_bank;
    wire [9:0]   w_rd_addr;
    wire [255:0] w_rd_data;


    // -------------------------
    // FC2 bring-up muxing:
    //  - FC2 input comes from SCOREBUF(bank0) addressed by feeder's in_rd_* (stride=32)
    //  - Disable global IN read port during FC2
    // -------------------------
    assign in_rd_en_mem   = is_fc2 ? gin_rd_en : in_rd_en;
    assign in_rd_addr_mem = is_fc2 ? gin_rd_addr : in_rd_addr;

    assign feeder_in_rd_data = is_fc2 ? score_rd_data : in_rd_data;

    // gin_rd_data taps memory_controller IN read data (unused by feeder during FC2)
    assign gin_rd_data = in_rd_data;

    assign score_rd_en   = is_fc2 ? in_rd_en   : score_rd_en_wb;
    assign score_rd_bank = is_fc2 ? 1'b0       : score_rd_bank_wb;
    assign score_rd_addr = is_fc2 ? in_rd_addr : score_rd_addr_wb;

    // -------------------------
    // PE array <-> controller_top writeback ports
    // -------------------------
    wire                    pe_out_col_valid;
    wire                    pe_out_col_ready;
    wire [4:0]              pe_out_col_idx;
    wire [32*32-1:0]        pe_out_col_data_flat;

    wire                    pe_array_busy;
    wire                    pe_array_done;

    // -------------------------
    // vit_controller <-> feeder job interface (via controller_top)
    // -------------------------
    wire        pe_ready;
    wire        pe_start;
    wire        pe_done;

    wire [9:0]  pe_klen;
    wire [4:0] pe_ktile;

    // FC2 bring-up detection: K=32 (tile0 only)
    wire is_fc2 = (pe_klen == 10'd32);

    // feeder IN read data mux (global input vs SCOREBUF)
    wire [255:0] feeder_in_rd_data;

    // gate global IN read port when FC2 (we use score_rd instead)
    wire        in_rd_en_mem;
    wire [10:0] in_rd_addr_mem;

    wire [2:0]  pe_nblk;
    wire [2:0]  pe_mblk;
    wire        pe_wbuf_sel;
    wire        pe_swap_ab;
    wire        pe_in_base_is_nblk;
    wire [9:0]  pe_in_koff;
    wire        pe_a_is_qlog;
wire        layer_inbuf_sel;  // ( global bank select )

    wire [4:0] wb_ktile_idx;
    wire [2:0]  wb_nblk_idx;
    wire [2:0]  wb_mblk_idx;

    // -------------------------
    // controller_top
    // -------------------------
    controller_top #(
        .M_AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .M_AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .RUN_QKV(8)
    ) ctrl (
        .clk(clk),
        .nRst(aresetn),

        .start(start),
        .done(done),

        .m_axi_read_done(m_axi_read_done),
        .m_axi_read_init(m_axi_read_init),
        .m_axi_araddress(m_axi_araddress),
        .m_axi_read_length(m_axi_read_length),

        .m_axi_write_done(m_axi_write_done),
        .m_axi_write_init(m_axi_write_init),
        .m_axi_awaddress(m_axi_awaddress),
        .m_axi_write_length(m_axi_write_length),

        .m_axi_wvalid(dump_wvalid),
        .m_axi_wdata (dump_wdata),
        .m_axi_wready(dump_wready),

        .base_in_word (base_in_word),
        .base_w_word  (base_w_word),
        .base_b_word  (base_b_word),
        .base_out_word(base_out_word),
        .base_q_word  (base_q_word),

        .quant_rd_en  (quant_rd_en),
        .quant_rd_addr(quant_rd_addr),
        .quant_rd_data(quant_rd_data),

        .axi_rvalid(m00_axi_rvalid),
        .axi_rdata (m00_axi_rdata),
        .axi_rlast (m00_axi_rlast),
        .axi_rready(m00_axi_rready),

        .mem_wr_valid(mem_wr_valid),
        .mem_wr_kind (mem_wr_kind),
        .mem_wr_bank (mem_wr_bank),
        .mem_wr_addr (mem_wr_addr),
        .mem_wr_data (mem_wr_data),

        .gout_rd_en  (gout_rd_en),
        .gout_rd_addr(gout_rd_addr),
        .gout_rd_data(gout_rd_data),

        .gin_rd_en   (gin_rd_en),
        .gin_rd_addr (gin_rd_addr),
        .gin_rd_data (gin_rd_data),

        .gout_wr_valid(gout_wr_valid),
        .gout_wr_addr (gout_wr_addr),
        .gout_wr_data (gout_wr_data),

        .score_rd_en  (score_rd_en_wb),
        .score_rd_bank(score_rd_bank_wb),
        .score_rd_addr(score_rd_addr_wb),
        .score_rd_data(score_rd_data),

        .score_wr_valid(score_wr_valid),
        .score_wr_bank (score_wr_bank),
        .score_wr_addr (score_wr_addr),
        .score_wr_data (score_wr_data),

        .bias_rd_en  (bias_rd_en),
        .bias_rd_addr(bias_rd_addr),
        .bias_rd_data(bias_rd_data),

        .pe_out_col_valid     (pe_out_col_valid),
        .pe_out_col_ready     (pe_out_col_ready),
        .pe_out_col_idx       (pe_out_col_idx),
        .pe_out_col_data_flat (pe_out_col_data_flat),

        .wb_ktile_idx(wb_ktile_idx),
        .wb_nblk_idx (wb_nblk_idx),
        .wb_mblk_idx (wb_mblk_idx),

        .pe_ready(pe_ready),
        .pe_done (pe_done),
        .pe_start(pe_start),

        .pe_klen     (pe_klen),
        .pe_ktile    (pe_ktile),
        .pe_nblk     (pe_nblk),
        .pe_mblk     (pe_mblk),
        .pe_wbuf_sel (pe_wbuf_sel),
        .pe_swap_ab  (pe_swap_ab),
        .pe_in_koff  (pe_in_koff),
        
                .pe_in_base_is_nblk(pe_in_base_is_nblk),
        .pe_a_is_qlog      (pe_a_is_qlog),
.pe_inbuf_sel(layer_inbuf_sel)
    );

    // -------------------------
    // memory_controller (? SRAM)
    //  - [ASSUME] always-dynamic :
    //    * in bank  layer_inbuf_sel 
    //    * (gout bank ?? ~layer_inbuf_sel ??? )
    //  - [FIX] in_rd_bank ? 
    // -------------------------
    memory_controller #(
        .MEM_WIDTH(AXI_DATA_WIDTH),
        .WEI_MEM_DEPTH(512),
        .SCORE_MEM_DEPTH(512),
        .GLO_MEM_DEPTH(2048),
        .BIAS_DEPTH(64)
    ) mem_ctrl (
        .clk(clk),
        .nRst(aresetn),

        .wr_valid(mem_wr_valid),
        .wr_kind (mem_wr_kind),
        .wr_bank (mem_wr_bank),
        .wr_addr (mem_wr_addr),
        .wr_data (mem_wr_data),

        // dynamic global bank select
        .layer_inbuf_sel(layer_inbuf_sel),

        // feeder reads (IN)
        .in_rd_en  (in_rd_en_mem),
        .in_rd_addr(in_rd_addr_mem),
        .in_rd_data(in_rd_data),

        // feeder reads (WGT)
        .w_rd_en   (w_rd_en),
        .w_rd_bank (w_rd_bank),
        .w_rd_addr (w_rd_addr),
        .w_rd_data (w_rd_data),

        // bias read for writeback
        .b_rd_en  (bias_rd_en),
        .b_rd_addr(bias_rd_addr),
        .b_rd_data(bias_rd_data),

        // quant read for writeback
        .q_rd_en  (quant_rd_en),
        .q_rd_addr(quant_rd_addr),
        .q_rd_data(quant_rd_data),


        // global out bank R/W for writeback
        .gout_rd_en  (gout_rd_en),
        .gout_rd_addr(gout_rd_addr),
        .gout_rd_data(gout_rd_data),

        .gout_wr_valid(gout_wr_valid),
        .gout_wr_addr (gout_wr_addr),
        .gout_wr_data (gout_wr_data),

        .score_rd_en  (score_rd_en),
        .score_rd_bank(score_rd_bank),
        .score_rd_addr(score_rd_addr),
        .score_rd_data(score_rd_data),

        .score_wr_valid(score_wr_valid),
        .score_wr_bank (score_wr_bank),
        .score_wr_addr (score_wr_addr),
        .score_wr_data (score_wr_data)
    );

    // -------------------------
    // PE feeder (2-slot WEI)
    //  - [FIX] job_inbuf_sel 
    //  - [FIX] in_rd_bank 
    // -------------------------
    wire feeder_ready;
    wire feeder_done;

    wire pe_in_valid;
    wire pe_first;
    wire pe_tile_last;
    wire [32*8-1:0] a_rows_flat;
    wire [32*8-1:0] b_cols_flat;

    pe_feeder #(
        .AXI_DATA_WIDTH(256),
        .MAX_KTILE(197)
    ) u_feeder (
        .clk(clk),
        .nRst(aresetn),

        .job_start   (pe_start),
        .job_klen    (pe_klen),
        .job_ktile   (pe_ktile),
        .job_nblk    (pe_nblk),
        .job_mblk    (pe_mblk),
        .job_in_base_is_nblk(pe_in_base_is_nblk),
        .job_in_koff (pe_in_koff),
        .job_wbuf_sel(pe_wbuf_sel),
        .swap_ab    (pe_swap_ab),

        .job_ready(feeder_ready),
        .job_done (feeder_done),

        .wb_ktile_idx(wb_ktile_idx),
        .wb_nblk_idx (wb_nblk_idx),
        .wb_mblk_idx (wb_mblk_idx),

        .in_rd_en  (in_rd_en),
        .in_rd_addr(in_rd_addr),
        .in_rd_data(feeder_in_rd_data),

        .w_rd_en   (w_rd_en),
        .w_rd_bank (w_rd_bank),
        .w_rd_addr (w_rd_addr),
        .w_rd_data (w_rd_data),

        .pe_in_valid   (pe_in_valid),
        .pe_first      (pe_first),
        .pe_tile_last  (pe_tile_last),
        .pe_a_rows_flat(a_rows_flat),
        .pe_b_cols_flat(b_cols_flat),

        .pe_array_busy(pe_array_busy),
        .pe_array_done(pe_array_done)
    );

    assign pe_ready = feeder_ready;
    assign pe_done  = feeder_done;

    // -------------------------
    // pe_array
    // -------------------------
    pe_array #(
        .OUTW(32)
    ) systolic_array (
        .clk(clk),
        .nRst(aresetn),

        .in_valid  (pe_in_valid),
        .first     (pe_first),
        .tile_last (pe_tile_last),

        .a_is_qlog (pe_a_is_qlog),
        .a_rows_flat(a_rows_flat),
        .b_cols_flat(b_cols_flat),

        .out_col_valid    (pe_out_col_valid),
        .out_col_ready    (pe_out_col_ready),
        .out_col_idx      (pe_out_col_idx),
        .out_col_data_flat(pe_out_col_data_flat),

        .busy(pe_array_busy),
        .done(pe_array_done)
    );

    // -------------------------
    // AXI_Master (DDR)
    // -------------------------
    wire ddr_last_data;

    AXI_Master #(
        .C_M_TARGET_SLAVE_BASE_ADDR(DDR_TARGET_SLAVE_BASE_ADDR),
        .C_M_AXI_ID_WIDTH(AXI_ID_WIDTH),
        .C_M_AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .C_M_AXI_DATA_WIDTH(AXI_DATA_WIDTH)
    ) AXI_Master_DDR (
        .INIT_AXI_TXN_W(m_axi_write_init),
        .INIT_AXI_TXN_R(m_axi_read_init),
        .init_axi_awaddr(m_axi_awaddress),
        .init_axi_araddr(m_axi_araddress),
        .init_write_length(m_axi_write_length),
        .init_read_length (m_axi_read_length),
        .write_done(m_axi_write_done),
        .read_done (m_axi_read_done),
        .read_last(ddr_last_data),

        .S_WDATA (dump_wdata),
        .S_WVALID(dump_wvalid),
        .S_WREADY(dump_wready),

        .M_AXI_ACLK(clk),
        .M_AXI_ARESETN(aresetn),

        .M_AXI_AWID   (m00_axi_awid),
        .M_AXI_AWADDR (m00_axi_awaddr),
        .M_AXI_AWLEN  (m00_axi_awlen),
        .M_AXI_AWSIZE (m00_axi_awsize),
        .M_AXI_AWBURST(m00_axi_awburst),
        .M_AXI_AWLOCK (m00_axi_awlock),
        .M_AXI_AWCACHE(m00_axi_awcache),
        .M_AXI_AWPROT (m00_axi_awprot),
        .M_AXI_AWQOS  (m00_axi_awqos),
        .M_AXI_AWVALID(m00_axi_awvalid),
        .M_AXI_AWREADY(m00_axi_awready),

        .M_AXI_WDATA (m00_axi_wdata),
        .M_AXI_WSTRB (m00_axi_wstrb),
        .M_AXI_WLAST (m00_axi_wlast),
        .M_AXI_WVALID(m00_axi_wvalid),
        .M_AXI_WREADY(m00_axi_wready),

        .M_AXI_BID   (m00_axi_bid),
        .M_AXI_BRESP (m00_axi_bresp),
        .M_AXI_BVALID(m00_axi_bvalid),
        .M_AXI_BREADY(m00_axi_bready),

        .M_AXI_ARID   (m00_axi_arid),
        .M_AXI_ARADDR (m00_axi_araddr),
        .M_AXI_ARLEN  (m00_axi_arlen),
        .M_AXI_ARSIZE (m00_axi_arsize),
        .M_AXI_ARBURST(m00_axi_arburst),
        .M_AXI_ARLOCK (m00_axi_arlock),
        .M_AXI_ARCACHE(m00_axi_arcache),
        .M_AXI_ARPROT (m00_axi_arprot),
        .M_AXI_ARQOS  (m00_axi_arqos),
        .M_AXI_ARVALID(m00_axi_arvalid),
        .M_AXI_ARREADY(m00_axi_arready),

        .M_AXI_RID   (m00_axi_rid),
        .M_AXI_RRESP (m00_axi_rresp),
        .M_AXI_RLAST (m00_axi_rlast),
        .M_AXI_RVALID(m00_axi_rvalid),
        .M_AXI_RREADY(m00_axi_rready)
    );

endmodule

`default_nettype wire
