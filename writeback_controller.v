`timescale 1ns/1ps
`default_nettype none

module writeback_controller #(
    parameter integer M_BLK_NUM   = 7,
    parameter integer OUT_STRIDE  = 197,
    parameter integer SHIFT_PART  = 8,
    parameter integer BIAS_LSHIFT = 0,
    parameter integer SCALE_W     = 16,
    parameter signed [SCALE_W-1:0] SCALE_OUT = 16'sd1,
    parameter integer SHIFT_OUT   = 8,

    parameter integer CLS_ALT_EN  = 1,
    parameter signed [SCALE_W-1:0] SCALE_CLS = 16'sd1,
    parameter integer SHIFT_CLS   = 0,

    // SCORE softmax i_exp/log_round parameter
    parameter integer SM_HW_SCALE = 4,

    // IndexSoftmaxShift parameters (must match LUT generation)
    parameter integer SM_LOG2_PREC = 4,
    parameter integer SM_LOG2_FRAC_LUT_SIZE = 128,
    parameter integer SM_QLOG_MAX = 13
)(


    input  wire clk,
    input  wire nRst,

    // NEW: layer final ktile (2b)
    input  wire [4:0] layer_final_ktile,
    input  wire       cls_alt_apply, // 1: apply CLS special handling (Patch Embedding only)
    input  wire [3:0] layer_id,

    // meta (pe_out_valid )
    input  wire [4:0] ktile_idx,
    input  wire [2:0] nblk_idx,
    input  wire [2:0] mblk_idx,
    input  wire [4:0] col_in_blk,

    // final-tile complete pulse + meta
    output reg          final_tile_pulse,
    output reg  [2:0]   final_nblk_idx,
    output reg  [2:0]   final_mblk_idx,

    input  wire             pe_out_valid,
    input  wire             pe_out_ready,
    input  wire [32*32-1:0] pe_out_i32_flat,

    // GOUT read (prev partial)
    output wire         gout_rd_en,
    output wire [10:0]  gout_rd_addr,
    input  wire [255:0] gout_rd_data,
    
    // Global IN read (FC2 residual add) - uses IN bank (layer_inbuf_sel)
    output wire         gin_rd_en,
    output wire [10:0]  gin_rd_addr,
    input  wire [255:0] gin_rd_data,

    // Bias read (final ktile )
    output wire         bias_rd_en,
    output wire [5:0]   bias_rd_addr,
    input  wire [255:0] bias_rd_data,


    // quant constants (async read LUTRAM)
    output wire        quant_rd_en,
    output wire [5:0]  quant_rd_addr,
    input  wire [255:0] quant_rd_data,
    // GOUT write
    output wire         gout_wr_valid,
    output wire [10:0]  gout_wr_addr,
    output wire [255:0] gout_wr_data,

    // SCOREBUF raw-score buffer (ping-pong) R/W for SCORE softmax
    output wire         score_rd_en,
    output wire         score_rd_bank,
    output wire [10:0]  score_rd_addr,
    input  wire [255:0] score_rd_data,

    output wire         score_wr_valid,
    output wire         score_wr_bank,
    output wire [10:0]  score_wr_addr,
    output wire [255:0] score_wr_data,

    output wire         wb_ready,
    output wire         wb_busy
);

    function [10:0] calc_word_addr_rowmajor;
        input [2:0] nblk;
        input [4:0] col;
        input [2:0] mblk;
        reg   [9:0] n_global;
        begin
            n_global = {nblk, 5'd0} + col; // 0..191
            calc_word_addr_rowmajor = (mblk * OUT_STRIDE) + n_global;
        end
    endfunction

    function signed [7:0] sat8;
        input signed [31:0] x;
        begin
            if (x > 32'sd127)       sat8 = 8'sd127;
            else if (x < -32'sd128) sat8 = -8'sd128;
            else                    sat8 = x[7:0];
        end
    endfunction

    // ------------------------------------------------------------
    // Banker's rounding right-shift for signed 64-bit values
    // - rounds to nearest, ties to even (matches torch.round / numpy.rint)
    // ------------------------------------------------------------
    function signed [31:0] round_shift_even_s64;
        input signed [63:0] x;
        input [5:0]         sh;
        reg   signed [63:0] q;
        reg   signed [63:0] rem;
        reg          [63:0] abs_rem;
        reg          [63:0] half;
        reg   signed [63:0] sign_adj;
        begin
            if (sh == 0) begin
                round_shift_even_s64 = x[31:0];
            end else begin
                q   = x >>> sh;
                rem = x - (q <<< sh);
                abs_rem = rem[63] ? (~rem + 64'd1) : rem;
                half    = 64'd1 <<< (sh - 1);
                sign_adj = x[63] ? -64'sd1 : 64'sd1;

                if (abs_rem > half) begin
                    q = q + sign_adj;
                end else if (abs_rem == half) begin
                    if (q[0]) q = q + sign_adj;
                end
                round_shift_even_s64 = q[31:0];
            end
        end
    endfunction






// --------------------------------------------------------------------
// SCORE softmax helpers (ilog/qlog4)
// - i_exp/log_round as in golden Python (integer-only approximation)
// --------------------------------------------------------------------
function [7:0] log_round_u32;
    input [31:0] x;
    integer b;
    reg [5:0] msb;
    reg [5:0] big;
    begin
        if (x == 0) begin
            log_round_u32 = 8'd0;
        end else begin
            msb = 0;
            for (b = 0; b < 32; b = b + 1) begin
                if (x[b]) msb = b[5:0];
            end
            if (msb == 0) big = 0;
            else          big = msb - 1;

            log_round_u32 = {2'd0, msb}; // <= 31
            if (x[big]) log_round_u32 = log_round_u32 + 1;
        end
    end
endfunction

function [31:0] i_exp_int_from_diff;
    input signed [8:0] diff9; // score - row_max (<=0)
    input        [3:0] sm_scale;
    reg signed [15:0] x;
    reg signed [15:0] x_ln2_s;
    reg [15:0]        x_ln2_u;
    reg [5:0]         q6;
    reg [15:0]        q_scaled16;
    reg signed [15:0] r_s;
    reg signed [31:0] z_s;
    reg [31:0]        exp_u;
    integer sh;
    begin
        x = {{7{diff9[8]}}, diff9}; // sign extend to 16
        // x_int_ln2 = -(x + x//2 - x//16)  (floor div for negative via >>>)
        x_ln2_s = x + (x >>> 1) - (x >>> 4);
        x_ln2_s = -x_ln2_s;

        if (x_ln2_s[15]) x_ln2_u = 0;
        else             x_ln2_u = x_ln2_s[15:0];

        // clamp to (2^sm_scale)*13
        if (x_ln2_u > (16'd13 << sm_scale)) x_ln2_u = (16'd13 << sm_scale);

        q6  = x_ln2_u >> sm_scale;

        // IMPORTANT: widen before shifting.
        // In plain Verilog, (q6 << sm_scale) keeps q6's width (6b) and truncates,
        // which corrupts the remainder r and inflates exp_sum (logsum mismatch).
        q_scaled16 = ({10'd0, q6} << sm_scale);
        r_s = -$signed({1'b0, x_ln2_u} - {1'b0, q_scaled16});

        // z = (r + sm_scale)*r + sm_scale
        z_s = ($signed(r_s) + $signed(sm_scale)) * $signed(r_s) + $signed(sm_scale);
        if (z_s[31]) z_s = 0; // clamp min=0

        // exp_int = floor( z * 2^(13 - q - 4) ) = z * 2^(9 - q)
        if (q6 <= 6'd9) begin
            sh    = 9 - q6;
            exp_u = z_s <<< sh;
        end else begin
            sh    = q6 - 9;
            exp_u = z_s >>> sh;
        end

        i_exp_int_from_diff = exp_u;
    end
endfunction

// ------------------------------------------------------------
// IndexSoftmaxShift helper: ilog2 floor (x>=1)
// ------------------------------------------------------------
function [5:0] ilog2_floor_u32;
    input [31:0] x;
    integer b;
    begin
        ilog2_floor_u32 = 0;
        for (b = 0; b < 32; b = b + 1) begin
            if (x[b]) begin
                ilog2_floor_u32 = b[5:0];
            end
        end
    end
endfunction


        localparam [3:0] L_PATCH = 4'd0;
localparam [3:0] L_QKV_V = 4'd2;
    localparam [3:0] L_SCORE = 4'd4;
    localparam [3:0] L_AV    = 4'd5;
    localparam [3:0] L_O_PROJ = 4'd6;
    localparam [3:0] L_MLP_FC1 = 4'd7;
localparam [3:0] L_MLP_FC2 = 4'd8;
    
localparam [3:0] L_CLS0   = 4'd9;
localparam [3:0] L_CLS1   = 4'd10;
localparam [3:0] L_CLS2   = 4'd11;
localparam [3:0] L_CLS3   = 4'd12;
localparam [3:0] L_CLS4   = 4'd13;
localparam [3:0] L_CLS5   = 4'd14;
wire mode_v = (layer_id == L_QKV_V);

    wire mode_score = (layer_id == L_SCORE);

    wire mode_av    = (layer_id == L_AV);
    wire mode_oproj = (layer_id == L_O_PROJ);
    wire mode_fc1  = (layer_id == L_MLP_FC1);
    wire mode_fc2  = (layer_id == L_MLP_FC2);


wire mode_cls = ((layer_id >= L_CLS0) && (layer_id <= L_CLS5));
// ------------------------------------------------------------
// Quant constants from quant_rd_data (256b)
// Bit layout (LSB..MSB) must match gen_memhex_quantbuf.py:
//   [15:0]   OUT_MUL   (s16)
//   [31:16]  OUT_OFF   (u16)
//   [36:32]  OUT_SH    (u5)
//   [52:37]  CLS_MUL   (s16)
//   [68:53]  CLS_OFF   (u16)
//   [73:69]  CLS_SH    (u5)
//   [77:74]  SM_SCALE  (u4)
//   [..]     ACC_SH[i] (u5 each) starting at bit 78
//   [208:193] RES_ALIGN_MUL   (s16, dyadic multiplier for residual align, shift_bits=15)
//   [212:209] RES_ALIGN_LSH   (u4, extra left shift before /2^15)
//   [228:213] RES_POST_MUL    (s16, dyadic multiplier for post-residual requant, shift_bits=15)
//   [232:229] RES_POST_LSH    (u4, extra left shift before /2^15)
//   [248:233] RES_POST_OFF    (u16, rounding offset for post-residual requant; recommend 16384)
// ------------------------------------------------------------
wire signed [15:0] q_out_mul = $signed(quant_rd_data[15:0]);
wire [15:0]        q_out_off_u16 = quant_rd_data[31:16];
wire [4:0]         q_out_sh  = quant_rd_data[36:32];

wire signed [15:0] q_cls_mul = $signed(quant_rd_data[52:37]);
wire [15:0]        q_cls_off_u16 = quant_rd_data[68:53];
wire [4:0]         q_cls_sh  = quant_rd_data[73:69];

wire [3:0]         sm_hw_scale_eff = quant_rd_data[77:74];
// Residual align/post-requant params for model_data_HW matching
// These fields are only used in OPROJ residual and FC2 final residual paths.
//  - Align: banker's rounding (torch.round) on dyadic ratio
//      aligned_i32 = round_even( (x_i8 * MUL) << LSH  / 2^15 )
//  - Post: half-up rounding (fixed-point multiply) with programmable offset
//      y_i8 = sat8( (((x_i32 * MUL) << LSH) + OFF) >>> 15 )
// Recommended: OFF = 1<<(15-1) = 16384
localparam integer RES_SHIFT_BITS = 15;

wire signed [15:0] q_res_align_mul    = $signed(quant_rd_data[208:193]);
wire [3:0]         q_res_align_divsh  =        quant_rd_data[212:209];
wire signed [15:0] q_res_post_mul     = $signed(quant_rd_data[228:213]);
wire [3:0]         q_res_post_divsh   =        quant_rd_data[232:229];
wire [15:0]        q_res_post_off_u16 =        quant_rd_data[248:233];
wire signed [47:0] q_res_post_off_s48 = $signed({32'd0, q_res_post_off_u16});

// default offset for shift_bits=15 (half-up)
localparam signed [47:0] RES_OFF_DYADIC_S48 = 48'sd16384;
wire signed [47:0] q_res_post_off_eff_s48 = (q_res_post_off_u16 == 16'd0) ? RES_OFF_DYADIC_S48 : q_res_post_off_s48;







// model_data_HW clamp: if mul is negative, treat as +32767 (matches _clamp_multiplier_modeldata)
wire signed [15:0] q_res_align_mul_eff = q_res_align_mul[15] ? 16'sd32767 : q_res_align_mul;
wire signed [15:0] q_res_post_mul_eff  = q_res_post_mul[15]  ? 16'sd32767 : q_res_post_mul;
// helper: extract 5b shift entry (0..22) from quant word.
function [4:0] f_acc_sh;
    input [4:0] idx;
    integer bi;
    begin
        if (idx >= 5'd23) begin
            f_acc_sh = 5'd0;
        end else begin
            bi = 78 + (idx * 5);
            f_acc_sh = quant_rd_data[bi +: 5];
        end
    end
endfunction

// Requant constants used for all non-CLS paths (bring-up):
wire signed [15:0] rq_mul = q_out_mul;
wire [4:0]         rq_sh  = q_out_sh;
wire [15:0]        rq_off_u16 = q_out_off_u16;
wire signed [31:0]  rq_off_s32 = $signed({16'd0, rq_off_u16});
wire signed [31:0]  cls_off_s32 = $signed({16'd0, q_cls_off_u16});
wire signed [47:0] rq_off_s48  = $signed({32'd0, rq_off_u16});
wire signed [47:0] cls_off_s48 = $signed({32'd0, q_cls_off_u16});
    // V-bias cache: 32 x int16 per channel-block (2 x 256b words)
    localparam [1:0] BIAS_IDLE  = 2'd0;
    localparam [1:0] BIAS_LOAD0 = 2'd1;
    localparam [1:0] BIAS_LOAD1 = 2'd2;
    reg  [1:0]   bias_load_state;
    reg  [2:0]   bias_target_blk;
    reg  [2:0]   bias_cached_blk;
    reg          bias_cache_valid;
    reg  [255:0] bias_word_lo;
    reg  [255:0] bias_word_hi;

    wire cur_is_final_ktile = (ktile_idx == layer_final_ktile);
    wire cur_is_final_eff = cur_is_final_ktile || mode_fc1;

    // Output word validity for edge blocks (197 = 6*32 + 5)
// - V proj: last token-block (mblk==6) has only 5 valid rows
// - SCORE:  last col-block  (nblk==6) has only 5 valid cols
wire out_word_valid = (mode_v) ? !((mblk_idx == 3'd6) && (col_in_blk > 5'd4)) :
                      (mode_score)        ? !((nblk_idx == 3'd6) && (col_in_blk > 5'd4)) :
                                          1'b1;

    // Backpressure:
    // - V final-ktile bias load requirement
    wire wb_ready_bias = !(mode_v && cur_is_final_ktile && pe_out_valid && out_word_valid &&
                           ((bias_load_state != BIAS_IDLE) || (!bias_cache_valid) || (bias_cached_blk != nblk_idx)));

    // - SCORE softmax context overflow protection:
    //   do not allow overwriting a SCOREBUF bank that still holds an older mblk context
    wire sm_score_bank_conflict = (mode_score && pe_out_valid && out_word_valid &&
                                   ((scorebuf_wr_bank_r == 1'b0 && sm_ctx_vld[0] && (sm_ctx_mblk[0] != mblk_idx)) ||
                                    (scorebuf_wr_bank_r == 1'b1 && sm_ctx_vld[1] && (sm_ctx_mblk[1] != mblk_idx))));

    assign wb_ready = wb_ready_bias && !sm_score_bank_conflict;

    // Handshake
    // - pe_out_valid is the raw column-stream valid from PE
    // - wb_ready applies backpressure
    wire accept     = pe_out_valid && wb_ready && pe_out_ready;   // (= fire)
    wire accept_eff = accept && out_word_valid;

    wire        core_gout_rd_en;
    wire [10:0] core_gout_rd_addr;
    assign core_gout_rd_en   = accept_eff && (ktile_idx != 5'd0) && (!mode_fc1);
    assign core_gout_rd_addr = calc_word_addr_rowmajor(mode_v ? mblk_idx : nblk_idx,
                                                       col_in_blk,
                                                       mode_v ? nblk_idx : mblk_idx);

    // FC2 residual add: read residual (int8) from IN bank on final ktile.
    // - memory_controller IN port is 1-cycle sync read (same as gout_rd).
    // - gin_rd_data is aligned with s0_* regs when s0_valid is asserted.
    assign gin_rd_en   = accept_eff && mode_fc2 && cur_is_final_ktile;
    assign gin_rd_addr = core_gout_rd_addr;

    // stage0 regs
    reg        s0_valid;
    // Core writeback pipeline valids (2-cycle) for timing closure
    reg        s1_valid_core;
    reg        s2_valid_core;

    // StageQ8 pipeline (1-cycle): register packed_q8 + meta for SCOREBUF write & softmax PASS1 timing
    reg        s1_valid_q8;
    reg [255:0] s1_packed_q8;
    reg [2:0]  s1_mb_q8;
    reg [2:0]  s1_nb_q8;
    reg [4:0]  s1_col_q8;
    reg [4:0]  s1_kt_q8;
    reg        s1_mode_score_q8;
    reg        s1_mode_fc1_q8;
    reg        s1_is_final_ktile_q8;


    // WB busy: prevent layer advance while PE still streaming or a write is in-flight (1-cycle pipe)
    // + hold busy across SCORE softmax post-processing (3-pass)
    wire sm_busy;
    assign wb_busy = pe_out_valid || s0_valid || s1_valid_q8 || s1_valid_core || s2_valid_core || sm_busy;
    reg [4:0]  s0_kt;
    reg [2:0]  s0_nb, s0_mb;
    reg [4:0]  s0_col;
    reg [10:0] s0_addr;
    reg [32*32-1:0] s0_cur_flat;

    // stage0 layer/meta regs (cuts layer_id fanout into datapath)
    reg [3:0]  s0_layer_id;
    reg [4:0]  s0_layer_final_ktile;
    reg        s0_cls_alt_apply;

    // stage0 layer decode (use s0_* only in datapath calculations)
    wire s0_mode_v     = (s0_layer_id == L_QKV_V);
    wire s0_mode_score = (s0_layer_id == L_SCORE);
    wire s0_mode_av    = (s0_layer_id == L_AV);
    wire s0_mode_oproj = (s0_layer_id == L_O_PROJ);
    wire s0_mode_fc1   = (s0_layer_id == L_MLP_FC1);
    wire s0_mode_fc2   = (s0_layer_id == L_MLP_FC2);
    wire s0_mode_cls   = ((s0_layer_id >= L_CLS0) && (s0_layer_id <= L_CLS5));

    // Bias read addr
    wire [5:0] bias_word_idx = s0_mode_fc1 ? {s0_kt, s0_col[4]} : (s0_mode_fc2 ? (6'd48 + {2'd0, s0_nb, s0_col[4]}) : {2'd0, s0_nb, s0_col[4]});
    wire [3:0] bias_lane_idx = s0_col[3:0];

    wire is_final_ktile = (s0_kt == s0_layer_final_ktile);
    wire is_final_eff = is_final_ktile || s0_mode_fc1;

    
    wire use_bias_q = (!s0_mode_v) && (!s0_mode_score) && (!s0_mode_av);
wire bias_rd_en_q   = (s0_valid && is_final_eff && use_bias_q);
wire [5:0] bias_rd_addr_q = bias_word_idx;

    wire       bias_rd_en_v   = (bias_load_state != BIAS_IDLE);
    wire [5:0] bias_rd_addr_v = {2'd0, bias_target_blk, (bias_load_state == BIAS_LOAD1)};

    assign bias_rd_en   = mode_v ? bias_rd_en_v : bias_rd_en_q;
    assign bias_rd_addr = mode_v ? bias_rd_addr_v : bias_rd_addr_q;
// Quant constants: address by s0_layer_id (0..15) to cut layer_id fanout into datapath
// NOTE: ram_1w1r_bias uses async read, so quant_rd_en is informational only.
assign quant_rd_en   = 1'b1;
assign quant_rd_addr = {2'd0, s0_layer_id};
    integer i;
    integer j;
    integer row_base;
    integer valid_lanes;
    reg [255:0] packed_q8;
    reg signed [31:0] cur32, prev32, sum32, sum32b;
    reg signed [7:0]  prev_q8;
    reg signed [15:0] bias16_col;
    reg signed [15:0] bias16_lane;
    reg signed [31:0] qtmp32;
    integer shift_prev_eff;
    integer shift_store_eff;
    reg signed [47:0] mul48;
    reg signed [63:0] mul64;
    reg signed [31:0] res_align32;

    wire is_cls_block = (s0_cls_alt_apply && is_final_ktile && (s0_mb == 3'd0));






    // Bias prefetch/cache for V projection: load 32 biases (2 words) per channel-block
    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            bias_load_state <= BIAS_IDLE;
            bias_target_blk <= 0;
            bias_cached_blk <= 0;
            bias_cache_valid <= 1'b0;
        end else if (!mode_v) begin
            // Only meaningful in V mode
            bias_load_state <= BIAS_IDLE;
            bias_cache_valid <= 1'b0;
        end else begin
            case (bias_load_state)
                BIAS_IDLE: begin
                    if (pe_out_valid && out_word_valid && cur_is_final_ktile &&
                        (!bias_cache_valid || (bias_cached_blk != nblk_idx))) begin
                        bias_target_blk <= nblk_idx;
                        bias_cache_valid <= 1'b0;
                        bias_load_state <= BIAS_LOAD0;
                    end
                end
                BIAS_LOAD0: begin
                    bias_word_lo <= bias_rd_data;
                    bias_load_state <= BIAS_LOAD1;
                end
                BIAS_LOAD1: begin
                    bias_word_hi <= bias_rd_data;
                    bias_cached_blk <= bias_target_blk;
                    bias_cache_valid <= 1'b1;
                    bias_load_state <= BIAS_IDLE;
                end
                default: begin
                    bias_load_state <= BIAS_IDLE;
                end
            endcase
        end
    end

    always @(*) begin
        packed_q8  = 0;
        bias16_col = 16'sd0;

        // Q-mode: 1 bias per output channel (col)
        if (use_bias_q && is_final_eff) begin
            bias16_col = $signed(bias_rd_data[bias_lane_idx*16 +: 16]);
        end

// effective accumulation shift for partial-sum storage/restore
// - dynamic only for PATCH and FC2
shift_prev_eff  = SHIFT_PART;
shift_store_eff = SHIFT_PART;
if (s0_layer_id == L_PATCH) begin
    shift_prev_eff  = f_acc_sh(s0_kt - 5'd1);
    shift_store_eff = f_acc_sh(s0_kt);
end else if (s0_mode_fc2) begin
    shift_prev_eff  = f_acc_sh(s0_kt - 5'd1);
    shift_store_eff = f_acc_sh(s0_kt);
end
        for (i = 0; i < 32; i = i + 1) begin
            cur32 = $signed(s0_cur_flat[i*32 +: 32]);

            prev_q8 = $signed(gout_rd_data[i*8 +: 8]);
            if (s0_mode_fc1 || (s0_kt == 5'd0)) begin
                prev32 = 32'sd0;
            end else if (CLS_ALT_EN && is_cls_block && (i == 0)) begin
                prev32 = 32'sd0;
            end else begin
                prev32 = ($signed(prev_q8) <<< shift_prev_eff);
            end

            sum32 = prev32 + cur32;

            if (is_final_eff) begin
                // V-mode: 1 bias per lane (channel). Q-mode: 1 bias per column.
                if (s0_mode_v) begin
                    if (i < 16) bias16_lane = $signed(bias_word_lo[i*16 +: 16]);
                    else        bias16_lane = $signed(bias_word_hi[(i-16)*16 +: 16]);
                end else begin
                    bias16_lane = use_bias_q ? bias16_col : 16'sd0;
                end

                sum32b = sum32 + ($signed(bias16_lane) <<< BIAS_LSHIFT);

                if (CLS_ALT_EN && is_cls_block && (i == 0)) begin
// CLS special requant (Patch Embedding only)
mul48  = $signed(sum32) * $signed(q_cls_mul);
qtmp32 = $signed(($signed(mul48) + cls_off_s48) >>> q_cls_sh);
packed_q8[i*8 +: 8] = sat8(qtmp32);
                end else begin
                    if (s0_mode_av) begin
                        // AV final quantization must match Python golden:
                        //   out_i8 = sat8( (av_prewb_i32 * SCALE_OUT) >>> (SHIFT_OUT + 16) )
                        mul48  = $signed(sum32b) * $signed(SCALE_OUT);
                        qtmp32 = $signed(($signed(mul48)) >>> (SHIFT_OUT + 16));
                    end else begin
                        mul48  = $signed(sum32b) * $signed(rq_mul);
                        qtmp32 = $signed(($signed(mul48) + rq_off_s48) >>> rq_sh);
                    end
                    packed_q8[i*8 +: 8] = sat8(qtmp32);
                end
            
                // Residual add (OPROJ/FC2) is pipelined in stage1/stage2 (see below)
end else begin
                qtmp32 = $signed(sum32 >>> shift_store_eff);
                packed_q8[i*8 +: 8] = sat8(qtmp32);
            end
        end

        // AV padding mask: rows >= OUT_STRIDE are padded tokens and must be written as 0
        // (Python golden forces these lanes to 0). This affects the tail of the last mblk only.
        if (s0_mode_av) begin
            row_base = (s0_mb << 5);
            if (row_base >= OUT_STRIDE) begin
                packed_q8 = 0;
            end else if ((row_base + 31) >= OUT_STRIDE) begin
                valid_lanes = OUT_STRIDE - row_base; // 0..32
                for (j = 0; j < 32; j = j + 1) begin
                    if (j >= valid_lanes) begin
                        packed_q8[j*8 +: 8] = 8'd0;
                    end
                end 
            end
        end
        // CLS output mask for golden-compare:
        // - Classifier operates on CLS token only (row0). Force lanes [31:1] to 0.
        // - CLS5 produces 64 logits but only first 40 are valid (1000 classes total). Force cols [63:40] to 0.
        if (mode_cls) begin
            for (j = 1; j < 32; j = j + 1) begin
                packed_q8[j*8 +: 8] = 8'd0;
            end
            if (s0_layer_id == L_CLS5) begin
                if ({s0_nb, s0_col} >= 8'd40) begin
                    packed_q8[7:0] = 8'd0;
                end
            end
        end


    end

    // ------------------------------------------------------------
    // StageQ8 regs: capture packed_q8 + meta (cuts BRAM->DSP/LUT->BRAM critical paths)
    // ------------------------------------------------------------
    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            s1_valid_q8         <= 0;
            s1_packed_q8        <= 0;
            s1_mb_q8            <= 0;
            s1_nb_q8            <= 0;
            s1_col_q8           <= 0;
            s1_kt_q8            <= 0;
            s1_mode_score_q8    <= 0;
            s1_mode_fc1_q8      <= 0;
            s1_is_final_ktile_q8 <= 0;
        end else begin
            s1_valid_q8 <= s0_valid;
            if (s0_valid) begin
                s1_packed_q8         <= packed_q8;
                s1_mb_q8             <= s0_mb;
                s1_nb_q8             <= s0_nb;
                s1_col_q8            <= s0_col;
                s1_kt_q8             <= s0_kt;
                s1_mode_score_q8     <= s0_mode_score;
                s1_mode_fc1_q8       <= s0_mode_fc1;
                s1_is_final_ktile_q8 <= is_final_ktile;
            end
        end
    end


    wire         core_gout_wr_valid;
    wire [10:0]  core_gout_wr_addr;
    wire [255:0] core_gout_wr_data;

    // ------------------------------------------------------------
    // Core GOUT writeback pipeline (2-cycle) for timing closure
    //  - Stage1: register base quant output (packed_q8) + residual data + constants
    //  - Stage2: residual-align + add (int32) for OPROJ/FC2 final
    //  - Stage3 (comb): post-requant + sat8, or pass-through base_q8
    // ------------------------------------------------------------
    wire core_en_s0;
    assign core_en_s0 = s0_valid && !s0_mode_score && !s0_mode_fc1;
    wire do_res_oproj_s0;
    wire do_res_fc2_s0;
    assign do_res_oproj_s0 = core_en_s0 && s0_mode_oproj && is_final_ktile;
    assign do_res_fc2_s0   = core_en_s0 && s0_mode_fc2   && is_final_ktile;

    // stage1 regs
    reg [10:0]  s1_addr;
    reg [255:0] s1_base_q8;
    reg         s1_do_res_oproj;
    reg         s1_do_res_fc2;
    reg [255:0] s1_score_res_data;
    reg [255:0] s1_gin_res_data;
    reg signed [15:0] s1_q_res_align_mul_eff;
    reg [3:0]         s1_q_res_align_divsh;
    reg signed [15:0] s1_q_res_post_mul_eff;
    reg [3:0]         s1_q_res_post_divsh;
    reg signed [47:0] s1_q_res_post_off_eff_s48;

    // stage2 regs
    reg [10:0]  s2_addr;
    reg [255:0] s2_base_q8;
    reg         s2_do_res;
    reg [32*32-1:0] s2_sum32_flat;
    reg signed [15:0] s2_q_res_post_mul_eff;
    reg [3:0]         s2_q_res_post_divsh;
    reg signed [47:0] s2_q_res_post_off_eff_s48;

    // stage2 comb (residual-align + add)
    reg [32*32-1:0] sum32_flat_next;
    reg signed [63:0] mul64_p1;
    reg signed [31:0] res_align32_p1;
    reg signed [31:0] sum32_p1;
    reg signed [7:0]  res_i8_p1;
    reg signed [7:0]  base_i8_p1;
    integer k1;
    always @(*) begin
        sum32_flat_next = 0;
        mul64_p1        = 0;
        res_align32_p1   = 0;
        sum32_p1         = 0;
        res_i8_p1        = 0;
        base_i8_p1       = 0;

        if (s1_do_res_oproj || s1_do_res_fc2) begin
            for (k1 = 0; k1 < 32; k1 = k1 + 1) begin
                base_i8_p1 = $signed(s1_base_q8[k1*8 +: 8]);
                if (s1_do_res_oproj) begin
                    res_i8_p1 = $signed(s1_score_res_data[k1*8 +: 8]);
                end else begin
                    res_i8_p1 = $signed(s1_gin_res_data[k1*8 +: 8]);
                end

                // residual align (dyadic, banker): aligned_i32 = round_even( (x * mul) << lsh / 2^15 )
                mul64_p1      = $signed({{56{res_i8_p1[7]}}, res_i8_p1}) * $signed(s1_q_res_align_mul_eff);
                mul64_p1      = $signed(mul64_p1 <<< s1_q_res_align_divsh);
                res_align32_p1 = round_shift_even_s64(mul64_p1, 6'd15);

                // add in int32 domain (base is int8 sign-extended)
                sum32_p1 = $signed({{24{base_i8_p1[7]}}, base_i8_p1}) + $signed(res_align32_p1);
                sum32_flat_next[k1*32 +: 32] = sum32_p1;
            end
        end
    end

    // stage1/stage2 regs update
    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            s1_valid_core <= 0;
            s1_do_res_oproj <= 0;
            s1_do_res_fc2 <= 0;

            s2_valid_core <= 0;
            s2_do_res <= 0;
        end else begin
            // stage1 capture
            s1_valid_core <= core_en_s0;
            if (core_en_s0) begin
                s1_addr <= s0_addr;
                s1_base_q8 <= packed_q8;
                s1_do_res_oproj <= do_res_oproj_s0;
                s1_do_res_fc2   <= do_res_fc2_s0;
                s1_score_res_data <= score_rd_data;
                s1_gin_res_data   <= gin_rd_data;
                s1_q_res_align_mul_eff <= q_res_align_mul_eff;
                s1_q_res_align_divsh   <= q_res_align_divsh;
                s1_q_res_post_mul_eff  <= q_res_post_mul_eff;
                s1_q_res_post_divsh    <= q_res_post_divsh;
                s1_q_res_post_off_eff_s48 <= q_res_post_off_eff_s48;
            end else begin
                s1_do_res_oproj <= 0;
                s1_do_res_fc2   <= 0;
            end

            // stage2 capture
            s2_valid_core <= s1_valid_core;
            if (s1_valid_core) begin
                s2_addr <= s1_addr;
                s2_base_q8 <= s1_base_q8;
                s2_do_res  <= (s1_do_res_oproj || s1_do_res_fc2);
                s2_sum32_flat <= sum32_flat_next;
                s2_q_res_post_mul_eff <= s1_q_res_post_mul_eff;
                s2_q_res_post_divsh   <= s1_q_res_post_divsh;
                s2_q_res_post_off_eff_s48 <= s1_q_res_post_off_eff_s48;
            end else begin
                s2_do_res <= 0;
                s2_sum32_flat <= 0;
            end
        end
    end

    // stage3 comb (post-requant + sat8)
    reg [255:0] packed_q8_core;
    reg signed [63:0] mul64_p2;
    reg signed [31:0] qtmp32_p2;
    reg signed [31:0] sum32_p2;
    integer k2;
    always @(*) begin
        packed_q8_core = s2_base_q8;
        mul64_p2  = 0;
        qtmp32_p2 = 0;
        sum32_p2  = 0;

        if (s2_valid_core && s2_do_res) begin
            for (k2 = 0; k2 < 32; k2 = k2 + 1) begin
                sum32_p2 = $signed(s2_sum32_flat[k2*32 +: 32]);
                // post requant (half-up): ((x * mul << lsh) + off) >>> 15
                mul64_p2  = $signed(sum32_p2) * $signed(s2_q_res_post_mul_eff);
                mul64_p2  = $signed(mul64_p2 <<< s2_q_res_post_divsh);
                qtmp32_p2 = $signed(($signed(mul64_p2) + $signed({16'd0, s2_q_res_post_off_eff_s48})) >>> 15);
                packed_q8_core[k2*8 +: 8] = sat8(qtmp32_p2);
            end
        end
    end

    assign core_gout_wr_valid = s2_valid_core;
    assign core_gout_wr_addr  = s2_addr;
    assign core_gout_wr_data  = packed_q8_core;

    // ============================================================
    // SCORE Softmax (row-wise) - 3 pass in writeback_controller
    // - Only active when layer_id == L_SCORE (mode_score)
    // - Output format: uint8 where [3:0]=qlog (ilog/qlog4), overwrite in-place
    
    // ============================================================
    // SCORE Softmax (row-wise) with SCOREBUF ping-pong
    //  - raw score(int8) is written to SCOREBUF (not to GOUT)
    //  - PASS2 reads SCOREBUF -> computes inv per row
    //  - PASS3 reads SCOREBUF -> writes softmax(u8) to GOUT
    //  - PASS2+PASS3 run per-mblk as soon as that mblk is complete
    //
    // Assumption (current design): SCORE uses a single ktile (ktile_idx==0),
    // so we don't need partial-sum accumulation in SCOREBUF.
    // ============================================================

    localparam signed [7:0] SM_MAX_INIT = -8'sd128;
    
    // per-bank (SCOREBUF ping-pong) softmax context:
    // - Because SCOREBUF is banked ping-pong, at most 2 row-blocks can be in-flight.
    // - We keep row-wise softmax state only for the two banks (instead of for all mblks).
    reg signed [7:0] sm_max_b0    [0:31];
    reg signed [7:0] sm_max_b1    [0:31];
    // log2(exp_sum) fixed-point (QSM_LOG2_PREC) per lane
    reg [15:0]       sm_log2sum_fp_b0 [0:31];
    reg [15:0]       sm_log2sum_fp_b1 [0:31];

    // IndexSoftmaxShift ROMs (generated by gen_memhex_updated.py)
    // - exp LUT: diff(0..255) -> exp_value_u8
    // - log2e LUT: exp_value_u8(0..255) -> log2(exp) in QSM_LOG2_PREC
    // - log2frac LUT: normalized sum (128..128+SM_LOG2_FRAC_LUT_SIZE-1) -> frac in QSM_LOG2_PREC
    reg [7:0]  sm_exp_lut_u8   [0:255];
    reg [15:0] sm_log2e_fp    [0:255];
    reg [15:0] sm_log2frac_fp [0:SM_LOG2_FRAC_LUT_SIZE-1];

    integer sm_init_i;
    initial begin
        // Default 0 to avoid X-propagation even if memh missing
        for (sm_init_i = 0; sm_init_i < 256; sm_init_i = sm_init_i + 1) begin
            sm_exp_lut_u8[sm_init_i] = 8'd0;
            sm_log2e_fp[sm_init_i]  = 16'd0;
        end
        for (sm_init_i = 0; sm_init_i < SM_LOG2_FRAC_LUT_SIZE; sm_init_i = sm_init_i + 1) begin
            sm_log2frac_fp[sm_init_i] = 16'd0;
        end
        // Read LUTs
        $readmemh("sm_exp_lut_u8.mem",   sm_exp_lut_u8);
        $readmemh("sm_log2e_fp.mem",    sm_log2e_fp);
        $readmemh("sm_log2frac_fp.mem", sm_log2frac_fp);
    end
    
    // per-bank bookkeeping
    reg        sm_ctx_vld   [0:1];
    reg        sm_ctx_ready [0:1];
    reg [2:0]  sm_ctx_mblk  [0:1];
    
    // per-mblk completion bookkeeping (PASS3 done for this mblk)
    reg sm_done [0:M_BLK_NUM-1];
    
    // SCOREBUF write bank ping-pong
    reg scorebuf_wr_bank_r;
    reg prev_mode_score;

    // SCOREBUF write from core stream (raw score)
    wire        scorebuf_wr_valid_w;
    wire [7:0]  s0_n_global8;
    wire [10:0] s0_n_global;

    // FC1 output column-block -> SCOREBUF (bank0, addr = mblk*32 + col)
    wire [7:0]  fc1_score_addr8;
    wire [10:0] fc1_score_addr;
    wire        fc1_score_wr_valid_w;

    assign scorebuf_wr_valid_w   = s1_valid_q8 && s1_mode_score_q8;
    assign s0_n_global8          = {s0_nb, 5'd0} + s0_col;
    assign s0_n_global           = {3'd0, s0_n_global8};

    assign fc1_score_wr_valid_w  = s1_valid_q8 && s1_mode_fc1_q8;
    assign fc1_score_addr8       = {s1_mb_q8, 5'd0} + s1_col_q8;
    assign fc1_score_addr        = {3'd0, fc1_score_addr8};

    // FC1 ReLU (after quantization): negative -> 0
    reg [255:0] packed_q8_fc1_relu;
    integer gi;
    always @(*) begin
        packed_q8_fc1_relu = s1_packed_q8;
        if (s1_mode_fc1_q8) begin
            for (gi = 0; gi < 32; gi = gi + 1) begin
                if (s1_packed_q8[gi*8+7]) packed_q8_fc1_relu[gi*8 +: 8] = 8'd0;
            end
        end
    end

    assign score_wr_valid = scorebuf_wr_valid_w || fc1_score_wr_valid_w;
    assign score_wr_bank  = scorebuf_wr_valid_w ? scorebuf_wr_bank_r : 1'b0;
    assign score_wr_addr  = scorebuf_wr_valid_w ? {3'd0, ({s1_nb_q8, 5'd0} + s1_col_q8)} : fc1_score_addr;
    assign score_wr_data  = scorebuf_wr_valid_w ? s1_packed_q8       : packed_q8_fc1_relu;
// last VALID word of a 197-wide row-block (nblk=6, col=4) @ final ktile
    wire score_last_valid_word;
    assign score_last_valid_word =
        scorebuf_wr_valid_w && s1_is_final_ktile_q8 && (s1_nb_q8 == 3'd6) && (s1_col_q8 == 5'd4);

// --------------------------------------------------------------------
// PASS1 softmax row-max (sm_max_b0/b1) next-state update
// - This is isolated from the main softmax FSM to avoid a shared, high-fanout
//   clock-enable path into sm_max_* regs (which was the WNS hot-spot).
// --------------------------------------------------------------------
wire score_entry_w;
assign score_entry_w = (!prev_mode_score && mode_score);

reg signed [7:0] sm_max_b0_next [0:31];
reg signed [7:0] sm_max_b1_next [0:31];

integer km;

always @(*) begin
    // default: hold
    for (km = 0; km < 32; km = km + 1) begin
        sm_max_b0_next[km] = sm_max_b0[km];
        sm_max_b1_next[km] = sm_max_b1[km];
    end

    // treat SCORE entry as "ctx invalid" for this cycle (safe even if first word overlaps)
    if (score_entry_w) begin
        for (km = 0; km < 32; km = km + 1) begin
            sm_max_b0_next[km] = SM_MAX_INIT;
            sm_max_b1_next[km] = SM_MAX_INIT;
        end
    end

    // PASS1 update on each accepted SCORE word
    if (scorebuf_wr_valid_w) begin
        if (scorebuf_wr_bank_r == 1'b0) begin
            if (!sm_ctx_vld[0] || score_entry_w) begin
                // init from first word
                for (km = 0; km < 32; km = km + 1) begin
                    if ((s1_mb_q8 != 3'd6) || (km < 5)) begin
                        sm_max_b0_next[km] = $signed(s1_packed_q8[km*8 +: 8]);
                    end else begin
                        sm_max_b0_next[km] = SM_MAX_INIT;
                    end
                end
            end else begin
                // update max
                for (km = 0; km < 32; km = km + 1) begin
                    if ((s1_mb_q8 != 3'd6) || (km < 5)) begin
                        if ($signed(s1_packed_q8[km*8 +: 8]) > sm_max_b0[km]) begin
                            sm_max_b0_next[km] = $signed(s1_packed_q8[km*8 +: 8]);
                        end
                    end
                end
            end
        end else begin
            if (!sm_ctx_vld[1] || score_entry_w) begin
                // init from first word
                for (km = 0; km < 32; km = km + 1) begin
                    if ((s1_mb_q8 != 3'd6) || (km < 5)) begin
                        sm_max_b1_next[km] = $signed(s1_packed_q8[km*8 +: 8]);
                    end else begin
                        sm_max_b1_next[km] = SM_MAX_INIT;
                    end
                end
            end else begin
                // update max
                for (km = 0; km < 32; km = km + 1) begin
                    if ((s1_mb_q8 != 3'd6) || (km < 5)) begin
                        if ($signed(s1_packed_q8[km*8 +: 8]) > sm_max_b1[km]) begin
                            sm_max_b1_next[km] = $signed(s1_packed_q8[km*8 +: 8]);
                        end
                    end
                end
            end
        end
    end
end

always @(posedge clk) begin
    if (!nRst) begin
        for (km = 0; km < 32; km = km + 1) begin
            sm_max_b0[km] <= SM_MAX_INIT;
            sm_max_b1[km] <= SM_MAX_INIT;
        end
    end else begin
        for (km = 0; km < 32; km = km + 1) begin
            sm_max_b0[km] <= sm_max_b0_next[km];
            sm_max_b1[km] <= sm_max_b1_next[km];
        end
    end
end


    // ------------------------------------------------------------
    // Softmax PASS2/PASS3 engine (one mblk at a time)
    // ------------------------------------------------------------
    localparam [1:0] SM_IDLE    = 2'd0;
    localparam [1:0] SM_PASS2   = 2'd1;
    localparam [1:0] SM_PASS3   = 2'd2;
    localparam [1:0] SM_P2FINAL = 2'd3;

    reg [1:0] sm_state;
    reg       sm_issuing;

    reg [2:0] sm_mblk;
    reg       sm_bank;  // SCOREBUF bank being processed by softmax engine
    reg [7:0] sm_n_issue; // 0..196

    // sum_work for PASS2 (Q0.16 accumulate)
    reg [31:0] sm_sum_work [0:31];

    // delayed read meta (SCOREBUF is 1-cycle synchronous read)
    reg       sm_rd_en_dly;
    reg       sm_rd_is_p3_dly;
    reg [2:0] sm_rd_mblk_dly;
    reg       sm_rd_bank_dly;
    reg [7:0] sm_rd_n_dly;

    // PASS2 finalize context (1-cycle stage before PASS3)
    reg [2:0] sm_p2final_mblk;
    reg       sm_p2final_bank;

    // pick next pending softmax job (bank context):
    // - choose among banks that have completed PASS1 (ctx_ready=1)
    // - if both banks ready, process lower mblk first (to preserve row order)
    reg       sm_pick_valid;
    reg       sm_pick_bank;
    reg [2:0] sm_pick_mblk;
    integer j_done;
    integer j_seq;

    always @(*) begin
        sm_pick_valid = 0;
        sm_pick_bank  = 0;
        sm_pick_mblk  = 0;

        if (sm_ctx_vld[0] && sm_ctx_ready[0] && sm_ctx_vld[1] && sm_ctx_ready[1]) begin
            if (sm_ctx_mblk[0] <= sm_ctx_mblk[1]) begin
                sm_pick_valid = 1;
                sm_pick_bank  = 1'b0;
                sm_pick_mblk  = sm_ctx_mblk[0];
            end else begin
                sm_pick_valid = 1;
                sm_pick_bank  = 1'b1;
                sm_pick_mblk  = sm_ctx_mblk[1];
            end
        end else if (sm_ctx_vld[0] && sm_ctx_ready[0]) begin
            sm_pick_valid = 1;
            sm_pick_bank  = 1'b0;
            sm_pick_mblk  = sm_ctx_mblk[0];
        end else if (sm_ctx_vld[1] && sm_ctx_ready[1]) begin
            sm_pick_valid = 1;
            sm_pick_bank  = 1'b1;
            sm_pick_mblk  = sm_ctx_mblk[1];
        end
    end

    // SCOREBUF read request
    wire       sm_sbuf_rd_en_now;
    wire       sm_sbuf_rd_is_p3_now;
    wire [2:0] sm_sbuf_rd_mblk_now;
    wire [7:0] sm_sbuf_rd_n_now;
    wire       sm_sbuf_rd_bank_now;

    assign sm_sbuf_rd_en_now    = mode_score && sm_issuing;
    assign sm_sbuf_rd_is_p3_now = (sm_state == SM_PASS3);
    assign sm_sbuf_rd_mblk_now  = sm_mblk;
    assign sm_sbuf_rd_n_now     = sm_n_issue;
    assign sm_sbuf_rd_bank_now  = sm_bank;

// SCOREBUF read mux:
// - SCORE softmax engine uses SCOREBUF during mode_score
// - OPROJ residual add reads SCOREBUF once per accepted output word (1-cycle sync read)
wire        score_rd_en_sm   = sm_sbuf_rd_en_now;
wire        score_rd_bank_sm = sm_sbuf_rd_bank_now;
wire [10:0] score_rd_addr_sm = {3'd0, sm_sbuf_rd_n_now};

// OPROJ: residual is prefetched into SCOREBUF by read_controller:
//   bank = nblk_idx[0] ping-pong (even/odd nblk)
//   addr = (mblk_idx*32) + col_in_blk  (0..223)
wire        score_rd_en_op   = accept_eff && mode_oproj;
wire        score_rd_bank_op = nblk_idx[0];
wire [7:0]  score_rd_addr_op8 = {mblk_idx, 5'd0} + {3'd0, col_in_blk};
wire [10:0] score_rd_addr_op = {3'd0, score_rd_addr_op8};

assign score_rd_en   = mode_score ? score_rd_en_sm   : (mode_oproj ? score_rd_en_op   : 1'b0);
assign score_rd_bank = mode_score ? score_rd_bank_sm : (mode_oproj ? score_rd_bank_op : 1'b0);
assign score_rd_addr = mode_score ? score_rd_addr_sm : (mode_oproj ? score_rd_addr_op : 11'd0);

    // Softmax write regs (to GOUT via mux)
    reg         sm_wr_valid_r;
    reg [10:0]  sm_wr_addr_r;
    reg [255:0] sm_wr_data_r;

    wire        sm_gout_wr_valid;
    wire [10:0] sm_gout_wr_addr;
    wire [255:0] sm_gout_wr_data;

    assign sm_gout_wr_valid = sm_wr_valid_r;
    assign sm_gout_wr_addr  = sm_wr_addr_r;
    assign sm_gout_wr_data  = sm_wr_data_r;

    // sm_busy: SCORE mode + any pending or in-flight
    reg sm_all_done;
    always @(*) begin
        sm_all_done = 1;
        for (j_done = 0; j_done < M_BLK_NUM; j_done = j_done + 1) begin
            if (!sm_done[j_done]) sm_all_done = 0;
        end
    end

    assign sm_busy = mode_score && (!sm_all_done || (sm_state != SM_IDLE) || sm_rd_en_dly || sm_wr_valid_r);

    // ------------------------------------------------------------
    // Softmax datapath (PASS2 consume / PASS3 consume)
    // ------------------------------------------------------------
    integer k;
    reg signed [7:0]  v_s8;
    reg signed [8:0]  diff9;
    reg [7:0]         diff_u8;

    reg [7:0]         exp_u8;
    reg [31:0]        sum_next;
    reg [5:0]         log2_sum_int;
    reg [5:0]         sh_r, sh_l;
    reg [31:0]        sum_norm;
    reg [15:0]        log2sum_fp;
    reg [15:0]        log2exp_fp;
    reg signed [17:0] shift_raw_s;
    reg [7:0]         qlog_u8;

    // ------------------------------------------------------------
    // Sequential control
    // ------------------------------------------------------------
    always @(posedge clk) begin
        if (!nRst) begin
            scorebuf_wr_bank_r <= 0;
            prev_mode_score <= 0;

            sm_state   <= SM_IDLE;
            sm_issuing <= 0;
            sm_mblk    <= 0;
            sm_bank    <= 0;
            sm_n_issue <= 0;

            sm_rd_en_dly     <= 0;
            sm_rd_is_p3_dly  <= 0;
            sm_rd_mblk_dly   <= 0;
            sm_rd_bank_dly  <= 0;
            sm_rd_n_dly      <= 0;
            sm_p2final_mblk <= 0;
            sm_p2final_bank <= 0;

            sm_wr_valid_r <= 0;
            sm_wr_addr_r  <= 0;
            sm_wr_data_r  <= 0;

            // softmax bookkeeping reset
            sm_ctx_vld[0]   <= 0;
            sm_ctx_ready[0] <= 0;
            sm_ctx_mblk[0]  <= 0;
            sm_ctx_vld[1]   <= 0;
            sm_ctx_ready[1] <= 0;
            sm_ctx_mblk[1]  <= 0;

            for (j_seq = 0; j_seq < M_BLK_NUM; j_seq = j_seq + 1) begin
                sm_done[j_seq] <= 0;
            end
            for (j_seq = 0; j_seq < 32; j_seq = j_seq + 1) begin
                sm_log2sum_fp_b0[j_seq] <= 0;
                sm_log2sum_fp_b1[j_seq] <= 0;
            end
            for (k = 0; k < 32; k = k + 1) begin
                sm_sum_work[k] <= 0;
            end
        end else begin
            // default: no softmax write unless PASS3 consume fires
            sm_wr_valid_r <= 0;
            prev_mode_score <= mode_score;

            // ----------------------------------------------------
            // SCORE mode entry: clear state
            // ----------------------------------------------------
            if (!prev_mode_score && mode_score) begin
                scorebuf_wr_bank_r <= 0;

                sm_state   <= SM_IDLE;
                sm_issuing <= 0;
                sm_mblk    <= 0;
                sm_bank    <= 0;
                sm_n_issue <= 0;

                sm_rd_en_dly     <= 0;
                sm_rd_is_p3_dly  <= 0;
                sm_rd_mblk_dly   <= 0;
                sm_rd_bank_dly   <= 0;
                sm_rd_n_dly      <= 0;
            sm_p2final_mblk <= 0;
            sm_p2final_bank <= 0;

                sm_ctx_vld[0]   <= 0;
                sm_ctx_ready[0] <= 0;
                sm_ctx_mblk[0]  <= 0;
                sm_ctx_vld[1]   <= 0;
                sm_ctx_ready[1] <= 0;
                sm_ctx_mblk[1]  <= 0;

                for (j_seq = 0; j_seq < M_BLK_NUM; j_seq = j_seq + 1) begin
                    sm_done[j_seq] <= 0;
                end
                for (j_seq = 0; j_seq < 32; j_seq = j_seq + 1) begin
                    sm_log2sum_fp_b0[j_seq] <= 0;
                    sm_log2sum_fp_b1[j_seq] <= 0;
                end
                for (k = 0; k < 32; k = k + 1) begin
                    sm_sum_work[k] <= 0;
                end
            end

            // ----------------------------------------------------
            // PASS1 (max): update per accepted VALID score word
            // - NOTE: sm_max_b0/b1 are updated in a dedicated next-state block (avoid shared high-fanout CE).
            //   sm_log2sum_fp_* are still updated in this sequential block (PASS1 init + PASS2 finalize).
            // ----------------------------------------------------
            if (scorebuf_wr_valid_w) begin
                if (scorebuf_wr_bank_r == 1'b0) begin
                    // bank0 context
                    if (!sm_ctx_vld[0]) begin
                        sm_ctx_vld[0]   <= 1'b1;
                        sm_ctx_ready[0] <= 1'b0;
                        sm_ctx_mblk[0]  <= s1_mb_q8;
                        for (k = 0; k < 32; k = k + 1) begin
                            sm_log2sum_fp_b0[k] <= 0;
                        end
                    end
                end else begin
                    // bank1 context
                    if (!sm_ctx_vld[1]) begin
                        sm_ctx_vld[1]   <= 1'b1;
                        sm_ctx_ready[1] <= 1'b0;
                        sm_ctx_mblk[1]  <= s1_mb_q8;
                        for (k = 0; k < 32; k = k + 1) begin
                            sm_log2sum_fp_b1[k] <= 0;
                        end
                    end
                end
            end


            // row-block done: mark this bank context as READY for PASS2 and toggle bank
            if (score_last_valid_word) begin
                if (scorebuf_wr_bank_r == 1'b0) begin
                    sm_ctx_ready[0] <= 1'b1;
                    sm_ctx_mblk[0]  <= s1_mb_q8;
                end else begin
                    sm_ctx_ready[1] <= 1'b1;
                    sm_ctx_mblk[1]  <= s1_mb_q8;
                end
                scorebuf_wr_bank_r <= ~scorebuf_wr_bank_r;
            end


            // ----------------------------------------------------
            // SCOREBUF read meta pipeline (1-cycle)
            // ----------------------------------------------------
            sm_rd_en_dly     <= sm_sbuf_rd_en_now;
            sm_rd_is_p3_dly  <= sm_sbuf_rd_is_p3_now;
            sm_rd_mblk_dly   <= sm_sbuf_rd_mblk_now;
            sm_rd_bank_dly   <= sm_sbuf_rd_bank_now;
            sm_rd_n_dly      <= sm_sbuf_rd_n_now;

            // ----------------------------------------------------
// PASS2 consume: accumulate exp_sum (IndexSoftmaxShift)
//   - NOTE: log2sum_fp finalize is moved to SM_P2FINAL (1-cycle later)
// ----------------------------------------------------
if (sm_rd_en_dly && !sm_rd_is_p3_dly) begin
    for (k = 0; k < 32; k = k + 1) begin
        if ((sm_rd_mblk_dly != 3'd6) || (k < 5)) begin
            v_s8  = $signed(score_rd_data[k*8 +: 8]);

            // diff = row_max - score (0..255)
            if (sm_rd_bank_dly == 1'b0) begin
                diff9 = $signed({sm_max_b0[k][7], sm_max_b0[k]}) - $signed({v_s8[7], v_s8});
            end else begin
                diff9 = $signed({sm_max_b1[k][7], sm_max_b1[k]}) - $signed({v_s8[7], v_s8});
            end

            if (diff9 < 0) begin
                diff_u8 = 8'd0;
            end else if (diff9 > 9'sd255) begin
                diff_u8 = 8'd255;
            end else begin
                diff_u8 = diff9[7:0];
            end

            exp_u8   = sm_exp_lut_u8[diff_u8];
            sum_next = sm_sum_work[k] + {24'd0, exp_u8};
            sm_sum_work[k] <= sum_next;
        end
    end

    if (sm_rd_n_dly == 8'd196) begin
        // PASS2 done -> compute log2sum_fp in SM_P2FINAL, then start PASS3
        sm_state        <= SM_P2FINAL;
        sm_p2final_mblk <= sm_rd_mblk_dly;
        sm_p2final_bank <= sm_rd_bank_dly;
    end
end

// ----------------------------------------------------
// SM_P2FINAL: compute log2(exp_sum) fixed-point (QSM_LOG2_PREC)
//   - uses sm_sum_work[] registers (breaks timing from SCOREBUF read)
// ----------------------------------------------------
if (sm_state == SM_P2FINAL) begin
    for (k = 0; k < 32; k = k + 1) begin
        if ((sm_p2final_mblk != 3'd6) || (k < 5)) begin
            sum_norm = sm_sum_work[k];
            if (sum_norm == 32'd0) begin
                sum_norm = 32'd1;
            end

            log2_sum_int = ilog2_floor_u32(sum_norm);

            if (log2_sum_int > 6'd7) begin
                sh_r = log2_sum_int - 6'd7;
            end else begin
                sh_r = 6'd0;
            end
            if (log2_sum_int < 6'd7) begin
                sh_l = 6'd7 - log2_sum_int;
            end else begin
                sh_l = 6'd0;
            end

            // normalize into [128 .. 128+SM_LOG2_FRAC_LUT_SIZE-1]
            sum_norm = (sum_norm >> sh_r);
            sum_norm = (sum_norm << sh_l);

            if (sum_norm < 32'd128) begin
                sum_norm = 32'd128;
            end else if (sum_norm > (32'd128 + SM_LOG2_FRAC_LUT_SIZE - 1)) begin
                sum_norm = (32'd128 + SM_LOG2_FRAC_LUT_SIZE - 1);
            end

            log2sum_fp = (log2_sum_int << SM_LOG2_PREC) + sm_log2frac_fp[sum_norm - 32'd128];

            if (sm_p2final_bank == 1'b0) begin
                sm_log2sum_fp_b0[k] <= log2sum_fp;
            end else begin
                sm_log2sum_fp_b1[k] <= log2sum_fp;
            end
        end
    end

    // start PASS3 (issue reads from the same mblk/bank)
    sm_state   <= SM_PASS3;
    sm_issuing <= 1;
    sm_n_issue <= 0;
end

// PASS3 consume: write softmax qlog[3:0] (stored as uint8) to GOUT
// ----------------------------------------------------
if (sm_rd_en_dly && sm_rd_is_p3_dly) begin
    sm_wr_valid_r <= 1;
    sm_wr_addr_r  <= (sm_rd_mblk_dly * OUT_STRIDE) + {3'd0, sm_rd_n_dly};

    // build 32-lane u8 packed output: {4'b0, qlog[3:0]}
    for (k = 0; k < 32; k = k + 1) begin
        if ((sm_rd_mblk_dly != 3'd6) || (k < 5)) begin
            v_s8  = $signed(score_rd_data[k*8 +: 8]);

            // diff = row_max - score (0..255)
            if (sm_rd_bank_dly == 1'b0) begin
                diff9     = $signed({sm_max_b0[k][7], sm_max_b0[k]}) - $signed({v_s8[7], v_s8});
                log2sum_fp = sm_log2sum_fp_b0[k];
            end else begin
                diff9     = $signed({sm_max_b1[k][7], sm_max_b1[k]}) - $signed({v_s8[7], v_s8});
                log2sum_fp = sm_log2sum_fp_b1[k];
            end

            if (diff9 < 0) begin
                diff_u8 = 8'd0;
            end else if (diff9 > 9'sd255) begin
                diff_u8 = 8'd255;
            end else begin
                diff_u8 = diff9[7:0];
            end

            exp_u8 = sm_exp_lut_u8[diff_u8];

            // log2(exp): clamp exp>=1 before lookup
            if (exp_u8 == 8'd0) begin
                log2exp_fp = sm_log2e_fp[8'd1];
            end else begin
                log2exp_fp = sm_log2e_fp[exp_u8];
            end

            // shift_amount_raw = round((log2sum_fp - log2exp_fp) / 2^SM_LOG2_PREC)
            shift_raw_s = $signed({1'b0, log2sum_fp}) - $signed({1'b0, log2exp_fp});
            shift_raw_s = shift_raw_s + $signed(18'd1 << (SM_LOG2_PREC - 1));
            shift_raw_s = shift_raw_s >>> SM_LOG2_PREC;

            if (shift_raw_s < 0) begin
                qlog_u8 = 8'd0;
            end else if (shift_raw_s > $signed(SM_QLOG_MAX)) begin
                qlog_u8 = SM_QLOG_MAX;
            end else begin
                qlog_u8 = shift_raw_s[7:0];
            end

            sm_wr_data_r[k*8 +: 8] <= {4'd0, qlog_u8[3:0]};
        end else begin
            sm_wr_data_r[k*8 +: 8] <= 8'd0;
        end
    end

    if (sm_rd_n_dly == 8'd196) begin
        sm_done[sm_rd_mblk_dly] <= 1;
        // free bank context
        if (sm_rd_bank_dly == 1'b0) begin
            sm_ctx_vld[0]   <= 1'b0;
            sm_ctx_ready[0] <= 1'b0;
            sm_ctx_mblk[0]  <= 0;
        end else begin
            sm_ctx_vld[1]   <= 1'b0;
            sm_ctx_ready[1] <= 1'b0;
            sm_ctx_mblk[1]  <= 0;
        end
        sm_state   <= SM_IDLE;
        sm_issuing <= 0;
        sm_n_issue <= 0;
    end
end

// ----------------------------------------------------
// PASS2/PASS3 issue progression + IDLE->PASS2 start
            // ----------------------------------------------------
            if (mode_score) begin
                if (sm_state == SM_IDLE) begin
                    if (sm_pick_valid) begin
                        sm_state   <= SM_PASS2;
                        sm_issuing <= 1;
                        sm_mblk    <= sm_pick_mblk;
                        sm_bank    <= sm_pick_bank;
                        if (sm_pick_bank == 1'b0) begin
                            sm_ctx_ready[0] <= 1'b0;
                        end else begin
                            sm_ctx_ready[1] <= 1'b0;
                        end
                        sm_n_issue <= 0;
                        for (k = 0; k < 32; k = k + 1) begin
                            sm_sum_work[k] <= 0;
                        end
                    end
                end else begin
                    // issuing reads in PASS2 or PASS3
                    if (sm_issuing) begin
                        if (sm_n_issue == 8'd196) begin
                            sm_issuing <= 0; // stop issuing; wait last consume to advance/finish
                        end else begin
                            sm_n_issue <= sm_n_issue + 1;
                        end
                    end
                end
            end else begin
                // not SCORE: keep softmax engine idle
                sm_state   <= SM_IDLE;
                sm_issuing <= 0;
                sm_mblk    <= 0;
                sm_bank    <= 0;
                sm_n_issue <= 0;
            end
        end
    end

// ------------------------------------------------------------
    // GOUT read/write port mux (core has priority)
    // ------------------------------------------------------------
    assign gout_rd_en   = core_gout_rd_en;
    assign gout_rd_addr = core_gout_rd_addr;

    assign gout_wr_valid = core_gout_wr_valid | sm_gout_wr_valid;
    assign gout_wr_addr  = core_gout_wr_valid ? core_gout_wr_addr : sm_gout_wr_addr;
    assign gout_wr_data  = core_gout_wr_valid ? core_gout_wr_data : sm_gout_wr_data;

    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            s0_valid    <= 0;
            s0_kt       <= 0;
            s0_nb       <= 0;
            s0_mb       <= 0;
            s0_col      <= 0;
            s0_addr     <= 0;

            s0_layer_id <= 0;
            s0_layer_final_ktile <= 0;
            s0_cls_alt_apply <= 0;
            final_tile_pulse <= 0;
            final_nblk_idx   <= 0;
            final_mblk_idx   <= 0;
        end else begin
            final_tile_pulse <= 0;

            s0_valid <= accept_eff;
            if (accept_eff) begin
                s0_kt       <= ktile_idx;
                s0_nb       <= nblk_idx;
                s0_mb       <= mblk_idx;
                s0_col      <= col_in_blk;
                s0_addr     <= calc_word_addr_rowmajor(mode_v ? mblk_idx : nblk_idx, col_in_blk, mode_v ? nblk_idx : mblk_idx);
                s0_layer_id <= layer_id;
                s0_layer_final_ktile <= layer_final_ktile;
                s0_cls_alt_apply <= cls_alt_apply;
                s0_cur_flat <= pe_out_i32_flat;
            end

            // End-of-tile (stream) detection:
            // - IMPORTANT: tile/loop advance must follow the PE's full 32-beat column stream (accept).
            //   Even if some beats are 'invalid' (out_word_valid=0) in the last partial block,
            //   we still must DRAIN those beats to avoid meta(nblk/mblk) advancing mid-stream.
            if (accept && cur_is_final_eff && (col_in_blk == 5'd31)) begin
                final_tile_pulse <= 1'b1;

                // For V dump we treat: mblk = channel_block (0..5), nblk = token_block (0..6)
                if (mode_v) begin
                    final_mblk_idx <= nblk_idx; // channel block
                    final_nblk_idx <= mblk_idx; // token block
                end else begin
                    final_nblk_idx <= nblk_idx;
                    final_mblk_idx <= mblk_idx;
                end
            end
        end
    end

endmodule

`default_nettype wire
