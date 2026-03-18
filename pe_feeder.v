`timescale 1ns/1ps
`default_nettype none

module pe_feeder #(
    parameter integer AXI_DATA_WIDTH = 256,
    parameter integer MAX_KTILE      = 197
)(
    input  wire                   clk,
    input  wire                   nRst,

    // job descriptor from vit_controller
    input  wire                   job_start,
    input  wire [9:0]             job_klen,
    input  wire [4:0]             job_ktile,
    input  wire [2:0]             job_nblk,
    input  wire [2:0]             job_mblk,
    input  wire                   job_in_base_is_nblk,
    input  wire [9:0]             job_in_koff,
    input  wire                   job_wbuf_sel,
    input  wire                   swap_ab,

    output wire                   job_ready,
    output reg                    job_done,      // pulse when tile_last MAC is issued

    // writeback meta (aligned to drain)
    output reg  [4:0]             wb_ktile_idx,
    output reg  [2:0]             wb_nblk_idx,
    output reg  [2:0]             wb_mblk_idx,

    // memory_controller read ports
    output reg                    in_rd_en,
    output reg  [10:0]            in_rd_addr,
    input  wire [AXI_DATA_WIDTH-1:0] in_rd_data,

    output reg                    w_rd_en,
    output reg                    w_rd_bank,
    output reg  [9:0]             w_rd_addr,
    input  wire [AXI_DATA_WIDTH-1:0] w_rd_data,

    // to pe_array
    output reg                    pe_in_valid,
    output reg                    pe_first,
    output reg                    pe_tile_last,
    output wire [32*8-1:0]        pe_a_rows_flat,
    output wire [32*8-1:0]        pe_b_cols_flat,

    // from pe_array
    input  wire                   pe_array_busy,
    input  wire                   pe_array_done
);

    // pass-through packing (256b == 32 lanes * 8b)
    assign pe_a_rows_flat = swap_ab ? w_rd_data[32*8-1:0] : in_rd_data[32*8-1:0];
    assign pe_b_cols_flat = swap_ab ? in_rd_data[32*8-1:0] : w_rd_data[32*8-1:0];

    reg        running;           // issuing/accumulating only
    reg        drain_inflight;    // previous tile drain occupies PE out_data/out_valid

    reg [9:0]  klen_lat;
    reg [4:0]  ktile_lat;
    reg [2:0]  nblk_lat;
    reg [2:0]  mblk_lat;
    reg        in_base_is_nblk_lat;
    reg        wbank_lat;


    // FC2 (K=32) bring-up helper
    reg        fc2_k32_lat;
    reg [9:0]  w_base_lat;   // nblk*32 for FC2; 0 otherwise

    reg [10:0] in_base_lat;       // mblk*MAX_KTILE
    reg [9:0]  k_issue;           // current MAC index (0..klen-1)

    wire [9:0] k_last    = (klen_lat == 0) ? 10'd0 : (klen_lat - 10'd1);
    wire       is_last_k = (k_issue == k_last);

    // stall ONLY the final MAC if previous tile is still draining
    wire stall_last = running && (k_issue < klen_lat) && is_last_k && drain_inflight;
    wire issue_fire = running && (k_issue < klen_lat) && !stall_last;

    // can accept a new job as soon as we finish issuing the current tile
    assign job_ready = !running;

    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            running        <= 0;
            drain_inflight <= 0;

            klen_lat  <= 0;
            ktile_lat <= 0;
            nblk_lat  <= 0;
            mblk_lat  <= 0;
            in_base_is_nblk_lat <= 0;
            wbank_lat <= 0;


            fc2_k32_lat <= 0;
            w_base_lat   <= 0;
            in_base_lat <= 0;
            k_issue     <= 0;

            job_done <= 0;

            wb_ktile_idx <= 0;
            wb_nblk_idx  <= 0;
            wb_mblk_idx  <= 0;

            in_rd_en   <= 0;
            in_rd_addr <= 0;

            w_rd_en   <= 0;
            w_rd_bank <= 0;
            w_rd_addr <= 0;

            pe_in_valid  <= 0;
            pe_first     <= 0;
            pe_tile_last <= 0;

        end else begin
            // defaults
            job_done     <= 0;
            pe_in_valid  <= 0;
            pe_first     <= 0;
            pe_tile_last <= 0;

            in_rd_en <= 0;
            w_rd_en  <= 0;


            // drain completion (previous tile)
            if (pe_array_done) begin
                drain_inflight <= 0;
            end

            // accept new job
            if (job_start && job_ready) begin
                running   <= 1;

                klen_lat  <= job_klen;
                ktile_lat <= job_ktile;
                nblk_lat  <= job_nblk;
                mblk_lat <= job_mblk;
                in_base_is_nblk_lat <= job_in_base_is_nblk;
                wbank_lat <= job_wbuf_sel;


                fc2_k32_lat <= (job_klen == 10'd32);
                w_base_lat   <= (job_klen == 10'd32) ? {job_nblk, 5'd0} : 10'd0;

                // input base:
                // - normal:  (job_in_base_is_nblk ? nblk : mblk) * MAX_KTILE + koff
                // - FC2 K=32: mblk * 32 + koff   (SCOREBUF tile input)
                in_base_lat <= (((job_klen == 10'd32) ? job_mblk : (job_in_base_is_nblk ? job_nblk : job_mblk))
                                * ((job_klen == 10'd32) ? 11'd32 : MAX_KTILE))
                                + job_in_koff;
                k_issue     <= 0;

                // prime read ports for k=0 (data appears next cycle)
                in_rd_en   <= 1;
                in_rd_addr <= (((job_klen == 10'd32) ? job_mblk : (job_in_base_is_nblk ? job_nblk : job_mblk))
                                * ((job_klen == 10'd32) ? 11'd32 : MAX_KTILE))
                                + job_in_koff;

                w_rd_en    <= 1;
                w_rd_bank  <= job_wbuf_sel;
                w_rd_addr  <= (job_klen == 10'd32) ? {job_nblk, 5'd0} : 10'd0;

            end else if (running) begin
                if (issue_fire) begin
                    // issue current MAC (aligned to previous cycle addr/data)
                    pe_in_valid  <= 1;
                    pe_first     <= (k_issue == 0);
                    pe_tile_last <= is_last_k;

                    if (is_last_k) begin
                        // last MAC executed -> commit tile to PE out_data
                        running        <= 0;
                        job_done       <= 1;
                        drain_inflight <= 1;

                        // latch drain meta for writeback
                        wb_ktile_idx <= ktile_lat;
                        wb_nblk_idx  <= nblk_lat;
                        wb_mblk_idx  <= mblk_lat;

                        in_rd_en <= 0;
                        w_rd_en  <= 0;

                    end else begin
                        // advance to next k, keep reads continuous
                        k_issue <= k_issue + 10'd1;

                        in_rd_en   <= 1;
                        in_rd_addr <= in_base_lat + (k_issue + 10'd1);

                        w_rd_en    <= 1;
                        w_rd_bank  <= wbank_lat;
                        w_rd_addr  <= fc2_k32_lat ? (w_base_lat + (k_issue + 10'd1)) : (k_issue + 10'd1);
                    end

                end else if (stall_last) begin
                    // hold ONLY the final MAC until drain finishes
                    // keep re-reading the last word so data stays valid
                    in_rd_en <= 1;
                    w_rd_en  <= 1;

                end else begin
                    in_rd_en <= 0;
                    w_rd_en  <= 0;
                end
            end
        end
    end

endmodule

`default_nettype wire