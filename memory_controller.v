`timescale 1ns/1ps
`default_nettype none

module memory_controller #(
    parameter integer MEM_WIDTH     = 256,

    // WEI_MEM_DEPTH = "physical depth"
    // logical bank depth = WEI_MEM_DEPTH/2
    // ex) WEI_MEM_DEPTH=512 -> bank0:0..255, bank1:256..511
    parameter integer WEI_MEM_DEPTH = 512,

    // SCORE_MEM_DEPTH = physical depth for SCOREBUF (2-bank ping-pong)
    parameter integer SCORE_MEM_DEPTH = 512,

    parameter integer GLO_MEM_DEPTH = 2048,
    parameter integer BIAS_DEPTH    = 16,

    parameter integer QUANT_DEPTH   = 64
)(
    input  wire clk,
    input  wire nRst,

    // -------------------------------------------------
    // ALWAYS-DYNAMIC global bank select
    // IN bank  = layer_inbuf_sel
    // GOUT bank= ~layer_inbuf_sel
    // -------------------------------------------------
    input  wire layer_inbuf_sel,

    // -------------------------------------------------
    // Write side (from AXI RDATA sink)
    // -------------------------------------------------
    input  wire        wr_valid,
    input  wire [2:0]  wr_kind,     // 1:IN(global) 2:WGT 3:BIAS 4:SCOREBUF(loader) 5:QUANT
    input  wire        wr_bank,     // WGT bank select(0/1). IN?? ????(????), bias?? ????
    input  wire [10:0] wr_addr,     // word addr (in-bank addr?? ???)
    input  wire [MEM_WIDTH-1:0] wr_data,

    // -------------------------------------------------
    // Read side to PE (global input read)
    // -------------------------------------------------
    input  wire        in_rd_en,
    input  wire [10:0] in_rd_addr,
    output reg  [MEM_WIDTH-1:0] in_rd_data,

    // -------------------------------------------------
    // Read side to PE (weight read) : logical bank + in-bank addr
    // -------------------------------------------------
    input  wire        w_rd_en,
    input  wire        w_rd_bank,
    input  wire [9:0]  w_rd_addr,
    output reg  [MEM_WIDTH-1:0] w_rd_data,

    // -------------------------------------------------
    // Read side for bias
    // -------------------------------------------------
    input  wire        b_rd_en,
    input  wire [5:0]  b_rd_addr,
    output reg  [MEM_WIDTH-1:0] b_rd_data,


    // -------------------------------------------------
    // Read side for quant constants
    // -------------------------------------------------
    input  wire        q_rd_en,
    input  wire [5:0]  q_rd_addr,
    output reg  [MEM_WIDTH-1:0] q_rd_data,

    // -------------------------------------------------
    // Global OUT bank ports for writeback_controller / dump
    // -------------------------------------------------
    input  wire        gout_rd_en,
    input  wire [10:0] gout_rd_addr,
    output reg  [MEM_WIDTH-1:0] gout_rd_data,

        input  wire        gout_wr_valid,
    input  wire [10:0] gout_wr_addr,
    input  wire [MEM_WIDTH-1:0] gout_wr_data,

    // -------------------------------------------------
    // SCOREBUF raw-score buffer ports (1W1R, 2-bank ping-pong)
    // -------------------------------------------------
    input  wire        score_rd_en,
    input  wire        score_rd_bank,
    input  wire [10:0] score_rd_addr,
    output reg  [MEM_WIDTH-1:0] score_rd_data,

    input  wire        score_wr_valid,
    input  wire        score_wr_bank,
    input  wire [10:0] score_wr_addr,
    input  wire [MEM_WIDTH-1:0] score_wr_data

);

    localparam integer WEI_AW   = $clog2(WEI_MEM_DEPTH);
    localparam integer SCORE_AW = $clog2(SCORE_MEM_DEPTH);
    localparam integer GLO_AW  = $clog2(GLO_MEM_DEPTH);
    localparam integer BIAS_AW = $clog2(BIAS_DEPTH);

    localparam integer QUANT_AW = $clog2(QUANT_DEPTH);

    // kind encoding
    localparam [2:0] K_NONE = 3'd0;
    localparam [2:0] K_IN   = 3'd1;
    localparam [2:0] K_WGT  = 3'd2;
    localparam [2:0] K_BIAS = 3'd3;
    localparam [2:0] K_SCORE = 3'd4; // loader -> SCOREBUF (residual cache)
    localparam [2:0] K_QUANT = 3'd5;

    // dynamic selects
    wire sel_in_bank   = layer_inbuf_sel;
    wire sel_gout_bank = ~layer_inbuf_sel;

    // IN write bank is forced to input bank (ignore wr_bank for IN)
    wire in_wr_bank_eff = layer_inbuf_sel;

    // ============================================================
    // Global banks: bank0/1 ???? 1W1R
    // - read : (??? bank?? GOUT bank??) gout_rd ???, ???? in_rd
    // - write: (??? bank?? GOUT bank??) gout_wr ???, ???? loader(K_IN)
    // ============================================================
    wire [MEM_WIDTH-1:0] glo_rdata_b0;
    wire [MEM_WIDTH-1:0] glo_rdata_b1;

    // ---------------- bank0 arb ----------------
    wire bank0_is_gout = (sel_gout_bank == 1'b0);
    wire bank0_is_in   = (sel_in_bank   == 1'b0);

    wire        glo0_we = (bank0_is_gout && gout_wr_valid) ? 1'b1 :
                          (wr_valid && (wr_kind==K_IN) && (in_wr_bank_eff==1'b0));
    wire [GLO_AW-1:0] glo0_waddr = (bank0_is_gout && gout_wr_valid) ? gout_wr_addr[GLO_AW-1:0] :
                                   wr_addr[GLO_AW-1:0];
    wire [MEM_WIDTH-1:0] glo0_wdata = (bank0_is_gout && gout_wr_valid) ? gout_wr_data :
                                      wr_data;

    wire        glo0_re = (bank0_is_gout && gout_rd_en) ? 1'b1 :
                          (in_rd_en && bank0_is_in);
    wire [GLO_AW-1:0] glo0_raddr = (bank0_is_gout && gout_rd_en) ? gout_rd_addr[GLO_AW-1:0] :
                                   in_rd_addr[GLO_AW-1:0];

    ram_1w1r #(
        .DW(MEM_WIDTH), .DEPTH(GLO_MEM_DEPTH), .AW(GLO_AW)
    ) u_glo0 (
        .clk(clk),
        .we(glo0_we), .waddr(glo0_waddr), .wdata(glo0_wdata),
        .re(glo0_re), .raddr(glo0_raddr), .rdata(glo_rdata_b0)
    );

    // ---------------- bank1 arb ----------------
    wire bank1_is_gout = (sel_gout_bank == 1'b1);
    wire bank1_is_in   = (sel_in_bank   == 1'b1);

    wire        glo1_we = (bank1_is_gout && gout_wr_valid) ? 1'b1 :
                          (wr_valid && (wr_kind==K_IN) && (in_wr_bank_eff==1'b1));
    wire [GLO_AW-1:0] glo1_waddr = (bank1_is_gout && gout_wr_valid) ? gout_wr_addr[GLO_AW-1:0] :
                                   wr_addr[GLO_AW-1:0];
    wire [MEM_WIDTH-1:0] glo1_wdata = (bank1_is_gout && gout_wr_valid) ? gout_wr_data :
                                      wr_data;

    wire        glo1_re = (bank1_is_gout && gout_rd_en) ? 1'b1 :
                          (in_rd_en && bank1_is_in);
    wire [GLO_AW-1:0] glo1_raddr = (bank1_is_gout && gout_rd_en) ? gout_rd_addr[GLO_AW-1:0] :
                                   in_rd_addr[GLO_AW-1:0];

    ram_1w1r #(
        .DW(MEM_WIDTH), .DEPTH(GLO_MEM_DEPTH), .AW(GLO_AW)
    ) u_glo1 (
        .clk(clk),
        .we(glo1_we), .waddr(glo1_waddr), .wdata(glo1_wdata),
        .re(glo1_re), .raddr(glo1_raddr), .rdata(glo_rdata_b1)
    );

    // ============================================================
    // Weight: ???? RAM 1???? ???? 2-bank?? ??? (1W1R)
    // ============================================================
    localparam integer WEI_BANK_DEPTH = (WEI_MEM_DEPTH/2);
    localparam integer WEI_BANK_AW    = $clog2(WEI_BANK_DEPTH);

    wire [WEI_AW-1:0] wei_waddr_phys = {wr_bank,   wr_addr[WEI_BANK_AW-1:0]};
    wire [WEI_AW-1:0] wei_raddr_phys = {w_rd_bank, w_rd_addr[WEI_BANK_AW-1:0]};

    wire [MEM_WIDTH-1:0] wei_rdata;

    ram_1w1r #(
        .DW(MEM_WIDTH), .DEPTH(WEI_MEM_DEPTH), .AW(WEI_AW)
    ) u_wei (
        .clk(clk),
        .we( wr_valid && (wr_kind==K_WGT) ),
        .waddr( wei_waddr_phys ),
        .wdata( wr_data ),
        .re( w_rd_en ),
        .raddr( wei_raddr_phys ),
        .rdata( wei_rdata )
    );

    
    // ============================================================
    // SCOREBUF: ping-pong RAM (1W1R) like WEI (bank0/1)
    //   - Each bank holds one mblk's 197 words at addr 0..196
    // ============================================================
    localparam integer SCORE_BANK_DEPTH = (SCORE_MEM_DEPTH/2);
    localparam integer SCORE_BANK_AW    = $clog2(SCORE_BANK_DEPTH);

    // SCOREBUF write mux:
// - core softmax path uses score_wr_*
// - loader path (wr_valid + K_SCORE) can also write SCOREBUF (e.g. residual prefetch)
wire        score_we_eff   = score_wr_valid || (wr_valid && (wr_kind==K_SCORE));
wire        score_bank_eff = score_wr_valid ? score_wr_bank : wr_bank;
wire [10:0] score_addr_eff = score_wr_valid ? score_wr_addr : wr_addr;
wire [MEM_WIDTH-1:0] score_data_eff = score_wr_valid ? score_wr_data : wr_data;

wire [SCORE_AW-1:0] score_waddr_phys = {score_bank_eff, score_addr_eff[SCORE_BANK_AW-1:0]};
wire [SCORE_AW-1:0] score_raddr_phys = {score_rd_bank,  score_rd_addr[SCORE_BANK_AW-1:0]};

    wire [MEM_WIDTH-1:0] score_rdata;

    ram_1w1r #(
        .DW(MEM_WIDTH), .DEPTH(SCORE_MEM_DEPTH), .AW(SCORE_AW)
    ) u_score (
        .clk(clk),
        .we   (score_we_eff),
        .waddr(score_waddr_phys),
        .wdata(score_data_eff),
        .re   (score_rd_en),
        .raddr(score_raddr_phys),
        .rdata(score_rdata)
    );

// ============================================================
    // Bias: LUTRAM(Distributed)
    // ============================================================
    wire [MEM_WIDTH-1:0] bias_rdata;

    ram_1w1r_bias #(
        .DW(MEM_WIDTH), .DEPTH(BIAS_DEPTH), .AW(BIAS_AW)
    ) u_bias (
        .clk(clk),
        .we( wr_valid && (wr_kind==K_BIAS) ),
        .waddr( wr_addr[BIAS_AW-1:0] ),
        .wdata( wr_data ),
        .re( b_rd_en ),
        .raddr( b_rd_addr[BIAS_AW-1:0] ),
        .rdata( bias_rdata )
    );

    

// ============================================================
// Quant constants: LUTRAM(Distributed)
// - 1 word (256b) per layer_id or per-entry index
// ============================================================
wire [MEM_WIDTH-1:0] quant_rdata;

ram_1w1r_bias #(
    .DW(MEM_WIDTH), .DEPTH(QUANT_DEPTH), .AW(QUANT_AW)
) u_quant (
    .clk(clk),
    .we( wr_valid && (wr_kind==K_QUANT) ),
    .waddr( wr_addr[QUANT_AW-1:0] ),
    .wdata( wr_data ),
    .re( q_rd_en ),
    .raddr( q_rd_addr[QUANT_AW-1:0] ),
    .rdata( quant_rdata )
);
// ============================================================
    // Output signals (combinational select)
    // ============================================================
    always @(*) begin
        in_rd_data   = (sel_in_bank   == 1'b0) ? glo_rdata_b0 : glo_rdata_b1;
        gout_rd_data = (sel_gout_bank == 1'b0) ? glo_rdata_b0 : glo_rdata_b1;
        w_rd_data     = wei_rdata;
        b_rd_data     = bias_rdata;
        score_rd_data = score_rdata;
        q_rd_data     = quant_rdata;
    end
endmodule


// ---------------------------------------------------------
// Simple 1W1R synchronous RAM (BRAM inference)
// ---------------------------------------------------------
module ram_1w1r #(
    parameter integer DW = 256,
    parameter integer DEPTH = 1024,
    parameter integer AW = 10
)(
    input  wire clk,
    input  wire we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire re,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] rdata
);
    // synthesis ram_style = "block"
    reg [DW-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata <= mem[raddr];
    end
endmodule


// ---------------------------------------------------------
// Bias LUTRAM (Distributed RAM inference)
// ---------------------------------------------------------
module ram_1w1r_bias #(
    parameter integer DW = 256,
    parameter integer DEPTH = 16,
    parameter integer AW = 4
)(
    input  wire              clk,
    input  wire              we,
    input  wire [AW-1:0]      waddr,
    input  wire [DW-1:0]      wdata,
    input  wire               re,
    input  wire [AW-1:0]      raddr,
    output wire [DW-1:0]      rdata
);
    (* ram_style = "distributed" *) reg [DW-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

    assign rdata = mem[raddr];   // async read
endmodule

`default_nettype wire
