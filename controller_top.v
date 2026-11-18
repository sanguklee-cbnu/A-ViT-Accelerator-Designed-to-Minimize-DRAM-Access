`timescale 1ns/1ps
`default_nettype none

module controller_top #(
    parameter integer M_AXI_DATA_WIDTH = 256,
    parameter integer M_AXI_ADDR_WIDTH = 32,
    parameter integer ADDR_LSB         = $clog2(M_AXI_DATA_WIDTH/8),

    parameter integer M_BLK_NUM   = 7,
    parameter integer N_BLK_NUM   = 6,
    parameter integer OUT_STRIDE  = 197,

    // vit_controller base word-index width
    parameter integer BASE_AW     = (M_AXI_ADDR_WIDTH-ADDR_LSB),

    // ---- Run control ----
        parameter integer RUN_QKV     = 6,      // 0: PATCH only, 1: PATCH->Q, 2: PATCH->Q->V, 3: PATCH->Q->V->K, 4: +SCORE(head0)
    parameter integer DUMP_ENABLE = 1,      // 0: disable DDR dump, 1: enable
    parameter [3:0]   DUMP_LAYER_ID = 4'd1, // default: dump Q layer (1). PATCH=0
    parameter integer FINAL_OUT_WRITE_ENABLE = 1 // 1: always write final MLP output to DDR
)(
    input  wire clk,
    input  wire nRst,

    input  wire start,
    output wire done,

    // AXI read/write to DDR (simple control IF)
    input  wire                        m_axi_read_done,
    output wire                        m_axi_read_init,
    output wire [M_AXI_ADDR_WIDTH-1:0] m_axi_araddress,
    output wire [16:0]                 m_axi_read_length,

    input  wire                        m_axi_write_done,
    output wire                        m_axi_write_init,
    output wire [M_AXI_ADDR_WIDTH-1:0] m_axi_awaddress,
    output wire [16:0]                 m_axi_write_length,

    // ---- Source-side WDATA stream to AXI_Master ----
    output wire [M_AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output wire                        m_axi_wvalid,
    input  wire                        m_axi_wready,

    // (optional) keep for debug
    output wire                        m_axi_wlast,

    // base addresses (word index)
    input  wire [BASE_AW-1:0] base_in_word,
    input  wire [BASE_AW-1:0] base_w_word,
    input  wire [BASE_AW-1:0] base_b_word,
    input  wire [BASE_AW-1:0] base_out_word,

    input  wire [BASE_AW-1:0] base_q_word,
    // AXI R-channel tap
    input  wire                         axi_rvalid,
    input  wire [M_AXI_DATA_WIDTH-1:0]  axi_rdata,
    input  wire                         axi_rlast,
    input  wire                         axi_rready,

    // DDR->SRAM write port
    output wire                         mem_wr_valid,
    output wire [2:0]                   mem_wr_kind,   // 1:IN 2:WGT 3:BIAS
    output wire                         mem_wr_bank,
    output wire [10:0]                  mem_wr_addr,
    output wire [M_AXI_DATA_WIDTH-1:0]  mem_wr_data,

    // PE output (to writeback)
    input  wire                    pe_out_col_valid,
    output wire                    pe_out_col_ready,
    input  wire [4:0]              pe_out_col_idx,
    input  wire [32*32-1:0]        pe_out_col_data_flat,

    // Global OUT bank port (to memory_controller)
    output wire                    gout_rd_en,
    output wire [10:0]             gout_rd_addr,
    input  wire [255:0]            gout_rd_data,
    
    // Global IN read (FC2 residual add) from memory_controller IN bank
    output wire                    gin_rd_en,
    output wire [10:0]             gin_rd_addr,
    input  wire [255:0]            gin_rd_data,

    output wire                    gout_wr_valid,
    output wire [10:0]             gout_wr_addr,
    output wire [255:0]            gout_wr_data,


    // SCOREBUF raw-score buffer (ping-pong) R/W for SCORE softmax
    output wire                    score_rd_en,
    output wire                    score_rd_bank,
    output wire [10:0]             score_rd_addr,
    input  wire [255:0]            score_rd_data,

    output wire                    score_wr_valid,
    output wire                    score_wr_bank,
    output wire [10:0]             score_wr_addr,
    output wire [255:0]            score_wr_data,

    // Bias port
    output wire                    bias_rd_en,
    output wire [5:0]              bias_rd_addr,
    input  wire [255:0]            bias_rd_data,

    // quant constants read port
    output wire        quant_rd_en,
    output wire [5:0]  quant_rd_addr,
    input  wire [255:0] quant_rd_data,
    // Compute handshake
    input  wire pe_ready,
    input  wire pe_done,
    output wire pe_start,

    // Job descriptor export
    output wire [9:0] pe_klen,
    output wire [4:0] pe_ktile,
    output wire [2:0] pe_nblk,
    output wire [2:0] pe_mblk,

    input  wire [4:0] wb_ktile_idx,
    input  wire [2:0] wb_nblk_idx,
    input  wire [2:0] wb_mblk_idx,

    output wire       pe_wbuf_sel,
    output wire       pe_inbuf_sel, // (memory_controller bank sel)
    output wire       pe_swap_ab,
    output wire [9:0] pe_in_koff,
    output wire       pe_in_base_is_nblk,
    output wire       pe_a_is_qlog
);
    `include "addr_map.vh"


// ---------------- layer id constants (keep consistent with vit_controller) ----------------
localparam [3:0] L_PATCH  = 4'd0;
localparam [3:0] L_QKV_Q  = 4'd1;
localparam [3:0] L_QKV_V  = 4'd2;
localparam [3:0] L_O_PROJ = 4'd6;

localparam [3:0] L_MLP_FC2 = 4'd8;
    
localparam [3:0] L_CLS0   = 4'd9;
localparam [3:0] L_CLS1   = 4'd10;
localparam [3:0] L_CLS2   = 4'd11;
localparam [3:0] L_CLS3   = 4'd12;
localparam [3:0] L_CLS4   = 4'd13;
localparam [3:0] L_CLS5   = 4'd14;
// ---------------- vit<->read interconnect ----------------
    wire layer_active, layer_start_pulse;
    wire [4:0] ktile_idx_cur;
    wire [6:0] mblk_release_pulse;
    wire [1:0] wgt_slot_release_pulse;


    // next-layer W0 prefetch (PATCH->QKV_Q)
    wire        nl_wgt0_prefetch_pulse;
    wire [3:0]  nl_wgt0_layer_id;
    wire [4:0]  nl_wgt0_ktile;
    wire [2:0]  nl_wgt0_nblk;
    wire        nl_wgt0_bank;
    wire [BASE_AW-1:0] nl_wgt0_base_w_word;

    wire vit_done;

    wire bias_ready;
    wire quant_ready;
    wire [6:0] in_ready_cur;
    wire [5:0] w_ready_cur;
wire [5:0] res_ready_cur;

    wire [2:0] res_upto0, res_upto1, res_upto2, res_upto3, res_upto4, res_upto5;
    // layer broadcast
    wire [3:0] layer_id;
    wire [1:0]       layer_head_idx;
wire [3:0]       enc_blk_idx;
    wire             layer_wgt_phase;
wire [5:0] w_ready_vit;
assign w_ready_vit = (layer_id == L_O_PROJ) ? (w_ready_cur & res_ready_cur) : w_ready_cur;
    // Swap A/B inputs for V projection (layer_id==2) and SCORE (layer_id==4)
    assign pe_swap_ab = (layer_id == 4'd2) || (layer_id == 4'd4);
    // SCORE: input base uses nblk (K block) rather than mblk
    assign pe_in_base_is_nblk = (layer_id == 4'd4);
    assign pe_in_koff      = (layer_id == 4'd4) ? ({layer_head_idx, 6'd0}) : 10'd0;
assign pe_a_is_qlog      = (layer_id == 4'd5);
    wire [4:0] layer_final_ktile;
    wire       layer_inbuf_sel;

    // layer-end synchronization
    wire layer_end_pulse;
    wire layer_adv_grant;

    // next-layer W0 prefetch completion (from read_controller)
    wire        nl_pf_valid;
    wire [3:0]  nl_pf_layer;
    wire [4:0]  nl_pf_ktile;
    wire [2:0]  nl_pf_nblk;
    wire        nl_pf_bank;

    // With layer-end wait enabled (vit_controller_wait), layer_id is held
    // stable until all DDR dumps for the layer are completed.
    wire [3:0] layer_id_dump = layer_id;

    // per-layer base (from vit_controller)
    wire [BASE_AW-1:0] rd_base_in_word;
    wire [BASE_AW-1:0] rd_base_w_word;
    wire [BASE_AW-1:0] rd_base_b_word;
    wire [BASE_AW-1:0] rd_base_out_word;

    // ---------------- vit_controller ----------------
    vit_controller #(
        .BASE_AW (BASE_AW),
        .RUN_QKV (RUN_QKV)
    ) u_vit (
        .clk(clk),
        .nRst(nRst),

        .start(start),
        .done(vit_done),

        .bias_ready(bias_ready),
        .quant_ready(quant_ready),
        .in_ready_cur(in_ready_cur),
        .w_ready_cur(w_ready_vit),

        .nl_pf_valid(nl_pf_valid),
        .nl_pf_layer(nl_pf_layer),
        .nl_pf_ktile(nl_pf_ktile),
        .nl_pf_nblk (nl_pf_nblk),
        .nl_pf_bank(nl_pf_bank),

        .layer_end_pulse(layer_end_pulse),
        .layer_adv_grant(layer_adv_grant),

        .layer_id(layer_id),
        .layer_final_ktile(layer_final_ktile),
        .layer_inbuf_sel(layer_inbuf_sel),
        .layer_head_idx(layer_head_idx),
        .enc_blk_idx (enc_blk_idx),
        .layer_wgt_phase(layer_wgt_phase),

        .layer_active(layer_active),
        .layer_start_pulse(layer_start_pulse),
        .ktile_idx_cur(ktile_idx_cur),
        .mblk_release_pulse(mblk_release_pulse),
        .wgt_slot_release_pulse(wgt_slot_release_pulse),


        .nl_wgt0_prefetch_pulse(nl_wgt0_prefetch_pulse),
        .nl_wgt0_layer_id      (nl_wgt0_layer_id),
        .nl_wgt0_ktile         (nl_wgt0_ktile),
        .nl_wgt0_nblk          (nl_wgt0_nblk),
        .nl_wgt0_bank          (nl_wgt0_bank),
        .nl_wgt0_base_w_word   (nl_wgt0_base_w_word),

        .pe_ready(pe_ready),
        .pe_start(pe_start),
        .pe_done(pe_done),

        .pe_klen     (pe_klen),
        .pe_ktile    (pe_ktile),
        .pe_nblk     (pe_nblk),
        .pe_mblk     (pe_mblk),
        .pe_wbuf_sel (pe_wbuf_sel),
        .pe_inbuf_sel(pe_inbuf_sel),

        .base_in_word (base_in_word),
        .base_w_word  (base_w_word),
        .base_b_word  (base_b_word),
        .base_out_word(base_out_word),

        .rd_base_in_word (rd_base_in_word),
        .rd_base_w_word  (rd_base_w_word),
        .rd_base_b_word  (rd_base_b_word),
        .rd_base_out_word(rd_base_out_word)
    );

    // Quantization constants are stored per encoder block (word index):
    // - Normal encoder layers use enc_blk_idx (0..ENC_BLK_NUM-1).
    // - Classifier head (L_CLS0..L_CLS5) uses the dedicated quant block at index ENC_BLK_NUM,
    //   because gen_memhex.py appends classifier quant words after all encoder blocks.
    //   (Keep enc_blk_idx unchanged so global-buffer ping-pong still matches the last encoder block output.)
    wire is_cls_layer = ((layer_id >= L_CLS0) && (layer_id <= L_CLS5));
    wire [3:0] q_blk_idx_sel = is_cls_layer ? ENC_BLK_NUM[3:0] : enc_blk_idx;
    // base_q_word_eff = base_q_word + q_blk_idx_sel*16  (layer_id is used as index 0..15 inside read_controller)
    wire [BASE_AW-1:0] enc_blk_q_off    = ({ {(BASE_AW-4){1'b0}}, q_blk_idx_sel } << 4);
    wire [BASE_AW-1:0] base_q_word_eff  = base_q_word + enc_blk_q_off;


// ---------------- read_controller ----------------
    read_controller u_read (
        .clk(clk),
        .nRst(nRst),

        .layer_active(layer_active),
        .layer_start_pulse(layer_start_pulse),
        .ktile_idx_cur(ktile_idx_cur),

        .layer_id(layer_id),
        .layer_final_ktile(layer_final_ktile),
        .layer_inbuf_sel(layer_inbuf_sel),
        .layer_head_idx(layer_head_idx),
        .layer_wgt_phase(layer_wgt_phase),

        .mblk_release_pulse(mblk_release_pulse),
        .wgt_slot_release_pulse(wgt_slot_release_pulse),


        .nl_wgt0_prefetch_pulse(nl_wgt0_prefetch_pulse),
        .nl_wgt0_layer_id      (nl_wgt0_layer_id),
        .nl_wgt0_ktile         (nl_wgt0_ktile),
        .nl_wgt0_nblk          (nl_wgt0_nblk),
        .nl_wgt0_bank          (nl_wgt0_bank),
        .nl_wgt0_base_w_word   (nl_wgt0_base_w_word),

        .base_in_word (rd_base_in_word),
        .base_w_word  (rd_base_w_word),
        .base_b_word  (rd_base_b_word),
        .base_out_word(rd_base_out_word),
        .base_q_word(base_q_word_eff),

        .m_axi_read_done(m_axi_read_done),
        .m_axi_read_init(m_axi_read_init),
        .m_axi_araddress(m_axi_araddress),
        .m_axi_read_length(m_axi_read_length),

        .bias_ready(bias_ready),
        .quant_ready(quant_ready),
        .in_ready_cur(in_ready_cur),
        .w_ready_cur(w_ready_cur),
        .res_ready_cur(res_ready_cur),

        .res_upto0(res_upto0),
        .res_upto1(res_upto1),
        .res_upto2(res_upto2),
        .res_upto3(res_upto3),
        .res_upto4(res_upto4),
        .res_upto5(res_upto5),

        .nl_pf_valid(nl_pf_valid),
        .nl_pf_layer(nl_pf_layer),
        .nl_pf_ktile(nl_pf_ktile),
        .nl_pf_nblk (nl_pf_nblk),
        .nl_pf_bank(nl_pf_bank),
        .axi_rvalid(axi_rvalid),
        .axi_rdata (axi_rdata),
        .axi_rlast (axi_rlast),
        .axi_rready(axi_rready),

        .mem_wr_valid(mem_wr_valid),
        .mem_wr_kind (mem_wr_kind),
        .mem_wr_bank (mem_wr_bank),
        .mem_wr_addr (mem_wr_addr),
        .mem_wr_data (mem_wr_data)
    );


    // dump layer match (declared early for backpressure gating)
    wire dump_layer_match;
    // ---------------- writeback_controller ----------------
    wire wb_ready;
    wire wb_busy;
    // Fine-grain residual safety (OPROJ): allow PE output only when the corresponding residual tile is loaded.
    reg [2:0] res_upto_cur;
    always @(*) begin
    case (wb_nblk_idx)
    3'd0: res_upto_cur = res_upto0;
    3'd1: res_upto_cur = res_upto1;
    3'd2: res_upto_cur = res_upto2;
    3'd3: res_upto_cur = res_upto3;
    3'd4: res_upto_cur = res_upto4;
    3'd5: res_upto_cur = res_upto5;
    default: res_upto_cur = 3'd0;
    endcase
    end

    wire res_tile_ok = res_ready_cur[wb_nblk_idx] && (wb_mblk_idx <= res_upto_cur);

    // Stream-dump pass: when dumping this layer AND we're on the final ktile (avoid partial-sum words)
    wire dump_stream_pass = dump_layer_match && (wb_ktile_idx == layer_final_ktile);
    wire dump_stream_ok;

    assign pe_out_col_ready = wb_ready && ((layer_id != L_O_PROJ) || res_tile_ok) && (!dump_stream_pass || dump_stream_ok);

    wire        wb_gout_rd_en;
    wire [10:0] wb_gout_rd_addr;

    wire wb_final_tile_pulse;
    wire [2:0] wb_final_mblk;
    wire [2:0] wb_final_nblk;

    // Apply CLS special handling only for Patch Embedding layer (layer_id==0)
    wire wb_cls_alt_apply;
    assign wb_cls_alt_apply = (layer_id == 4'd0);

    writeback_controller #(
        .M_BLK_NUM  (M_BLK_NUM),
        .OUT_STRIDE (OUT_STRIDE),
        .SHIFT_PART (8),
        .BIAS_LSHIFT(0),
        .SCALE_W    (16),
        .SCALE_OUT  (16'sd1),
        .SHIFT_OUT  (8)
    ) u_wb (
        .clk(clk),
        .nRst(nRst),

        .layer_id(layer_id),

        .layer_final_ktile(layer_final_ktile),
        .cls_alt_apply     (wb_cls_alt_apply),

        .ktile_idx(wb_ktile_idx),
        .nblk_idx(wb_nblk_idx),
        .mblk_idx(wb_mblk_idx),
        .col_in_blk(pe_out_col_idx),

        .final_tile_pulse(wb_final_tile_pulse),
        .final_nblk_idx  (wb_final_nblk),
        .final_mblk_idx  (wb_final_mblk),

        .pe_out_valid(pe_out_col_valid),
        .pe_out_ready(pe_out_col_ready),
        .pe_out_i32_flat(pe_out_col_data_flat),

        .gout_rd_en  (wb_gout_rd_en),
        .gout_rd_addr(wb_gout_rd_addr),
        .gout_rd_data(gout_rd_data),

        .gin_rd_en   (gin_rd_en),
        .gin_rd_addr (gin_rd_addr),
        .gin_rd_data (gin_rd_data),

        .bias_rd_en  (bias_rd_en),
        .bias_rd_addr(bias_rd_addr),
        .bias_rd_data(bias_rd_data),

        .quant_rd_en  (quant_rd_en),
        .quant_rd_addr(quant_rd_addr),
        .quant_rd_data(quant_rd_data),

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
        .score_wr_data (score_wr_data),

        .wb_ready(wb_ready),
        .wb_busy (wb_busy)
    );

    // ---------------- dump path: GOUT read mux (WB has priority) ----------------
    wire        dump_gout_rd_en;
    wire [10:0] dump_gout_rd_addr;

    assign gout_rd_en   = wb_gout_rd_en ? 1'b1 : dump_gout_rd_en;
    assign gout_rd_addr = wb_gout_rd_en ? wb_gout_rd_addr : dump_gout_rd_addr;

    // AXI_Master WLAST ? 0 ? 
    assign m_axi_wlast = 1'b0;

    // ---------------- write_controller (dump) ----------------
    wire dump_done_pulse;
    wire [2:0] wc_cur_mb, wc_cur_nb;

    // ---------------- write_controller (dump) ----------------
    // NOTE: For correctness, the tile's DDR destination descriptor is computed here
    //       and latched *per request* inside write_controller.
    // dump layer selection
    // - debug dump layers are controlled by DUMP_ENABLE
    // - final output (MLP FC2) writeback can be enabled even when DUMP_ENABLE=0
    wire debug_dump_layer_match = (layer_id_dump == L_PATCH) ||
                       ((RUN_QKV != 0) && (layer_id_dump == L_QKV_Q)) ||
                       ((RUN_QKV >= 2) && (layer_id_dump == L_QKV_V));

    wire final_out_layer_match = (layer_id_dump == L_MLP_FC2) || is_cls_dump;
    wire final_out_lastpass     = (wb_ktile_idx == layer_final_ktile);

    wire debug_dump_en = (DUMP_ENABLE != 0) && debug_dump_layer_match;
    wire final_out_en  = (FINAL_OUT_WRITE_ENABLE != 0) && final_out_layer_match && final_out_lastpass;
    // -------- Final output (MLP FC2) DDR write is done *after* compute completes --------
    // FC2 has 24 ktile accumulations, but the output matrix is 7(mblk) x 6(nblk) = 42 tiles.
    // To avoid stalling AXI reads during compute (and to avoid write_controller request overflow),
    // we run a post-dump pass at layer_end_pulse and stream all tiles to DDR sequentially.
    reg        post_fc2_dump_active;
    reg        post_fc2_dump_pending;
    reg [2:0]  post_fc2_mb;
    reg [2:0]  post_fc2_nb;
    reg        post_fc2_issue_pulse;

    wire is_fc2_final_out_layer = final_out_en; // (layer_id_dump == L_MLP_FC2) && FINAL_OUT_WRITE_ENABLE

    wire debug_dump_tile_start = debug_dump_en && wb_final_tile_pulse;
    // For FC2 final ktile, dump tiles immediately (overlapped) using stream source
    wire final_out_tile_start  = final_out_en && wb_final_tile_pulse;

    assign dump_layer_match = debug_dump_en || final_out_en;
    wire dump_tile_start  = debug_dump_tile_start || final_out_tile_start;

    wire [2:0] dump_req_mblk = wb_final_mblk;
    wire [2:0] dump_req_nblk = wb_final_nblk;

    // this tile uses stream source iff it is FC2 final output tile
    wire dump_tile_src_stream = dump_tile_start; // stream for all dumped tiles (no GOUT readback)

    wire [2:0] post_fc2_mb_last = M_BLK_NUM[2:0] - 3'd1;
    wire [2:0] post_fc2_nb_last = N_BLK_NUM[2:0] - 3'd1;
// destination mapping per layer
    reg  [1:0]              dump_dst_sel;
    reg  [BASE_AW-1:0]      dump_dst_off_word;
    reg  [9:0]              dump_dst_stride_words;

    always @(*) begin
        dump_dst_sel          = DST_SEL_OUT;
        dump_dst_off_word     = 0;
        dump_dst_stride_words = STRIDE_192;

        case (layer_id_dump)
            L_PATCH: begin
                // Patch Embedding output -> OUT region (residual read later)
                dump_dst_sel          = DST_SEL_OUT;
                dump_dst_off_word     = OFF_OUT_PATCH_OUT;
                dump_dst_stride_words = STRIDE_192;
            end

            L_QKV_Q: begin
                // Q projection output -> W region (Q_OUT scratch inside encoder block)
                dump_dst_sel          = DST_SEL_W;
                dump_dst_off_word     = OFF_W_Q_OUT + (enc_blk_idx * SIZE_W_ENC_BLK_WGT);
                dump_dst_stride_words = STRIDE_192;
            end


            L_QKV_V: begin
                // V projection output -> W region (V_OUT scratch inside encoder block)
                dump_dst_sel          = DST_SEL_W;
                dump_dst_off_word     = OFF_W_V_OUT + (enc_blk_idx * SIZE_W_ENC_BLK_WGT);
                dump_dst_stride_words = STRIDE_197;
            end
L_O_PROJ: begin
    dump_dst_sel          = DST_SEL_OUT;
    dump_dst_off_word     = OFF_OUT_O_OUT + (enc_blk_idx * SIZE_OUT_PATCH_OUT);
    dump_dst_stride_words = STRIDE_192;
end
L_MLP_FC2: begin
    dump_dst_sel          = DST_SEL_OUT;
    dump_dst_off_word     = OFF_OUT_O_OUT + (enc_blk_idx * SIZE_OUT_PATCH_OUT);  // bring-up: reuse OPROJ region
    dump_dst_stride_words = STRIDE_192;
end

            
                    L_CLS0: begin dump_dst_sel <= DST_SEL_OUT; dump_dst_off_word <= OFF_OUT_CLS0_OUT; dump_dst_stride_words <= STRIDE_192; end
                    L_CLS1: begin dump_dst_sel <= DST_SEL_OUT; dump_dst_off_word <= OFF_OUT_CLS1_OUT; dump_dst_stride_words <= STRIDE_192; end
                    L_CLS2: begin dump_dst_sel <= DST_SEL_OUT; dump_dst_off_word <= OFF_OUT_CLS2_OUT; dump_dst_stride_words <= STRIDE_192; end
                    L_CLS3: begin dump_dst_sel <= DST_SEL_OUT; dump_dst_off_word <= OFF_OUT_CLS3_OUT; dump_dst_stride_words <= STRIDE_192; end
                    L_CLS4: begin dump_dst_sel <= DST_SEL_OUT; dump_dst_off_word <= OFF_OUT_CLS4_OUT; dump_dst_stride_words <= STRIDE_192; end
                    L_CLS5: begin dump_dst_sel <= DST_SEL_OUT; dump_dst_off_word <= OFF_OUT_CLS5_OUT; dump_dst_stride_words <= STRIDE_64;  end

                    default: begin
                dump_dst_sel          = DST_SEL_OUT;
                dump_dst_off_word     = 0;
                dump_dst_stride_words = STRIDE_192;
            end
        endcase
    end

    wire [BASE_AW-1:0] dump_dst_base_word_sel =
        (dump_dst_sel == DST_SEL_IN)  ? base_in_word :
        (dump_dst_sel == DST_SEL_W)   ? base_w_word  :
                                        base_out_word;

    wire [BASE_AW-1:0] dump_tile_dst_base_word = dump_dst_base_word_sel + dump_dst_off_word;

    // compute per-tile word count (supports 197 stride last-nblk=5 words, etc.)
    wire [4:0] dump_nblk_num = f_nblk_num(dump_dst_stride_words);
    wire [2:0] dump_last_nblk_idx = dump_nblk_num[2:0] - 3'd1;
    wire       dump_is_last_nblk  = (dump_req_nblk == dump_last_nblk_idx);
    wire [5:0] dump_tile_words    = dump_is_last_nblk ? f_last_tile_cols(dump_dst_stride_words) : 6'd32;

    // Stream push into write_controller internal DATA FIFO (only FC2 final ktile)
    wire dump_stream_in_valid = gout_wr_valid && dump_stream_pass;
    wire [255:0] dump_stream_in_data = gout_wr_data;
    wire dump_stream_in_ready;

    // ---------------- write_controller instance ----------------
    write_controller #(
        .M_AXI_ADDR_WIDTH(M_AXI_ADDR_WIDTH),
        .DATA_W          (M_AXI_DATA_WIDTH),
        .ADDR_LSB        (ADDR_LSB),
        .M_BLK_NUM       (M_BLK_NUM),
        .GOUT_STRIDE     (OUT_STRIDE),
        .GOUT_AW         (11),
        .REQ_FIFO_HEADROOM  (16),
        .DATA_FIFO_HEADROOM (16)
    ) u_dump (
        .clk(clk),
        .nRst(nRst),

        .tile_start_pulse     (dump_tile_start),
        .tile_mblk_idx        (dump_req_mblk),
        .tile_nblk_idx        (dump_req_nblk),
        .tile_dst_base_word   (dump_tile_dst_base_word),
        .tile_dst_stride_words(dump_dst_stride_words),
        .tile_dst_words       (dump_tile_words),

        .tile_src_stream     (dump_tile_src_stream),
        .stream_in_valid     (dump_stream_in_valid),
        .stream_in_data      (dump_stream_in_data),
        .stream_in_ready     (dump_stream_in_ready),
        .stream_ok           (dump_stream_ok),

        .wb_gout_rd_en   (wb_gout_rd_en),

        .m_axi_write_done  (m_axi_write_done),
        .m_axi_write_init  (m_axi_write_init),
        .m_axi_awaddress   (m_axi_awaddress),
        .m_axi_write_length(m_axi_write_length),

        .S_WDATA  (m_axi_wdata),
        .S_WVALID (m_axi_wvalid),
        .S_WREADY (m_axi_wready),

        .gout_rd_en  (dump_gout_rd_en),
        .gout_rd_addr(dump_gout_rd_addr),
        .gout_rd_data(gout_rd_data),

        .dump_done_pulse(dump_done_pulse),

        .cur_mblk_idx_o(wc_cur_mb),
        .cur_nblk_idx_o(wc_cur_nb)
    );


    // ---------------- done generation ----------------
    localparam integer DUMP_TILES_PER_LAYER = (M_BLK_NUM * N_BLK_NUM);
    localparam integer DUMP_EXPECTED_TILES =
        (RUN_QKV == 0) ? (1*DUMP_TILES_PER_LAYER) :
        (RUN_QKV == 1) ? (2*DUMP_TILES_PER_LAYER) :
                         (3*DUMP_TILES_PER_LAYER);

    reg start_d1;
    wire start_pulse = start && !start_d1;

    reg [7:0] dump_done_cnt;
    reg       vit_done_latched;
    reg       final_out_last_tile_done; // asserted when LAST encoder-block FC2 last tile is written to DDR

    // --- per-layer wait for DDR dump completion (prevents early layer advance) ---
    reg [7:0] dump_done_cnt_layer;
    reg [7:0] dump_expected_layer;
    reg       wait_layer_dump;

    wire       layer_needs_dump         = dump_layer_match;
    wire is_cls_dump = ((layer_id_dump >= L_CLS0) && (layer_id_dump <= L_CLS5));
    wire [3:0] dump_mblk_num = (layer_id_dump == L_QKV_V) ? N_BLK_NUM[3:0] : (is_cls_dump ? 4'd1 : M_BLK_NUM[3:0]);
    wire [7:0] layer_expected_tiles_calc = dump_mblk_num * dump_nblk_num;

    assign layer_adv_grant = wait_layer_dump && (dump_done_cnt_layer >= dump_expected_layer) && !wb_busy;

    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            start_d1        <= 0;
            dump_done_cnt   <= 0;
            vit_done_latched<= 0;
            final_out_last_tile_done <= 0;

            dump_done_cnt_layer <= 0;
            dump_expected_layer <= 0;
            wait_layer_dump     <= 0;

            post_fc2_dump_active  <= 0;
            post_fc2_dump_pending <= 0;
            post_fc2_mb           <= 0;
            post_fc2_nb           <= 0;
            post_fc2_issue_pulse  <= 0;
        end else begin
            start_d1 <= start;

            post_fc2_issue_pulse <= 1'b0;
            if (start_pulse) begin
                dump_done_cnt    <= 0;
                vit_done_latched <= 0;
            final_out_last_tile_done <= 0;

                dump_done_cnt_layer <= 0;
                dump_expected_layer <= 0;
                wait_layer_dump     <= 0;

                post_fc2_dump_active  <= 0;
                post_fc2_dump_pending <= 0;
                post_fc2_mb           <= 0;
                post_fc2_nb           <= 0;
                post_fc2_issue_pulse  <= 0;
            end else begin
                if (dump_done_pulse) begin
                    // Latch final done when the LAST encoder block's FC2 last (mblk,nblk) tile write completes
                    if (final_out_en && (enc_blk_idx == (ENC_BLK_NUM-1)) &&
                        (wc_cur_mb == (M_BLK_NUM[2:0]-3'd1)) && (wc_cur_nb == (N_BLK_NUM[2:0]-3'd1))) begin
                        final_out_last_tile_done <= 1'b1;
                    end
                    dump_done_cnt <= dump_done_cnt + 8'd1;
                end

                // per-layer dump counter (reset on each layer start)
                if (layer_start_pulse) begin
                    dump_done_cnt_layer <= 0;
                end else if (dump_done_pulse) begin
                    dump_done_cnt_layer <= dump_done_cnt_layer + 8'd1;
                end

                // start waiting when vit_controller reports end-of-layer compute
                if (layer_end_pulse) begin
                    dump_expected_layer <= layer_needs_dump ? layer_expected_tiles_calc : 8'd0;
                    wait_layer_dump     <= 1'b1;
                end else if (layer_adv_grant) begin
                    wait_layer_dump     <= 1'b0;
                end

                // ---------------- Post-dump pass for final output (FC2) ----------------
                // Start after FC2 compute ends; wait WB pipeline to go idle, then dump all tiles.
                if (layer_end_pulse && is_fc2_final_out_layer) begin
                    post_fc2_dump_active  <= 1'b1;
                    post_fc2_dump_pending <= 1'b1;
                    post_fc2_mb           <= 0;
                    post_fc2_nb           <= 0;
                end else if (post_fc2_dump_active) begin
                    // issue next tile when pending and WB is idle
                    if (post_fc2_dump_pending) begin
                        if (!wb_busy) begin
                            post_fc2_issue_pulse  <= 1'b1; // 1-cycle kick to write_controller
                            post_fc2_dump_pending <= 1'b0;
                        end
                    end else begin
                        // wait for write_controller to finish the issued tile
                        if (dump_done_pulse) begin
                            if ((post_fc2_mb == post_fc2_mb_last) && (post_fc2_nb == post_fc2_nb_last)) begin
                                post_fc2_dump_active <= 1'b0;
                            end else begin
                                // advance (nblk major)
                                if (post_fc2_nb == post_fc2_nb_last) begin
                                    post_fc2_nb <= 0;
                                    post_fc2_mb <= post_fc2_mb + 3'd1;
                                end else begin
                                    post_fc2_nb <= post_fc2_nb + 3'd1;
                                end
                                post_fc2_dump_pending <= 1'b1;
                            end
                        end
                    end
                end


                if (vit_done) begin
                    vit_done_latched <= 1'b1;
                end
            end
        end
    end

    wire [7:0] dump_expected = DUMP_EXPECTED_TILES[7:0];
    wire dump_all_done = vit_done_latched; // vit_done already implies all per-layer dumps completed via layer_adv_grant handshake

    wire vit_done_pulse = vit_done && !vit_done_latched; // 1-cycle pulse at end of run
    assign done = vit_done_pulse;

endmodule

`default_nettype wire