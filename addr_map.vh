`ifndef ADDR_MAP_VH
`define ADDR_MAP_VH
// ============================================================================
// addr_map.vh  (12-encoder-block layout)
// - DDR layout constants in 256-bit WORD INDEX units (word = 32 bytes)
// - Base addresses (BASE_*_WORD) are provided externally (controller_top / TB)
//
// Policy:
// - Patch weights appear once.
// - Encoder weights are stored per-block: block0 .. block11.
// - Q_OUT / V_OUT are stored per-encoder-block (block0..block11) for debug/dump.
// - OUT region is scratch by default (will be overwritten per block unless TB allocates per-block dump).
// ============================================================================

/* ---------- Common tiling ---------- */
localparam  integer ENC_BLK_NUM        = 12;

localparam  integer M_BLK_NUM_PATCH_Q  = 7;   // for 197 rows -> 7 m-blocks
localparam  integer M_BLK_NUM_WGT_192  = 6;   // for 192 rows -> 6 m-blocks

localparam  integer STRIDE_192 = 192;
localparam  integer STRIDE_197 = 197;
localparam  integer STRIDE_769 = 769;
localparam  integer STRIDE_64  = 64;

/* ---------- IN region (BASE_IN_WORD + OFF_*) ---------- */
// Patch-Embedding input is preloaded: 7 blk * 769 words
localparam integer OFF_IN_PATCH_INPUT  = 0;
localparam integer SIZE_IN_PATCH_INPUT = (M_BLK_NUM_PATCH_Q * STRIDE_769); // 7*769 = 5383

// Attention scores (head1/head2) are appended after patch input
localparam integer OFF_IN_ATT_H1       = (OFF_IN_PATCH_INPUT + SIZE_IN_PATCH_INPUT);          // 5383
localparam integer SIZE_IN_ATT_H1      = (M_BLK_NUM_PATCH_Q * STRIDE_197);                     // 7*197 = 1379
localparam integer OFF_IN_ATT_H2       = (OFF_IN_ATT_H1 + SIZE_IN_ATT_H1);                     // 6762
localparam integer SIZE_IN_ATT_H2      = (M_BLK_NUM_PATCH_Q * STRIDE_197);                     // 1379

/* ---------- W region (BASE_W_WORD + OFF_*) ---------- */
// Patch-Embedding weights (global, once): 6 blk * 769 words
localparam integer OFF_W_PATCH_WGT     = 0;
localparam integer SIZE_W_PATCH_WGT    = (M_BLK_NUM_WGT_192 * STRIDE_769);                     // 6*769 = 4614

// -------- Encoder weights per-block (block0..block11) --------
// Q/V/K/O weights: each 6 blk * 192 words
localparam integer SIZE_W_Q_WGT        = (M_BLK_NUM_WGT_192 * STRIDE_192);                     // 1152
localparam integer SIZE_W_V_WGT        = (M_BLK_NUM_WGT_192 * STRIDE_192);                     // 1152
localparam integer SIZE_W_K_WGT        = (M_BLK_NUM_WGT_192 * STRIDE_192);                     // 1152
localparam integer SIZE_W_O_WGT        = (M_BLK_NUM_WGT_192 * STRIDE_192);                     // 1152

// MLP weights: FC1/FC2 each 24 tiles * 192 words (K_TOTAL=768 -> 24*32)
localparam integer MLP_TILE_NUM        = 24;
localparam integer SIZE_W_FC1_WGT      = (MLP_TILE_NUM * STRIDE_192);                          // 24*192 = 4608
localparam integer SIZE_W_FC2_WGT      = (MLP_TILE_NUM * STRIDE_192);                          // 24*192 = 4608

// One encoder block weight footprint
// Layout per encoder block (matches gen_memhex.py):
//   Q_WGT -> V_WGT -> K_WGT -> Q_OUT(scratch) -> V_OUT(scratch) -> O_WGT -> FC1_WGT -> FC2_WGT
localparam integer SIZE_W_Q_OUT        = (M_BLK_NUM_PATCH_Q * STRIDE_192);                     // 7*192 = 1344
localparam integer SIZE_W_V_OUT        = (M_BLK_NUM_WGT_192 * STRIDE_197);                     // 6*197 = 1182
localparam integer SIZE_W_ENC_BLK_WGT  = (SIZE_W_Q_WGT + SIZE_W_V_WGT + SIZE_W_K_WGT +
                                         SIZE_W_Q_OUT + SIZE_W_V_OUT +
                                         SIZE_W_O_WGT + SIZE_W_FC1_WGT + SIZE_W_FC2_WGT);      // 16350

// Absolute offsets for block0 weights (block b base = OFF_W_ENC0 + b*SIZE_W_ENC_BLK_WGT)
localparam integer OFF_W_ENC0          = (OFF_W_PATCH_WGT + SIZE_W_PATCH_WGT);                 // 4614

localparam integer OFF_W_Q_WGT         = (OFF_W_ENC0 + 0);
localparam integer OFF_W_V_WGT         = (OFF_W_Q_WGT + SIZE_W_Q_WGT);
localparam integer OFF_W_K_WGT         = (OFF_W_V_WGT + SIZE_W_V_WGT);
// Q/V outputs are stored inside each encoder block footprint
localparam integer OFF_W_Q_OUT         = (OFF_W_K_WGT + SIZE_W_K_WGT);
localparam integer OFF_W_V_OUT         = (OFF_W_Q_OUT + SIZE_W_Q_OUT);
// OPROJ/MLP weights follow after Q_OUT/V_OUT scratch
localparam integer OFF_W_O_WGT         = (OFF_W_V_OUT + SIZE_W_V_OUT);
localparam integer OFF_W_FC1_WGT       = (OFF_W_O_WGT + SIZE_W_O_WGT);
localparam integer OFF_W_FC2_WGT       = (OFF_W_FC1_WGT + SIZE_W_FC1_WGT);

// End of all encoder blocks (weights + Q/V scratch)
localparam integer OFF_W_ENC_ALL_END   = (OFF_W_ENC0 + (ENC_BLK_NUM * SIZE_W_ENC_BLK_WGT));
// ---------- Classifier head weights (1000 classes, grouped) ----------
// Groups: cls0..cls4 each produce 192 logits, cls5 produces 64 logits (pad to 1024; last 24 are unused).
localparam integer SIZE_W_CLS_G192_WGT = (M_BLK_NUM_WGT_192 * STRIDE_192);                     // 6*192 = 1152
localparam integer SIZE_W_CLS_G64_WGT  = (M_BLK_NUM_WGT_192 * STRIDE_64);                      // 6*64  = 384

localparam integer OFF_W_CLS0_WGT      = OFF_W_ENC_ALL_END;
localparam integer OFF_W_CLS1_WGT      = (OFF_W_CLS0_WGT + SIZE_W_CLS_G192_WGT);
localparam integer OFF_W_CLS2_WGT      = (OFF_W_CLS1_WGT + SIZE_W_CLS_G192_WGT);
localparam integer OFF_W_CLS3_WGT      = (OFF_W_CLS2_WGT + SIZE_W_CLS_G192_WGT);
localparam integer OFF_W_CLS4_WGT      = (OFF_W_CLS3_WGT + SIZE_W_CLS_G192_WGT);
localparam integer OFF_W_CLS5_WGT      = (OFF_W_CLS4_WGT + SIZE_W_CLS_G192_WGT);

localparam integer OFF_W_CLS_ALL_END   = (OFF_W_CLS5_WGT + SIZE_W_CLS_G64_WGT);
localparam integer OFF_W_END_ALL       = OFF_W_CLS_ALL_END;
/* ---------- OUT region (BASE_OUT_WORD + OFF_*) ---------- */
// Patch output (residual reuse): 7 blk * 192 words
localparam integer OFF_OUT_PATCH_OUT   = 0;
localparam integer SIZE_OUT_PATCH_OUT  = (M_BLK_NUM_PATCH_Q * STRIDE_192);                     // 7*192 = 1344

// Output projection output (option B / debug scratch)
localparam integer OFF_OUT_O_OUT       = (OFF_OUT_PATCH_OUT + SIZE_OUT_PATCH_OUT);

// ENC block final outputs (FC2 post-residual): base_out_word + OFF_OUT_O_OUT + enc_blk_idx*SIZE_OUT_PATCH_OUT (per-block)
localparam integer SIZE_OUT_O_OUT      = (M_BLK_NUM_PATCH_Q * STRIDE_192);                     // 7*192 = 1344

// ---------- Classifier head outputs (DDR dump destination) ----------
localparam integer OFF_OUT_ENC_ALL_END = (OFF_OUT_O_OUT + (ENC_BLK_NUM * SIZE_OUT_O_OUT));
localparam integer OFF_OUT_CLS0_OUT    = OFF_OUT_ENC_ALL_END;
localparam integer OFF_OUT_CLS1_OUT    = (OFF_OUT_CLS0_OUT + STRIDE_192);
localparam integer OFF_OUT_CLS2_OUT    = (OFF_OUT_CLS1_OUT + STRIDE_192);
localparam integer OFF_OUT_CLS3_OUT    = (OFF_OUT_CLS2_OUT + STRIDE_192);
localparam integer OFF_OUT_CLS4_OUT    = (OFF_OUT_CLS3_OUT + STRIDE_192);
localparam integer OFF_OUT_CLS5_OUT    = (OFF_OUT_CLS4_OUT + STRIDE_192);
localparam integer OFF_OUT_CLS_ALL_END = (OFF_OUT_CLS5_OUT + STRIDE_64);

/* ---------- DDR dump destination selector ---------- */
localparam [1:0] DST_SEL_IN  = 2'd0;
localparam [1:0] DST_SEL_W   = 2'd1;
localparam [1:0] DST_SEL_OUT = 2'd2;

// ceil(stride_words / 32) -> number of n-blocks
function [4:0] f_nblk_num;
    input [9:0] stride_words;
    reg [9:0] tmp;
    begin
        tmp = stride_words + 10'd31;
        f_nblk_num = tmp[9:5];
    end
endfunction

function [5:0] f_last_tile_cols;
    input [9:0] stride_words;
    reg [4:0] rem;
    begin
        rem = stride_words[4:0];
        if (rem == 5'd0) f_last_tile_cols = 6'd32;
        else             f_last_tile_cols = {1'b0, rem};
    end
endfunction

`endif // ADDR_MAP_VH
