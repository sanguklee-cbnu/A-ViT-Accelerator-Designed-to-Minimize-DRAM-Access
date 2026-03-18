`timescale 1ns/1ps
`default_nettype none

module read_controller #(
    parameter integer M_AXI_DATA_WIDTH = 256,
    parameter integer M_AXI_ADDR_WIDTH = 32,
    parameter integer ADDR_LSB = $clog2(M_AXI_DATA_WIDTH/8),

    parameter integer M_TOTAL   = 197,
    parameter integer N_TOTAL   = 192,

    parameter integer M_BLK_NUM = 7,
    parameter integer N_BLK_NUM = 6,
    parameter integer MAX_KTILE = 197
)(
    input  wire clk,
    input  wire nRst,

    // from vit_controller
    input  wire       layer_active,
    input  wire       layer_start_pulse,   // 1-cycle
    input  wire [4:0] ktile_idx_cur,

    input  wire [3:0] layer_id,
    input  wire [4:0] layer_final_ktile,
    input  wire       layer_inbuf_sel,
    input  wire [1:0] layer_head_idx,


    input  wire       layer_wgt_phase,
    input  wire [6:0] mblk_release_pulse,  // patch?????? ???(???? ktile overwrite)
    input  wire [1:0] wgt_slot_release_pulse,


        // next-layer W0 prefetch (from vit_controller)
        input  wire        nl_wgt0_prefetch_pulse,
        input  wire [3:0]  nl_wgt0_layer_id,
        input  wire [4:0]  nl_wgt0_ktile,
        input  wire [2:0]  nl_wgt0_nblk,
        input  wire        nl_wgt0_bank,
        input  wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] nl_wgt0_base_w_word,

    // per-layer base addresses (word index)
    input  wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_in_word,
    input  wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_w_word,
    input  wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_b_word,
    input  wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_out_word,

    input  wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_q_word,
    // AXI read interface
    input  wire                        m_axi_read_done,
    output reg                         m_axi_read_init,     // 1-cycle pulse
    output reg  [M_AXI_ADDR_WIDTH-1:0] m_axi_araddress,
    output reg  [16:0]                 m_axi_read_length,

    // ready outputs to vit_controller
    output reg                         bias_ready,
    output reg  quant_ready,
    output reg  [6:0]                  in_ready_cur,
    output reg  [5:0]                  w_ready_cur,
    output reg  [5:0]  res_ready_cur,

    output reg  [2:0] res_upto0,
    output reg  [2:0] res_upto1,
    output reg  [2:0] res_upto2,
    output reg  [2:0] res_upto3,
    output reg  [2:0] res_upto4,
    output reg  [2:0] res_upto5,
    // next-layer prefetch status (to vit_controller)
    output wire                        nl_pf_valid,
    output wire [3:0]                  nl_pf_layer,
    output wire [4:0]                  nl_pf_ktile,
    output wire [2:0]                  nl_pf_nblk,
    output wire                        nl_pf_bank,

    // AXI R-channel tap
    input  wire                        axi_rvalid,
    input  wire [M_AXI_DATA_WIDTH-1:0] axi_rdata,
    input  wire                        axi_rlast,
    input  wire                        axi_rready,

    // DDR -> SRAM write port
    output reg                         mem_wr_valid,
    output reg  [2:0]                  mem_wr_kind,   // 1:IN 2:WGT 3:BIAS 4:SCOREBUF(residual)
    output reg                         mem_wr_bank,
    output reg  [10:0]                 mem_wr_addr,
    output reg  [M_AXI_DATA_WIDTH-1:0] mem_wr_data
);

    // layer IDs (vit_controller?? ????)
    localparam [3:0] L_PATCH = 4'd0;

localparam [3:0] L_SCORE = 4'd4;
    localparam [3:0] L_AV    = 4'd5;
        localparam [3:0] L_O_PROJ = 4'd6;
    localparam [3:0] L_MLP_FC1 = 4'd7;
    localparam [3:0] L_MLP_FC2 = 4'd8;
// kind
    localparam [2:0] LD_NONE = 3'd0;
    localparam [2:0] LD_IN   = 3'd1;
    localparam [2:0] LD_WGT  = 3'd2;
    localparam [2:0] LD_BIAS = 3'd3;

        localparam [2:0] LD_SCORE= 3'd4;
        localparam [2:0] LD_QUANT= 3'd5;
// FSM
    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_CHOOSE = 3'd1;
    localparam [2:0] S_WAIT   = 3'd2;

    reg [2:0] fsm;

    // latched bases
    reg [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_in_l, base_w_l, base_b_l, base_out_l, base_q_l;

    // Use "effective" bases on the cycle of layer_start_pulse to avoid 1-cycle stale base_*_l
    // (layer_start_pulse latches base_*_l with nonblocking, but S_CHOOSE may issue AR in same cycle)
    wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_in_eff = layer_start_pulse ? base_in_word : base_in_l;
    wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_w_eff  = layer_start_pulse ? base_w_word  : base_w_l;
    wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_b_eff  = layer_start_pulse ? base_b_word  : base_b_l;
    wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_out_eff= layer_start_pulse ? base_out_word: base_out_l;
    wire [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_q_eff  = layer_start_pulse ? base_q_word  : base_q_l;
    // Avoid 1-cycle stale w_ready_cur / fc2_wgt_ptr on the layer_start_pulse cycle (nonblocking update)
    wire [5:0] w_ready_eff = layer_start_pulse ? 6'd0 : w_ready_cur;
    wire [2:0] fc2_ptr_eff = layer_start_pulse ? 3'd0 : fc2_wgt_ptr;

// Quant load target (FC1 preloads FC2 quant at FC1 start)
wire [3:0] quant_tgt_eff =
    ((layer_id == L_MLP_FC1) && !mlp_quant_fc1_loaded) ? L_MLP_FC1 :
    ((layer_id == L_MLP_FC1) && !mlp_quant_fc2_loaded) ? L_MLP_FC2 :
    layer_id;



    // stride(=blk?? word ??)
    function [15:0] f_kstride;
        input [3:0] layer;
        begin
            if (layer == L_PATCH)      f_kstride = 16'd769;
            else if (layer == L_AV)      f_kstride = 16'd197;
            else if (layer == L_MLP_FC2) f_kstride = 16'd32;
            else                         f_kstride = 16'd192;
        end
    endfunction

    // tile base(192-step)
    function [17:0] f_kbase;
        input [4:0] t;
        begin
            // base offset in 256-bit WORD units. Default 192-word tiling.
            // PATCH uses 4 tiles (0..3), MLP uses up to 24 tiles (0..23).
            f_kbase = t * 18'd192;
        end
    endfunction

    // tile length
    function [9:0] f_klen;
        input [3:0] layer;
        input [4:0] t;
        begin
            if (layer == L_PATCH) begin
                if (t == 5'd3) f_klen = 10'd193;
                else          f_klen = 10'd192;
            end else if (layer == L_SCORE) begin
                f_klen = 10'd64; // SCORE head0: K=64
            end
        else if (layer == L_AV) begin
            f_klen = 10'd197; // AV: K=197
        end else if (layer == L_MLP_FC2) begin
            f_klen = 10'd32; // FC2 bring-up: tile0 only
        end else begin
                f_klen = 10'd192; // QKV proj: K=192
            end
        end
    endfunction

    // priority encoder
    function [2:0] pick_first_set7;
        input [6:0] v;
        begin
            if (v[0]) pick_first_set7 = 3'd0;
            else if (v[1]) pick_first_set7 = 3'd1;
            else if (v[2]) pick_first_set7 = 3'd2;
            else if (v[3]) pick_first_set7 = 3'd3;
            else if (v[4]) pick_first_set7 = 3'd4;
            else if (v[5]) pick_first_set7 = 3'd5;
            else pick_first_set7 = 3'd6;
        end
    endfunction

    // IN: base + mblk*KSTRIDE + k_base(tile)
    function [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] calc_in_addr;
        input [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base;
        input [2:0] mblk;
        input [4:0] tile;
        input [15:0] kstride;
        reg [17:0] off;
        begin
            off = (mblk * kstride) + f_kbase(tile);
            calc_in_addr = base + off;
        end
    endfunction

    // WGT: base + nblk*KSTRIDE + k_base(tile)
    function [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] calc_w_addr;
        input [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base;
        input [2:0] nblk;
        input [4:0] tile;
        input [15:0] kstride;
        reg [17:0] off;
        begin
            off = (nblk * kstride) + f_kbase(tile);
            calc_w_addr = base + off;
        end
    endfunction

    // OUT(residual): base_out + mblk*192 + nblk*32
function [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] calc_out_addr;
    input [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] base;
    input [2:0] mblk;
    input [2:0] nblk;
    reg [17:0] off;
    begin
        off = (mblk * 16'd192) + (nblk * 16'd32);
        calc_out_addr = base + off;
    end
endfunction

// ktile tracking (buffer-side)
    reg [4:0] ktile_seen;

    // MLP bias is loaded once at tile0 (FC1) and reused for all other MLP tiles
    reg        mlp_bias_loaded;
    reg mlp_quant_fc1_loaded;
    reg mlp_quant_fc2_loaded;
    reg [3:0] act_quant_tgt_layer;
    reg        act_bias_is_mlp;

    // ktile change pending
    reg        ktile_change_pending;
    reg [4:0] ktile_pending_val;

    wire ktile_change = (layer_id == L_PATCH) && (ktile_idx_cur != ktile_seen);
    wire can_apply_tile_change = (fsm != S_WAIT);
    wire tile_switching_now = ktile_change_pending && can_apply_tile_change;

    // next-tile input bookkeeping (patch only)
    reg [6:0] need_in_next;
    reg [6:0] in_ready_next;
    reg [4:0] next_tile_for_in;

    wire [2:0] m_pick_cur  = pick_first_set7(~in_ready_cur);
    wire [2:0] m_pick_next = pick_first_set7(need_in_next & ~in_ready_next);

    // 2-slot WEI schedule state
    // FC2 bring-up: sequential WGT preload pointer (nblk 0..5)
    reg [2:0] fc2_wgt_ptr;
    reg [2:0] wgt_slot0_nblk;  // 0->2->4->(next tile 0)
    reg [2:0] wgt_slot1_nblk;  // 1->3->5
    reg       wgt_slot0_valid;
    reg       wgt_slot1_valid;

    reg [1:0] wgt_slot_loading;
    reg [1:0] wgt_slot_release_pending;
    reg boot_wgt0_loaded;
    reg oproj_wgt0_seen;
    // SCORE(Q head0) reload bookkeeping
    reg  [2:0] score_q_mblk_next;
    reg        score_q_release_pending;
    reg act_wgt_slot;
    reg act_wgt_is_next;

    reg       slot0_is_next;
    reg [4:0] slot0_next_ktile;


    // next-layer W0 prefetch bookkeeping (slot0)
    reg        nl_w0_req;
    reg        nl_w0_valid;
    reg  [3:0] nl_w0_layer;
    reg  [4:0] nl_w0_ktile;
    reg  [2:0] nl_w0_nblk;
    reg        nl_w0_bank;
    reg  [M_AXI_ADDR_WIDTH-ADDR_LSB-1:0] nl_w0_base_w;



    // FC1->FC2 full weight prefetch sequencing (nblk 0..5)
    reg        nl_fc2_pf_active;
    reg [2:0]  nl_fc2_pf_ptr;
    reg        nl_w0_fc2_full;   // this nl_w0 descriptor represents "FC2 full preload"
// Export next-layer W0 prefetch completion (latched valid until consumed at layer_start_pulse)
assign nl_pf_valid = nl_w0_valid;
assign nl_pf_layer = nl_w0_layer;
assign nl_pf_ktile = nl_w0_ktile;
assign nl_pf_nblk  = nl_w0_nblk;
assign nl_pf_bank  = nl_w0_bank;

// Expected W0 descriptor at layer start (for consuming next-layer prefetch)
// - Most layers start with (ktile=0, nblk=0, bank0)
// - AV starts with nblk={head,0}
// - FC2 (if prefetched later) starts on bank1
wire [2:0] nl_w0_expect_nblk = (layer_id == L_AV)      ? {layer_head_idx, 1'b0} :
                               3'd0;

wire nl_fc2_bank       = ~layer_wgt_phase;
wire nl_w0_expect_bank = (layer_id == L_MLP_FC2) ? nl_fc2_bank : layer_wgt_phase;

wire       nl_w0_match = nl_w0_valid &&
                         (nl_w0_layer == layer_id) &&
                         (nl_w0_ktile == ktile_idx_cur) &&
                         (nl_w0_nblk  == nl_w0_expect_nblk) &&
                         (nl_w0_bank  == nl_w0_expect_bank);

// FC2 full-prefetch: on the layer_start_pulse cycle, override the "eff" views so FC2 bring-up does not re-read WGT.
wire       layerstart_fc2_fullpref = layer_start_pulse && (layer_id == L_MLP_FC2) && nl_w0_match && nl_w0_fc2_full;
wire [5:0] w_ready_eff_fc2 = layerstart_fc2_fullpref ? 6'b111111 : w_ready_eff;
wire [2:0] fc2_ptr_eff_fc2 = layerstart_fc2_fullpref ? 3'd6      : fc2_ptr_eff;
 
// MLP FC1/FC2 are run in prefetch-only mode: current-layer weight reads are suppressed.
wire mlp_prefetch_only = (layer_id == L_MLP_FC1) || (layer_id == L_MLP_FC2);



    reg        act_wgt_is_nextlayer;

    reg        act_wgt_is_nl_fc2pf;
    // Active transaction latch
    wire r_fire = axi_rvalid && axi_rready;

    reg [2:0]  act_kind;
    reg [4:0] act_ktile;
    reg [2:0]  act_nblk;
    reg [2:0]  act_mblk;
    reg [10:0] act_base;
    reg        act_bank;
    reg [10:0] beat_idx;

    reg act_in_is_next;

    // OPROJ residual prefetch into SCOREBUF
    reg        res_inflight;
    reg [2:0]  res_nblk;
    reg [2:0]  res_mblk;
    reg        res_bank;

    wire [5:0] res_need     = w_ready_cur & ~res_ready_cur;
    wire       res_need_any = |res_need;
    wire [2:0] res_pick     = res_need[0] ? 3'd0 :
                              res_need[1] ? 3'd1 :
                              res_need[2] ? 3'd2 :
                              res_need[3] ? 3'd3 :
                              res_need[4] ? 3'd4 :
                              res_need[5] ? 3'd5 : 3'd0;

    wire [2:0] res_nblk_eff = res_inflight ? res_nblk : res_pick;
    wire [2:0] res_mblk_eff = res_inflight ? res_mblk : 3'd0;
    wire       res_bank_eff = res_inflight ? res_bank : res_pick[0];


    // stride latch per layer (combinational is fine too)
    wire [15:0] kstride_cur = f_kstride(layer_id);

    // ---------------- Sequential ----------------
    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            fsm <= S_IDLE;

            base_in_l <= 0;
            base_w_l  <= 0;
            base_b_l  <= 0;
            base_out_l<= 0;

            ktile_seen <= 0;
            ktile_change_pending <= 0;
            ktile_pending_val    <= 0;

            need_in_next     <= 0;
            in_ready_next    <= 0;
            next_tile_for_in <= 0;

            wgt_slot0_nblk  <= 0;
            wgt_slot1_nblk  <= 0;
            wgt_slot0_valid <= 0;
            wgt_slot1_valid <= 0;

            wgt_slot_loading         <= 0;
            wgt_slot_release_pending <= 0;

            boot_wgt0_loaded <= 0;
                    oproj_wgt0_seen <= 0;
            score_q_mblk_next       <= 0;
            score_q_release_pending <= 1'b0;

            slot0_is_next    <= 0;
            slot0_next_ktile <= 0;
            nl_w0_req   <= 0;
            nl_w0_valid <= 0;
            nl_w0_layer <= 0;
            nl_w0_ktile <= 0;
            nl_w0_nblk  <= 0;
            nl_w0_bank  <= 0;
            nl_w0_base_w<= 0;
            nl_fc2_pf_active <= 1'b0;
            nl_fc2_pf_ptr    <= 3'd0;
            nl_w0_fc2_full   <= 1'b0;
            act_wgt_is_nextlayer <= 0;
            act_wgt_is_nl_fc2pf    <= 1'b0;
            bias_ready   <= 0;
                mlp_bias_loaded <= 1'b0;
                act_bias_is_mlp <= 1'b0;
            in_ready_cur <= 0;
            w_ready_cur  <= 0;
                    fc2_wgt_ptr <= 0;

            m_axi_read_init   <= 0;
            m_axi_araddress   <= 0;
            m_axi_read_length <= 0;

            act_kind  <= LD_NONE;
            act_ktile <= 0;
            act_nblk  <= 0;
            act_mblk  <= 0;
            act_base  <= 0;
            act_bank  <= 0;
            beat_idx  <= 0;

            act_in_is_next  <= 0;
            act_wgt_slot    <= 0;
            act_wgt_is_next <= 0;

            mem_wr_valid <= 0;
            mem_wr_kind  <= 0;
            mem_wr_bank  <= 0;
            mem_wr_addr  <= 0;
            mem_wr_data  <= 0;
        end else begin
            // defaults
            m_axi_read_init <= 0;
            mem_wr_valid    <= 0;

            if (!layer_active) begin
                fsm <= S_IDLE;

                bias_ready   <= 0;
            quant_ready <= 0;
                in_ready_cur <= 0;
                w_ready_cur  <= 0;
                    fc2_wgt_ptr <= 0;

                need_in_next  <= 0;
                in_ready_next <= 0;

                wgt_slot0_nblk  <= 0;
                wgt_slot1_nblk  <= 0;
                wgt_slot0_valid <= 0;
                wgt_slot1_valid <= 0;

                wgt_slot_loading         <= 0;
                wgt_slot_release_pending <= 0;

                boot_wgt0_loaded <= 0;

                slot0_is_next    <= 0;
                slot0_next_ktile <= 0;

                ktile_seen <= 0;
                ktile_change_pending <= 0;
                ktile_pending_val    <= 0;

                act_kind <= LD_NONE;
                                    act_wgt_is_nextlayer <= 0;
                                    act_wgt_is_nl_fc2pf    <= 1'b0;
                beat_idx <= 0;

                m_axi_read_length <= 0;
            end else begin
                // start init
                
                // latch next-layer prefetch request (one-shot)
// - Default: single W0 prefetch.
// - Special: FC1->FC2 uses "full preload" (nblk 0..5) sequence; nl_pf_valid asserts only after all 6 are loaded.
                if (nl_wgt0_prefetch_pulse) begin
                    nl_w0_layer  <= nl_wgt0_layer_id;
                    nl_w0_ktile  <= nl_wgt0_ktile;
                    nl_w0_bank   <= nl_wgt0_bank;
                    nl_w0_base_w <= nl_wgt0_base_w_word;

                    if (nl_wgt0_layer_id == L_MLP_FC2) begin
                        // FC2 full preload sequence
                        nl_fc2_pf_active <= 1'b1;
                        nl_fc2_pf_ptr    <= 3'd0;
                        nl_w0_fc2_full   <= 1'b1;

                        nl_w0_req        <= 1'b0;   // sequence-driven; do not use legacy single-shot path
                        nl_w0_nblk       <= 3'd0;   // descriptor stays at W0 for pf_done matching
                        nl_w0_valid      <= 1'b0;   // clear any stale completion
                    end else begin
                        // legacy: single W0 prefetch
                        nl_w0_req      <= 1'b1;
                        nl_w0_nblk     <= nl_wgt0_nblk;
                        nl_w0_fc2_full <= 1'b0;
                        nl_w0_valid    <= 1'b0; // (re)arm
                    end
                end

                if (layer_start_pulse) begin
                    base_in_l <= base_in_word;
                    base_w_l  <= base_w_word;
                    base_b_l  <= base_b_word;
                    base_out_l<= base_out_word;

            base_q_l   <= base_q_word;
                    ktile_seen <= ktile_idx_cur;

                    ktile_change_pending <= 0;
                    ktile_pending_val    <= 0;

// quant policy on new layer start:
// - default: quant not ready, will be loaded first
// - FC2: can skip reload if it was preloaded during FC1
if (layer_id == L_MLP_FC2) quant_ready <= mlp_quant_fc2_loaded;
else                       quant_ready <= 1'b0;

// FC1 triggers (re)load of both FC1/FC2 quant words
if (layer_id == L_MLP_FC1) begin
    mlp_quant_fc1_loaded <= 1'b0;
    mlp_quant_fc2_loaded <= 1'b0;
end

                    // bias policy on new layer start:
                    // - SCORE/AV/FC2: no bias fetch needed
                    // - MLP_FC1: fetch bias only once at tile0, then reuse for other tiles
                    // - others: bias fetch required
                    // IMPORTANT: MLP bias is per-encoder-block. Reset when FC1 tile0 starts.
                    if ((layer_id == L_MLP_FC1) && (ktile_idx_cur == 5'd0)) begin
                        mlp_bias_loaded <= 1'b0;
                    end
                    if ((layer_id == L_SCORE) || (layer_id == L_AV) || (layer_id == L_MLP_FC2)) begin
                        bias_ready <= 1'b1;
                    end else if (layer_id == L_MLP_FC1) begin
                        // For each encoder block, FC1 tile0 must reload bias (base_b_word changes per block).
                        bias_ready <= (ktile_idx_cur == 5'd0) ? 1'b0 : (mlp_bias_loaded ? 1'b1 : 1'b0);
end else begin
                        bias_ready <= 1'b0;
                    end

                    // Patch: DDR???? IN ???? ???
                    if (layer_id == L_PATCH) begin
                        in_ready_cur <= 0;
                        mlp_bias_loaded <= 1'b0; // new run / rewind
                    end else begin
                        // Q: IN?? resident(GB)?? ???? -> ??? ????
                        in_ready_cur <= 7'b1111111;
                    end

                    need_in_next     <= 0;
                    in_ready_next    <= 0;
                    next_tile_for_in <= ktile_idx_cur + 1'b1;

                    w_ready_cur <= 0;
                    fc2_wgt_ptr <= 0;
                    res_ready_cur <= 0;
                    res_upto0 <= 0; res_upto1 <= 0; res_upto2 <= 0; res_upto3 <= 0; res_upto4 <= 0; res_upto5 <= 0;
                    res_inflight  <= 0;
                    res_nblk      <= 0;
                    res_mblk      <= 0;
                    res_bank      <= 0;

                    if (layer_id == L_AV) begin
                        wgt_slot0_nblk  <= {layer_head_idx, 1'b0};
                        wgt_slot1_nblk  <= {layer_head_idx, 1'b0} + 3'd1;
                    end else begin
                        wgt_slot0_nblk  <= 3'd0;
                        wgt_slot1_nblk  <= 3'd1;
                    end
                    wgt_slot0_valid <= 0;
                    wgt_slot1_valid <= 0;

                    wgt_slot_loading         <= 0;
                    wgt_slot_release_pending <= 0;

                    boot_wgt0_loaded <= 0;
                    oproj_wgt0_seen <= 1'b0;
                    score_q_mblk_next       <= 0;
                    score_q_release_pending <= 1'b0;

                    slot0_is_next    <= 0;
                    slot0_next_ktile <= 0;

                    nl_fc2_pf_active <= 1'b0;
                    nl_fc2_pf_ptr    <= 3'd0;


// Consume next-layer prefetched W0 (skip W0 boot read)
if (nl_w0_match) begin
    boot_wgt0_loaded <= 1'b1;

    

    if (layer_id == L_O_PROJ) oproj_wgt0_seen <= 1'b1;
// Mark W0 as ready immediately for this layer
    if (layer_id == L_SCORE) begin
        w_ready_cur[layer_wgt_phase] <= 1'b1;  // SCORE bank=phase (mblk0)
        score_q_mblk_next   <= 3'd1;  // mblk0 already loaded -> next read is mblk1
    end else if ((layer_id == L_MLP_FC2) && nl_w0_fc2_full) begin
        // FC2 full preload consumed: all nblk0..5 are already in the FC2 bank
        w_ready_cur   <= 6'b111111;
        fc2_wgt_ptr   <= 3'd6;
    end else begin
        w_ready_cur[nl_w0_expect_nblk] <= 1'b1;
    end

    // Keep slot0 bookkeeping as valid W0 (common path)
// NOTE: SCORE layer uses slot-valids as "unused" (kept 0) so that SCORE->AV next-layer prefetch
// can always reuse slot0 during SCORE without being blocked by slot0_valid.
if ((layer_id == L_SCORE) || (layer_id == L_MLP_FC2)) begin
    wgt_slot0_nblk              <= nl_w0_expect_nblk;
    wgt_slot0_valid             <= 1'b0;
    wgt_slot_loading[0]         <= 1'b0;
    wgt_slot_release_pending[0] <= 1'b0;
end else begin
    wgt_slot0_nblk              <= nl_w0_expect_nblk;
    wgt_slot0_valid             <= 1'b1;
    wgt_slot_loading[0]         <= 1'b0;
    wgt_slot_release_pending[0] <= 1'b0;
end

    // One-shot consume
    nl_w0_valid <= 1'b0;
    nl_w0_fc2_full <= 1'b0;
end

                    act_kind <= LD_NONE;
                                    act_wgt_is_nextlayer <= 0;
                    act_bias_is_mlp <= 1'b0;
                    beat_idx <= 0;

                    m_axi_read_length <= 0;
                
                    // Force read FSM to restart for the new layer
                    fsm <= S_CHOOSE;

                    // NEW: run-boundary cleanup (when a new run starts at PATCH)
                    // Clear any latched next-layer prefetch completion / OPROJ residual gate that could leak across runs.
                    if (layer_id == L_PATCH) begin
                        nl_w0_valid    <= 1'b0;
                        nl_w0_fc2_full <= 1'b0;
                        nl_w0_req      <= 1'b0;
                        nl_w0_layer    <= 0;
                        nl_w0_ktile    <= 0;
                        nl_w0_nblk     <= 0;
                        nl_w0_bank     <= 0;
                        nl_w0_base_w   <= 0;
                        oproj_wgt0_seen <= 1'b0;
                        mlp_quant_fc1_loaded <= 1'b0;
                        mlp_quant_fc2_loaded <= 1'b0;
                    end
end else begin

                // ktile change handling (PATCH only)
                // - ktile change detection arrives 1 cycle after vit_controller increments ktile_idx_cur.
                // - With slow DDR, we must not allow compute to reuse previous-ktile IN data.
                // - If no AXI read is inflight (fsm != S_WAIT), apply the tile promotion immediately (no extra bubble).
                // - Otherwise, latch pending and force in_ready_cur=0 until promotion is applied.
                if (ktile_change && can_apply_tile_change) begin
                    // apply immediately (no 1-cycle bubble)
                    ktile_seen <= ktile_idx_cur;
                
                    // Patch: promote next->cur
                    in_ready_cur  <= in_ready_next;
                    in_ready_next <= 0;
                    need_in_next  <= 0;
                
                    // reset weights for new tile, BUT keep prefetched next-W0 if it matches
                    w_ready_cur <= 0;
                    fc2_wgt_ptr <= 0;
                    res_ready_cur <= 0;
                    res_inflight  <= 0;
                    res_nblk      <= 0;
                    res_mblk      <= 0;
                    res_bank      <= 0;
                
                    wgt_slot1_nblk  <= 3'd1;
                    wgt_slot1_valid <= 0;
                    wgt_slot_loading[1] <= 0;
                    wgt_slot_release_pending[1] <= 0;
                
                    if (slot0_is_next && wgt_slot0_valid && (slot0_next_ktile == ktile_idx_cur) && (wgt_slot0_nblk == 3'd0)) begin
                        w_ready_cur[0]   <= 1'b1;
                        boot_wgt0_loaded <= 1'b1;
                
                        wgt_slot0_nblk   <= 3'd0;
                        wgt_slot0_valid  <= 1'b1;
                        wgt_slot_loading[0] <= 0;
                        wgt_slot_release_pending[0] <= 0;
                
                        slot0_is_next <= 0;
                    end else begin
                        boot_wgt0_loaded <= 0;
                
                        wgt_slot0_nblk   <= 3'd0;
                        wgt_slot0_valid  <= 0;
                        wgt_slot_loading[0] <= 0;
                        wgt_slot_release_pending[0] <= 0;
                
                        slot0_is_next    <= 0;
                        slot0_next_ktile <= 0;
                    end
                
                    next_tile_for_in <= ktile_idx_cur + 1'b1;
                
                    ktile_change_pending <= 0;
                end else begin
                    // ktile change -> pending
                    if (ktile_change) begin
                        // block compute on the new ktile until promotion is applied
                        in_ready_cur <= 0;
                
                        ktile_change_pending <= 1'b1;
                        ktile_pending_val    <= ktile_idx_cur;
                    end
                
                    // apply tile promote only when not inflight
                    if (ktile_change_pending && can_apply_tile_change) begin
                        ktile_seen <= ktile_pending_val;
                
                        // Patch: promote next->cur
                        in_ready_cur  <= in_ready_next;
                        in_ready_next <= 0;
                        need_in_next  <= 0;
                
                        // reset weights for new tile, BUT keep prefetched next-W0 if it matches
                        w_ready_cur <= 0;
                        fc2_wgt_ptr <= 0;
                        res_ready_cur <= 0;
                        res_inflight  <= 0;
                        res_nblk      <= 0;
                        res_mblk      <= 0;
                        res_bank      <= 0;
                
                        wgt_slot1_nblk  <= 3'd1;
                        wgt_slot1_valid <= 0;
                        wgt_slot_loading[1] <= 0;
                        wgt_slot_release_pending[1] <= 0;
                
                        if (slot0_is_next && wgt_slot0_valid && (slot0_next_ktile == ktile_pending_val) && (wgt_slot0_nblk == 3'd0)) begin
                            w_ready_cur[0]   <= 1'b1;
                            boot_wgt0_loaded <= 1'b1;
                
                            wgt_slot0_nblk   <= 3'd0;
                            wgt_slot0_valid  <= 1'b1;
                            wgt_slot_loading[0] <= 0;
                            wgt_slot_release_pending[0] <= 0;
                
                            slot0_is_next <= 0;
                        end else begin
                            boot_wgt0_loaded <= 0;
                
                            wgt_slot0_nblk   <= 3'd0;
                            wgt_slot0_valid  <= 0;
                            wgt_slot_loading[0] <= 0;
                            wgt_slot_release_pending[0] <= 0;
                
                            slot0_is_next    <= 0;
                            slot0_next_ktile <= 0;
                        end
                
                        next_tile_for_in <= ktile_pending_val + 1'b1;
                
                        ktile_change_pending <= 0;
                    end
                end

                // next-tile input overwrite request (patch only)
                if ((layer_id == L_PATCH) && (mblk_release_pulse != 0)) begin
                    need_in_next     <= need_in_next | mblk_release_pulse;
                    next_tile_for_in <= ktile_seen + 1'b1;
                end

                // capture releases
                if (layer_id == L_SCORE) begin
                    // SCORE: free the bank that just finished (vit_controller toggles bank by mblk parity)
                    if (wgt_slot_release_pulse[0]) w_ready_cur[0] <= 1'b0;
                    if (wgt_slot_release_pulse[1]) w_ready_cur[1] <= 1'b0;
                end else begin
                    if (wgt_slot_release_pulse[0]) wgt_slot_release_pending[0] <= 1'b1;
                    if (wgt_slot_release_pulse[1]) wgt_slot_release_pending[1] <= 1'b1;
                end
                if ((layer_id != L_SCORE) && wgt_slot_release_pending[0] && !wgt_slot_loading[0]) begin
                    wgt_slot_release_pending[0] <= 0;

                    if (wgt_slot0_valid && !slot0_is_next) begin
                        w_ready_cur[wgt_slot0_nblk] <= 0;
                    end

                    if ((wgt_slot0_nblk == 3'd0) || (wgt_slot0_nblk == 3'd2)) begin
                        wgt_slot0_nblk  <= wgt_slot0_nblk + 3'd2;
                        wgt_slot0_valid <= 0;
                        slot0_is_next   <= 0;
                    end else if (wgt_slot0_nblk == 3'd4) begin
                        wgt_slot0_nblk  <= 3'd0;
                        wgt_slot0_valid <= 0;
                        slot0_is_next   <= 1'b1;
                        slot0_next_ktile<= ktile_seen + 1'b1;
                    end
                end

                if ((layer_id != L_SCORE) && wgt_slot_release_pending[1] && !wgt_slot_loading[1]) begin
                    wgt_slot_release_pending[1] <= 0;

                    if (wgt_slot1_valid) begin
                        w_ready_cur[wgt_slot1_nblk] <= 0;
                    end

                    if ((wgt_slot1_nblk == 3'd1) || (wgt_slot1_nblk == 3'd3)) begin
                        wgt_slot1_nblk  <= wgt_slot1_nblk + 3'd2;
                        wgt_slot1_valid <= 0;
                    end
                end

                // R-channel -> SRAM write
                if (r_fire) begin
                    mem_wr_valid <= 1'b1;
                    mem_wr_kind  <= act_kind;
                    // BIAS is stored in a single (unbanked) RAM in memory_controller
                    mem_wr_bank  <= (act_kind == LD_BIAS) ? 1'b0 : act_bank;
mem_wr_addr  <= act_base + beat_idx;
                    mem_wr_data  <= axi_rdata;
                    beat_idx     <= beat_idx + 1'b1;
                end

                case (fsm)
                    S_IDLE: begin
                        fsm <= S_CHOOSE;
                    end

                    S_CHOOSE: begin
                        if (tile_switching_now) begin
                            fsm <= S_CHOOSE;
                        end else begin
                            // priority:
// 0) quant constants (must be loaded before compute starts)
if (!quant_ready) begin
    act_kind       <= LD_QUANT;
    act_quant_tgt_layer <= quant_tgt_eff;
    act_ktile      <= 0;
    act_nblk       <= 0;
    act_mblk       <= 0;
    act_bank       <= 0;
    act_base       <= {7'd0, quant_tgt_eff};
    act_in_is_next <= 0;
    act_wgt_is_next<= 0;
    beat_idx       <= 0;

    m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= base_q_eff + quant_tgt_eff;
    m_axi_araddress[ADDR_LSB-1:0]               <= 0;
    m_axi_read_length <= 17'd1;
    m_axi_read_init   <= 1'b1;
    fsm <= S_WAIT;
end else

                            // 1) bias
                            // 2) W0 boot
                            // 3) IN (patch only)
                            // 4) W1 boot
                            // 5) next tile W0 prefetch
                            // 6) next-tile IN overwrite (patch only)
                            // 7) slot reload

                            // SCORE: prefetch Q(mblk) into WGT ping-pong banks (bank = mblk[0] ^ phase)
                            // FC2: sequential WGT preload (nblk 0..5) into FC2 bank.
                            // After preload completes (fc2_wgt_ptr > 5), fall through so other priorities
                            // (e.g., next-layer W0 prefetch for the next tile) can run during FC2.
                            if ((layer_id == L_MLP_FC2) && (fc2_ptr_eff_fc2 <= 3'd5) && !mlp_prefetch_only) begin
                                if (w_ready_eff_fc2[fc2_ptr_eff_fc2]) begin
                                    fc2_wgt_ptr <= fc2_wgt_ptr + 3'd1;
                                    fsm <= S_CHOOSE;
                                end else if (!wgt_slot_loading[1]) begin
                                    act_wgt_slot   <= 1;

                                    act_kind       <= LD_WGT;
                                    act_ktile      <= ktile_idx_cur;
                                    act_nblk       <= fc2_ptr_eff_fc2;
                                    act_mblk       <= 0;
                                    act_bank       <= nl_fc2_bank;
                                    act_base       <= {fc2_ptr_eff_fc2, 5'd0};
                                    act_in_is_next <= 0;
                                    act_wgt_is_next<= 0;
                                    beat_idx       <= 0;

                                    wgt_slot_loading[1] <= 1'b1;

                                    m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_w_addr(base_w_eff, fc2_ptr_eff_fc2, ktile_idx_cur, kstride_cur);
                                    m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                    m_axi_read_length <= {7'd0, f_klen(layer_id, ktile_idx_cur)};
                                    m_axi_read_init   <= 1'b1;

                                    fsm <= S_WAIT;
                                end else begin
                                    fsm <= S_CHOOSE;
                                end
                             end else if (layer_id == L_SCORE) begin
                                // SCORE: prefetch Q(mblk) into ping-pong banks (bank = mblk[0] ^ phase)
                                // When all Q blocks have been issued (score_q_mblk_next > 6),
                                // allow next-layer W0 prefetch (e.g., SCORE->AV) to run using the freed bank.
                                if (score_q_mblk_next <= 3'd6) begin
                                    if (!wgt_slot_loading[score_q_mblk_next[0]] && !w_ready_cur[score_q_mblk_next[0] ^ layer_wgt_phase]) begin
                                        act_wgt_slot   <= score_q_mblk_next[0];

                                        act_kind       <= LD_WGT;
                                        act_ktile      <= 5'd0;
                                        act_nblk       <= {5'd0, score_q_mblk_next[0]};
                                        act_mblk       <= score_q_mblk_next;
                                        act_bank       <= score_q_mblk_next[0] ^ layer_wgt_phase;
                                        act_base       <= 0;
                                        act_in_is_next <= 0;
                                        act_wgt_is_next<= 0;
                                        beat_idx       <= 0;

                                        wgt_slot_loading[score_q_mblk_next[0]] <= 1'b1;

                                        // Q is stored in DDR with depth=192 per mblk; head0 uses depth 0..63 only (klen=64)
                                        m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_in_addr(base_w_eff, score_q_mblk_next, 5'd0, 16'd192);
                                        m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                        m_axi_read_length <= {7'd0, f_klen(layer_id, 5'd0)};
                                        m_axi_read_init   <= 1'b1;

                                        score_q_mblk_next <= score_q_mblk_next + 1'b1;

                                        fsm <= S_WAIT;
                                    end else begin
                                        fsm <= S_CHOOSE;
                                    end
                                end else if (nl_w0_req && !nl_w0_valid && !wgt_slot0_valid && !wgt_slot_loading[0]) begin
                                    // next-layer W0 prefetch during SCORE (use slot0 bookkeeping, bank from descriptor)
                                    act_wgt_slot        <= 0;

                                    act_kind            <= LD_WGT;
                                    act_ktile           <= nl_w0_ktile;
                                    act_nblk            <= nl_w0_nblk;
                                    act_mblk            <= 0;
                                    act_bank            <= nl_w0_bank;
                                    act_base            <= 0;
                                    act_in_is_next      <= 0;
                                    act_wgt_is_next     <= 1'b0;
                                    act_wgt_is_nextlayer<= 1'b1;
                                    beat_idx            <= 0;

                                    // disable next-tile W0 prefetch when using this slot for next layer
                                    slot0_is_next       <= 0;
                                    slot0_next_ktile    <= 0;

                                    // consume request
                                    nl_w0_req           <= 1'b0;

                                    wgt_slot_loading[0] <= 1'b1;

                                    m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <=
                                        calc_w_addr(nl_w0_base_w, nl_w0_nblk, nl_w0_ktile, f_kstride(nl_w0_layer));
                                    m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                    m_axi_read_length <= {7'd0, f_klen(nl_w0_layer, nl_w0_ktile)};
                                    m_axi_read_init   <= 1'b1;

                                    fsm <= S_WAIT;
                                end else begin
                                    fsm <= S_CHOOSE;
                                end
                            end
                             else if (nl_fc2_pf_active && bias_ready && boot_wgt0_loaded && !nl_w0_valid && !wgt_slot1_valid && !wgt_slot_loading[1]) begin
                                 // FC1->FC2 full preload: prefetch FC2 nblk0..5 sequentially into nl_w0_bank (slot1).
                                 act_wgt_slot        <= 1;
                                 wgt_slot_loading[1] <= 1'b1;

                                 act_kind            <= LD_WGT;
                                 act_ktile           <= nl_w0_ktile;
                                 act_nblk            <= nl_fc2_pf_ptr;
                                 act_mblk            <= 0;
                                 act_bank            <= nl_w0_bank;
                                 act_base            <= {nl_fc2_pf_ptr, 5'd0};
                                 act_in_is_next      <= 0;
                                 act_wgt_is_next     <= 1'b0;
                                 act_wgt_is_nextlayer<= 1'b1;
                                 act_wgt_is_nl_fc2pf <= 1'b1;
                                 beat_idx            <= 0;

                                 m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <=
                                     calc_w_addr(nl_w0_base_w, nl_fc2_pf_ptr, nl_w0_ktile, f_kstride(nl_w0_layer));
                                 m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                 m_axi_read_length <= {7'd0, f_klen(nl_w0_layer, nl_w0_ktile)};
                                 m_axi_read_init    <= 1'b1;
                                 fsm <= S_WAIT;
                             end
    else if ((layer_id == L_O_PROJ) && bias_ready && (res_inflight || (oproj_wgt0_seen && res_need_any))) begin
        // OPROJ: prefetch residual from DDR OUT(PATCH_OUT) into SCOREBUF bank=nblk[0]
        if (!res_inflight) begin
            res_inflight <= 1'b1;
            res_nblk     <= res_pick;
            res_mblk     <= 0;
            res_bank     <= res_pick[0];
        end

        act_kind       <= LD_SCORE;
        act_ktile      <= ktile_idx_cur;
        act_nblk       <= res_nblk_eff;
        act_mblk       <= res_mblk_eff;
        act_bank       <= res_bank_eff;
        act_base       <= {res_mblk_eff, 5'd0}; // mblk*32
        act_in_is_next <= 0;
        act_wgt_is_next<= 0;
        beat_idx       <= 0;

        m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_out_addr(base_out_eff, res_mblk_eff, res_nblk_eff);
        m_axi_araddress[ADDR_LSB-1:0] <= 0;
        m_axi_read_length <= 17'd32;
        m_axi_read_init   <= 1'b1;

        fsm <= S_WAIT;
    end
    else if (!bias_ready) begin

                                act_kind       <= LD_BIAS;
                                act_bias_is_mlp <= (layer_id == L_MLP_FC1);
                                act_ktile      <= ktile_idx_cur;
                                act_nblk       <= 0;
                                act_mblk       <= 0;
                                act_bank       <= 1'b0;  // BIAS RAM is single-bank; force writes to bank0
                                act_base       <= 0;
                                act_in_is_next <= 0;
                                act_wgt_is_next<= 0;
                                beat_idx       <= 0;

                                m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= base_b_eff;
                                m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                m_axi_read_length <= (layer_id == L_MLP_FC1) ? 17'd60 : 17'd12;
                                m_axi_read_init   <= 1'b1;

                                fsm <= S_WAIT;
                            end
                            else if (!boot_wgt0_loaded) begin
                                if (mlp_prefetch_only) begin
                                    // MLP FC1/FC2: prefetch-only. Do not auto-read current-layer weights here.
                                    fsm <= S_CHOOSE;
                                end else if (layer_id == L_SCORE) begin
                                    // SCORE(Q head0): load Q for current mblk into WGT bank0, depth 0..63
                                    if (!wgt_slot_loading[0]) begin
                                        act_wgt_slot   <= 0;

                                        act_kind       <= LD_WGT;
                                        act_ktile      <= 0;
                                        act_nblk       <= 3'd0;
                                        act_mblk       <= score_q_mblk_next;
                                        act_bank       <= (layer_id == L_MLP_FC2) ? nl_fc2_bank : layer_wgt_phase;
                                        act_base       <= 0;
                                        act_in_is_next <= 0;
                                        act_wgt_is_next<= 0;
                                        beat_idx       <= 0;

                                        wgt_slot_loading[0] <= 1'b1;

                                        m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_in_addr(base_w_eff, score_q_mblk_next, 5'd0, 16'd192);
                                        m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                        m_axi_read_length <= {7'd0, f_klen(layer_id, 0)};
                                        m_axi_read_init   <= 1'b1;

                                        fsm <= S_WAIT;
                                    end else begin
                                        fsm <= S_CHOOSE;
                                    end
                                end else begin
                                if (!wgt_slot0_valid && !wgt_slot_loading[0] && !slot0_is_next) begin
                                    act_wgt_slot   <= 0;

                                    act_kind       <= LD_WGT;
                                    act_ktile      <= ktile_idx_cur;
                                    act_nblk       <= wgt_slot0_nblk;
                                    act_mblk       <= 0;
                                    act_bank       <= (layer_id == L_MLP_FC2) ? nl_fc2_bank : layer_wgt_phase; // slot0 -> wgt bank0 (FC2 forces bank1)
                                    act_base       <= 0;
                                    act_in_is_next <= 0;
                                    act_wgt_is_next<= 0;
                                    beat_idx       <= 0;

                                    wgt_slot_loading[0] <= 1'b1;

                                    m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_w_addr(base_w_eff, wgt_slot0_nblk, ktile_idx_cur, kstride_cur);
                                    m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                    m_axi_read_length <= {7'd0, f_klen(layer_id, ktile_idx_cur)};
                                    m_axi_read_init   <= 1'b1;

                                    fsm <= S_WAIT;
                                end else begin
                                    fsm <= S_CHOOSE;
                                end

                                end
                            end
                            else if (layer_id == L_SCORE) begin
                                // SCORE: after Q(mblk) is loaded, wait for release from vit_controller
                                fsm <= S_CHOOSE;
                            end
                            else if ((layer_id == L_PATCH) && (in_ready_cur != 7'b1111111)) begin
                                act_kind       <= LD_IN;
                                act_ktile      <= ktile_idx_cur;
                                act_nblk       <= 0;
                                act_mblk       <= m_pick_cur;
                                act_bank       <= layer_inbuf_sel;             // IN -> layer input bank
                                act_base       <= (m_pick_cur * MAX_KTILE);    // mblk segment base
                                act_in_is_next <= 0;
                                act_wgt_is_next<= 0;
                                beat_idx       <= 0;

                                m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_in_addr(base_in_eff, m_pick_cur, ktile_idx_cur, kstride_cur);
                                m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                m_axi_read_length <= {7'd0, f_klen(layer_id, ktile_idx_cur)};
                                m_axi_read_init   <= 1'b1;

                                fsm <= S_WAIT;
                            end
                            else if (!wgt_slot1_valid && !wgt_slot_loading[1] && (wgt_slot1_nblk == 3'd1) && (layer_id != L_MLP_FC1) && (layer_id != L_MLP_FC2)) begin
                                act_wgt_slot   <= 1;

                                act_kind       <= LD_WGT;
                                act_ktile      <= ktile_idx_cur;
                                act_nblk       <= 3'd1;
                                act_mblk       <= 0;
                                act_bank       <= (layer_id == L_MLP_FC2) ? nl_fc2_bank : (1'b1 ^ layer_wgt_phase); // slot1 -> wgt bank1
                                act_base       <= 0;
                                act_in_is_next <= 0;
                                act_wgt_is_next<= 0;
                                beat_idx       <= 0;

                                wgt_slot_loading[1] <= 1'b1;

                                m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_w_addr(base_w_eff, 3'd1, ktile_idx_cur, kstride_cur);
                                m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                m_axi_read_length <= {7'd0, f_klen(layer_id, ktile_idx_cur)};
                                m_axi_read_init   <= 1'b1;

                                fsm <= S_WAIT;
                            end
                                                        else if (nl_w0_req && !nl_w0_valid &&
                                     ((!wgt_slot0_valid && !wgt_slot_loading[0]) || (!wgt_slot1_valid && !wgt_slot_loading[1]))) begin
                                // next-layer W0 prefetch into a free slot (prefer slot0)
                                if (!wgt_slot0_valid && !wgt_slot_loading[0]) begin
                                    act_wgt_slot        <= 0;
                                    wgt_slot_loading[0] <= 1'b1;
                                end else begin
                                    act_wgt_slot        <= 1;
                                    wgt_slot_loading[1] <= 1'b1;
                                end

                                act_kind            <= LD_WGT;
                                act_ktile           <= nl_w0_ktile;
                                act_nblk            <= nl_w0_nblk;
                                act_mblk            <= 0;
                                act_bank            <= nl_w0_bank;
                                act_base            <= 0;
                                act_in_is_next      <= 0;
                                act_wgt_is_next     <= 1'b0;
                                // NOTE: next-layer W0 prefetch request
                                act_wgt_is_nextlayer<= 1'b1;
                                act_wgt_is_nl_fc2pf <= 1'b0;
                                beat_idx            <= 0;

                                // consume request; next-tile prefetch (slot0) is also disabled by the caller
                                nl_w0_req           <= 1'b0;

                                // Issue AR for next-layer W0 using the same addressing scheme as other WGT reads
                                m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <=
                                    calc_w_addr(nl_w0_base_w, nl_w0_nblk, nl_w0_ktile, f_kstride(nl_w0_layer));
                                m_axi_read_length <= {7'd0, f_klen(nl_w0_layer, nl_w0_ktile)};
                                m_axi_read_init    <= 1'b1;
                                fsm <= S_WAIT;
                            end
                            else if (slot0_is_next && !wgt_slot0_valid && !wgt_slot_loading[0]) begin
                                act_wgt_slot   <= 0;

                                act_kind       <= LD_WGT;
                                act_ktile      <= slot0_next_ktile;
                                act_nblk       <= 3'd0;
                                act_mblk       <= 0;
                                act_bank       <= (layer_id == L_MLP_FC2) ? nl_fc2_bank : layer_wgt_phase;
                                act_base       <= 0;
                                act_in_is_next <= 0;
                                act_wgt_is_next<= 1'b1;
                                beat_idx       <= 0;

                                wgt_slot_loading[0] <= 1'b1;

                                m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_w_addr(base_w_eff, 3'd0, slot0_next_ktile, kstride_cur);
                                m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                m_axi_read_length <= {7'd0, f_klen(layer_id, slot0_next_ktile)};
                                m_axi_read_init   <= 1'b1;

                                fsm <= S_WAIT;
                            end
                            else if ((layer_id == L_PATCH) && ((need_in_next & ~in_ready_next) != 0)) begin
                                act_kind       <= LD_IN;
                                act_ktile      <= next_tile_for_in;
                                act_nblk       <= 0;
                                act_mblk       <= m_pick_next;
                                act_bank       <= layer_inbuf_sel;
                                act_base       <= (m_pick_next * MAX_KTILE);
                                act_in_is_next <= 1'b1;
                                act_wgt_is_next<= 0;
                                beat_idx       <= 0;

                                m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_in_addr(base_in_eff, m_pick_next, next_tile_for_in, kstride_cur);
                                m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                m_axi_read_length <= {7'd0, f_klen(layer_id, next_tile_for_in)};
                                m_axi_read_init   <= 1'b1;

                                fsm <= S_WAIT;
                            end
                            else if (!slot0_is_next && !wgt_slot0_valid && !wgt_slot_loading[0] && !mlp_prefetch_only) begin
                                act_wgt_slot   <= 0;

                                act_kind       <= LD_WGT;
                                act_ktile      <= ktile_idx_cur;
                                act_nblk       <= wgt_slot0_nblk;
                                act_mblk       <= 0;
                                act_bank       <= (layer_id == L_MLP_FC2) ? nl_fc2_bank : layer_wgt_phase;
                                act_base       <= 0;
                                act_in_is_next <= 0;
                                act_wgt_is_next<= 0;
                                beat_idx       <= 0;

                                wgt_slot_loading[0] <= 1'b1;

                                m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_w_addr(base_w_eff, wgt_slot0_nblk, ktile_idx_cur, kstride_cur);
                                m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                m_axi_read_length <= {7'd0, f_klen(layer_id, ktile_idx_cur)};
                                m_axi_read_init   <= 1'b1;

                                fsm <= S_WAIT;
                            end
                            else if (!wgt_slot1_valid && !wgt_slot_loading[1] && (layer_id != L_MLP_FC1) && (layer_id != L_MLP_FC2)) begin
                                act_wgt_slot   <= 1;

                                act_kind       <= LD_WGT;
                                act_ktile      <= ktile_idx_cur;
                                act_nblk       <= wgt_slot1_nblk;
                                act_mblk       <= 0;
                                act_bank       <= (layer_id == L_MLP_FC2) ? nl_fc2_bank : (1'b1 ^ layer_wgt_phase);
                                act_base       <= 0;
                                act_in_is_next <= 0;
                                act_wgt_is_next<= 0;
                                beat_idx       <= 0;

                                wgt_slot_loading[1] <= 1'b1;

                                m_axi_araddress[M_AXI_ADDR_WIDTH-1:ADDR_LSB] <= calc_w_addr(base_w_eff, wgt_slot1_nblk, ktile_idx_cur, kstride_cur);
                                m_axi_araddress[ADDR_LSB-1:0] <= 0;
                                m_axi_read_length <= {7'd0, f_klen(layer_id, ktile_idx_cur)};
                                m_axi_read_init   <= 1'b1;

                                fsm <= S_WAIT;
                            end
                            else begin
                                fsm <= S_CHOOSE;
                            end
                        end
                    end

                    S_WAIT: begin
                        if (m_axi_read_done) begin
                            if (act_kind == LD_BIAS) begin
                                bias_ready <= 1'b1;
                                if (act_bias_is_mlp) mlp_bias_loaded <= 1'b1;
                                act_bias_is_mlp <= 1'b0;
                            end else if (act_kind == LD_QUANT) begin

                                if (layer_id == L_MLP_FC1) begin

                                    if (act_quant_tgt_layer == L_MLP_FC1) mlp_quant_fc1_loaded <= 1'b1;

                                    if (act_quant_tgt_layer == L_MLP_FC2) mlp_quant_fc2_loaded <= 1'b1;


                                    if ( ((act_quant_tgt_layer == L_MLP_FC1) || mlp_quant_fc1_loaded) &&

                                         ((act_quant_tgt_layer == L_MLP_FC2) || mlp_quant_fc2_loaded) ) begin

                                        quant_ready <= 1'b1;

                                    end else begin

                                        quant_ready <= 1'b0;

                                    end

                                end else begin

                                    quant_ready <= 1'b1;

                                end


                            end else if (act_kind == LD_IN) begin
                                if (act_in_is_next) begin
                                    in_ready_next[act_mblk] <= 1'b1;
                                    need_in_next[act_mblk]  <= 1'b0;
                                end else begin
                                    in_ready_cur[act_mblk] <= 1'b1;
                                end
                            end else if (act_kind == LD_WGT) begin
                                // -------------------------------
                                // Weight load complete
                                // -------------------------------
                                if (act_wgt_is_nextlayer) begin
                                    // -------------------------------
                                    // Next-layer prefetch complete
                                    // -------------------------------
                                    if (act_wgt_is_nl_fc2pf) begin
                                        // FC1->FC2 full preload: advance pointer; assert nl_w0_valid only after nblk5 completes.
                                        wgt_slot_loading[1] <= 1'b0;
                                        wgt_slot1_valid     <= 1'b0;

                                        if (nl_fc2_pf_ptr == 3'd5) begin
                                            nl_fc2_pf_active <= 1'b0;
                                            nl_fc2_pf_ptr    <= 3'd0;
                                            nl_w0_valid      <= 1'b1;   // pf_done for FC1->FC2 gate
                                        end else begin
                                            nl_fc2_pf_ptr    <= nl_fc2_pf_ptr + 3'd1;
                                            nl_w0_valid      <= 1'b0;
                                        end
                                    end else begin
                                        // Legacy next-layer W0 prefetch: keep it protected in slot0/1 and assert nl_w0_valid.
                                        if (act_wgt_slot == 0) begin
                                            wgt_slot0_valid     <= 1'b1;
                                            wgt_slot_loading[0] <= 1'b0;
                                            wgt_slot0_nblk      <= act_nblk[2:0];
                                        end else begin
                                            wgt_slot1_valid     <= 1'b1;
                                            wgt_slot_loading[1] <= 1'b0;
                                            wgt_slot1_nblk      <= act_nblk[2:0];
                                        end
                                        nl_w0_valid <= 1'b1;
                                    end

                                    act_wgt_is_nl_fc2pf <= 1'b0;
                                    // NOTE: do NOT touch boot_wgt0_loaded / w_ready_cur for the current layer.
                                end else if (layer_id == L_SCORE) begin
                                    // SCORE Q(mblk) load: track readiness per physical bank (act_bank).
                                    if (act_wgt_slot == 0) wgt_slot_loading[0] <= 1'b0;
                                    else                  wgt_slot_loading[1] <= 1'b0;

                                    w_ready_cur[act_bank] <= 1'b1;

                                    if (!act_wgt_is_next) begin
                                        boot_wgt0_loaded <= 1'b1;
                                    end
                                end else begin
                                    if (act_wgt_slot == 0) begin
                                        wgt_slot0_valid     <= 1'b1;
                                        wgt_slot_loading[0] <= 1'b0;

                                        w_ready_cur[act_nblk] <= 1'b1;

                                        if ((layer_id == L_O_PROJ) && !act_wgt_is_next) oproj_wgt0_seen <= 1'b1;
                                        if (!act_wgt_is_next) begin
                                            boot_wgt0_loaded <= 1'b1;
                                        end
                                    end else begin
                                        wgt_slot1_valid     <= 1'b1;
                                        wgt_slot_loading[1] <= 1'b0;

                                        w_ready_cur[act_nblk] <= 1'b1;
                                    end
                                end
                            end else if (act_kind == LD_SCORE) begin
// Track loaded residual tiles per nblk (loaded in-order mblk=0..6)
case (act_nblk)
    3'd0: res_upto0 <= act_mblk[2:0];
    3'd1: res_upto1 <= act_mblk[2:0];
    3'd2: res_upto2 <= act_mblk[2:0];
    3'd3: res_upto3 <= act_mblk[2:0];
    3'd4: res_upto4 <= act_mblk[2:0];
    3'd5: res_upto5 <= act_mblk[2:0];
    default: ;
endcase

// Allow compute to start as soon as the first tile(mblk0) is loaded.
if (act_mblk == 3'd0) begin
    res_ready_cur[act_nblk] <= 1'b1;
end

// Continue prefetching remaining mblks in background.
if (act_mblk == 3'd6) begin
    res_inflight <= 0;
    res_mblk     <= 0;
end else begin
    res_mblk     <= act_mblk + 1'b1;
    res_inflight <= 1'b1;
end
end

m_axi_read_length <= 0;
fsm <= S_CHOOSE;
                        end
                    end

                    default: begin
                        fsm <= S_IDLE;
                    end
                endcase
end
            end
        end
    end

endmodule

`default_nettype wire