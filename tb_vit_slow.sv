`timescale 1ns/1ps
`default_nettype none

`define BASE_PATH "test_vector/tests"

module tb_vit_slow;

    // --------------------------
    // Parameters
    // --------------------------
    localparam int AXI_ID_WIDTH   = 1;
    localparam int AXI_ADDR_WIDTH = 32;
    localparam int AXI_DATA_WIDTH = 256;

    localparam int WORD_BYTES = (AXI_DATA_WIDTH/8);      // 32B
    localparam int ADDR_LSB   = $clog2(WORD_BYTES);       // 5

    // --------------------------
    // clock / reset / control
    // --------------------------
    logic clk;
    logic aresetn;
    logic start;
    logic done;

    // AXI interface
    // - DUT_AXI: master side (DUT <-> shim)
    // - DDR_AXI: slave side (shim <-> axi_ram_wrap)
    axi_if DUT_AXI();
    axi_if DDR_AXI();


    // AXI-Lite control interface (TB master -> DUT slave)
    localparam int S_AXI_ADDR_WIDTH = 12;
    localparam int S_AXI_DATA_WIDTH = 32;

    logic [S_AXI_ADDR_WIDTH-1:0]      s_axi_awaddr;
    logic                             s_axi_awvalid;
    logic                             s_axi_awready;

    logic [S_AXI_DATA_WIDTH-1:0]      s_axi_wdata;
    logic [S_AXI_DATA_WIDTH/8-1:0]    s_axi_wstrb;
    logic                             s_axi_wvalid;
    logic                             s_axi_wready;

    logic [1:0]                       s_axi_bresp;
    logic                             s_axi_bvalid;
    logic                             s_axi_bready;

    logic [S_AXI_ADDR_WIDTH-1:0]      s_axi_araddr;
    logic                             s_axi_arvalid;
    logic                             s_axi_arready;

    logic [S_AXI_DATA_WIDTH-1:0]      s_axi_rdata;
    logic [1:0]                       s_axi_rresp;
    logic                             s_axi_rvalid;
    logic                             s_axi_rready;

    // --------------------------
    // DDR address map (case0)
    // --------------------------
    localparam logic [31:0] WEIGHT_BASE     = 32'h8000_0000;
    localparam logic [31:0] INPUT_BASE      = 32'h8100_0000;
    localparam logic [31:0] PARAMETER_BASE  = 32'h8300_0000;

    localparam logic [31:0] QUANT_BASE      = 32'h8200_0000;
    localparam logic [31:0] OUTPUT_BASE     = 32'h8400_0000;

    // ------------------------------------------------------------
    // DDR layout constants (OFFSETS/SIZES in 256b word index)
    // ------------------------------------------------------------

    // NOTE:
    //     ??  ?       0x8500_0000  ???(16MB)  ? ??? ? ? ??????  ?,
    //     ?  ?       ?  ?  ?   ?    ?? X  ?       ????? X  ?  ? ?       ??   ? ???  .
    //             ? "  ???  ?        ???   ?"     ????????  ? ??  ?.
    //
    //     ??? ????   ?  ?       ?(OUT_STRIDE=193, M_BLK_NUM=7)   ??  ??  ? 1351  ???.
    //   (OUT_STRIDE  ? 192  ?   ?  ??    ?   ?  ?     1344  ?   ?  ?  ? ??.)

// STACK12 + residual slot stack
// Residual stack in OUT region (word = 32 bytes):
//   slot0            : PATCH output (post-quant)
//   slot(b+1)        : FC2 post-residual output of encoder block b
//   OPROJ debug area : placed AFTER residual stack (kept for legacy visibility)
localparam int ENC_BLKS = 12;

localparam int RESID_WORDS       = 1344; // 7*192, padded mblk storage (matches RTL calc_out_addr)
localparam int RESID_STACK_WORDS = (ENC_BLKS + 1) * RESID_WORDS;

localparam logic [31:0] RESID0_BASE = OUTPUT_BASE;
localparam logic [31:0] RESID0_END  = RESID0_BASE + (RESID_WORDS * WORD_BYTES);

localparam logic [31:0] RESID_LAST_BASE = OUTPUT_BASE + (ENC_BLKS * RESID_WORDS * WORD_BYTES);
localparam logic [31:0] RESID_LAST_END  = RESID_LAST_BASE + (RESID_WORDS * WORD_BYTES);


// Weight region sizing (256b words). Used only to size DDR init load ranges.
// Must match the layout assumed by RTL/addr_map.vh.
localparam int SIZE_W_PATCH_WGT  = 4614;  // 6*769
localparam int SIZE_W_ENC_BLK    = 16350; // per-encoder-block weights/slots (words)
localparam int SIZE_W_CLS_ALL    = 6144;  // 5*1152 + 384 (CLS0..4=192 each, CLS5=64)


// --------------------------
    // AXI RAM (DDR) instance
    // --------------------------
    axi_ram_wrap #(
        .AXI_ID_WIDTH  (AXI_ID_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ) DDR (
        .ACLK   (clk),
        .ARESETN(aresetn),
        .s00_axi(DDR_AXI)
    );

    // --------------------------
    // AXI slowdown shim
    //  - Use plusargs to enable random stalls / latency
    //    +SLOW_MEM
    //    +AXI_SEED=<int>
    //    +AW_STALL_MAX=<int> +W_STALL_MAX=<int> +B_STALL_MAX=<int>
    //    +AR_STALL_MAX=<int> +R_STALL_MAX=<int>
    //  - If +SLOW_MEM is set but *_MAX is not provided, reasonable defaults are used.
    // --------------------------
    axi_latency_inserter #(
        .AXI_ID_WIDTH  (AXI_ID_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH)
    ) U_AXI_SLOW (
        .ACLK   (clk),
        .ARESETN(aresetn),
        .s_axi  (DUT_AXI),
        .m_axi  (DDR_AXI)
    );

    // --------------------------
    // DUT: vit + AXI-Lite ctrl wrapper
    // --------------------------
    vit_axi_top #(
        .AXI_ID_WIDTH  (AXI_ID_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .ADDR_LSB      (ADDR_LSB),

        .S_AXI_ADDR_WIDTH(S_AXI_ADDR_WIDTH),
        .S_AXI_DATA_WIDTH(S_AXI_DATA_WIDTH),

        .DDR_TARGET_SLAVE_BASE_ADDR(WEIGHT_BASE),

        .BASE_W_ADDR_RESET   (WEIGHT_BASE),
        .BASE_IN_ADDR_RESET  (INPUT_BASE),
        .BASE_Q_ADDR_RESET   (QUANT_BASE),
        .BASE_B_ADDR_RESET   (PARAMETER_BASE),
        .BASE_OUT_ADDR_RESET (OUTPUT_BASE)
    ) u_vit (
        .clk    (clk),
        .aresetn(aresetn),

        // AXI-Lite control
        .s_axi_awaddr (s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),

        .s_axi_wdata  (s_axi_wdata),
        .s_axi_wstrb  (s_axi_wstrb),
        .s_axi_wvalid (s_axi_wvalid),
        .s_axi_wready (s_axi_wready),

        .s_axi_bresp  (s_axi_bresp),
        .s_axi_bvalid (s_axi_bvalid),
        .s_axi_bready (s_axi_bready),

        .s_axi_araddr (s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),

        .s_axi_rdata  (s_axi_rdata),
        .s_axi_rresp  (s_axi_rresp),
        .s_axi_rvalid (s_axi_rvalid),
        .s_axi_rready (s_axi_rready),

        // DDR AXI master
        .m00_axi_awid    (DUT_AXI.AWID),
        .m00_axi_awaddr  (DUT_AXI.AWADDR),
        .m00_axi_awlen   (DUT_AXI.AWLEN),
        .m00_axi_awsize  (DUT_AXI.AWSIZE),
        .m00_axi_awburst (DUT_AXI.AWBURST),
        .m00_axi_awlock  (DUT_AXI.AWLOCK),
        .m00_axi_awcache (DUT_AXI.AWCACHE),
        .m00_axi_awprot  (DUT_AXI.AWPROT),
        .m00_axi_awqos   (DUT_AXI.AWQOS),
        .m00_axi_awvalid (DUT_AXI.AWVALID),
        .m00_axi_awready (DUT_AXI.AWREADY),

        .m00_axi_wdata   (DUT_AXI.WDATA),
        .m00_axi_wstrb   (DUT_AXI.WSTRB),
        .m00_axi_wlast   (DUT_AXI.WLAST),
        .m00_axi_wvalid  (DUT_AXI.WVALID),
        .m00_axi_wready  (DUT_AXI.WREADY),

        .m00_axi_bid     (DUT_AXI.BID),
        .m00_axi_bresp   (DUT_AXI.BRESP),
        .m00_axi_bvalid  (DUT_AXI.BVALID),
        .m00_axi_bready  (DUT_AXI.BREADY),

        .m00_axi_arid    (DUT_AXI.ARID),
        .m00_axi_araddr  (DUT_AXI.ARADDR),
        .m00_axi_arlen   (DUT_AXI.ARLEN),
        .m00_axi_arsize  (DUT_AXI.ARSIZE),
        .m00_axi_arburst (DUT_AXI.ARBURST),
        .m00_axi_arlock  (DUT_AXI.ARLOCK),
        .m00_axi_arcache (DUT_AXI.ARCACHE),
        .m00_axi_arprot  (DUT_AXI.ARPROT),
        .m00_axi_arqos   (DUT_AXI.ARQOS),
        .m00_axi_arvalid (DUT_AXI.ARVALID),
        .m00_axi_arready (DUT_AXI.ARREADY),

        .m00_axi_rid     (DUT_AXI.RID),
        .m00_axi_rdata   (DUT_AXI.RDATA),
        .m00_axi_rresp   (DUT_AXI.RRESP),
        .m00_axi_rlast   (DUT_AXI.RLAST),
        .m00_axi_rvalid  (DUT_AXI.RVALID),
        .m00_axi_rready  (DUT_AXI.RREADY)
    );
    
    // --------------------------
    // clock/reset gen
    // --------------------------
    localparam real CLK_PERIOD  = 10.0; // ns
    localparam int  RESET_PULSE = 100;  // ns

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2.0) clk = ~clk;
    end

    initial begin
        aresetn = 1;
        #1;
        aresetn = 0;
        #(RESET_PULSE);
        aresetn = 1;
    end

    // --------------------------
    // Optional early-stop
    //   +STOP_AFTER_TILE0
    // --------------------------
    bit stop_after_tile0;
    initial stop_after_tile0 = $test$plusargs("STOP_AFTER_TILE0");

    // Sticky completion per-run (for multi-run TB + watchdog)
    bit done_latched [0:1];

    // --------------------------
    // Track "request-level completion" using m_axi_read_done
    // --------------------------
    localparam int LD_IN   = 1;
    localparam int LD_WGT  = 2;
    localparam int LD_BIAS = 3;

    localparam int K_TOTAL   = 769;
    localparam int MAX_KTILE = 193;

    bit got_bias;
    bit got_wgt_t0_n0;
    bit got_wgt_t0_n1;
    bit got_wgt_t0_n2;
    bit got_wgt_t0_n3;
    bit got_in_t0_m0;
    bit got_in_t0_m1;
    bit got_in_t0_m6;

    // --------------------------
    // File helper: read Nth line (0-based) from 256b hex file
    // --------------------------
    task automatic read_hex256_at_line(
        input  string path,
        input  int    line_idx,
        output logic [AXI_DATA_WIDTH-1:0] data256
    );
        int fd;
        string s;
        int i;
        int r;

        data256 = 0;
        fd = $fopen(path, "r");
        if (fd == 0) begin
            $display("[TB][ERROR] cannot open file: %s", path);
            return;
        end

        for (i = 0; i <= line_idx; i = i + 1) begin
            s = "";
            r = $fgets(s, fd);
            if (r == 0) begin
                $display("[TB][ERROR] EOF before line %0d in %s", line_idx, path);
                $fclose(fd);
                return;
            end
        end

        r = $sscanf(s, "%h", data256);
        if (r != 1) begin
            $display("[TB][ERROR] sscanf failed for line %0d in %s : %s", line_idx, path, s);
            data256 = 0;
        end

        $fclose(fd);
    endtask


    
     // ------------------------------------------------------------
    // Debug: extract byte with selectable byte order + sign-extend
    //   msb_first=0: lane0 = data[7:0]
    //   msb_first=1: lane0 = data[255:248]
    // ------------------------------------------------------------
    function automatic logic [7:0] get_u8_lane(
        input logic [AXI_DATA_WIDTH-1:0] w,
        input int lane,
        input bit msb_first
    );
        logic [7:0] b;
        if (!msb_first) b = w[lane*8 +: 8];
        else            b = w[(31-lane)*8 +: 8];
        return b;
    endfunction

    function automatic int signed sx8(input logic [7:0] u8);
        return $signed(u8); // 8-bit signed -> int signed
    endfunction


    
    
    // --------------------------
    // AXI-Lite master tasks (simulation-only)
    // --------------------------
    task automatic axi_lite_write32(
        input logic [11:0] addr,
        input logic [31:0] data
    );
        // Drive AW + W, then wait for B
        begin
            // AW
            s_axi_awaddr = addr;
            s_axi_awvalid = 1'b1;

            // W
            s_axi_wdata = data;
            s_axi_wstrb = 4'hF;
            s_axi_wvalid = 1'b1;

            // Wait handshake(s)
            while (!(s_axi_awvalid && s_axi_awready)) @(posedge clk);
            @(posedge clk);
            s_axi_awvalid = 1'b0;
            s_axi_awaddr = '0;

            while (!(s_axi_wvalid && s_axi_wready)) @(posedge clk);
            @(posedge clk);
            s_axi_wvalid = 1'b0;
            s_axi_wdata = '0;
            s_axi_wstrb = '0;

            // B response
            s_axi_bready = 1'b1;
            while (!s_axi_bvalid) @(posedge clk);
            if (s_axi_bresp != 2'b00) begin
                $display("[TB][AXIL][WARN] write32 addr=0x%03h data=0x%08x bresp=%02b @%0t",
                         addr, data, s_axi_bresp, $time);
            end
            @(posedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task automatic axi_lite_read32(
        input  logic [11:0] addr,
        output logic [31:0] data
    );
        begin
            s_axi_araddr = addr;
            s_axi_arvalid = 1'b1;

            while (!(s_axi_arvalid && s_axi_arready)) @(posedge clk);
            @(posedge clk);
            s_axi_arvalid = 1'b0;
            s_axi_araddr = '0;

            s_axi_rready = 1'b1;
            while (!s_axi_rvalid) @(posedge clk);
            data = s_axi_rdata;
            if (s_axi_rresp != 2'b00) begin
                $display("[TB][AXIL][WARN] read32 addr=0x%03h rresp=%02b @%0t",
                         addr, s_axi_rresp, $time);
            end
            @(posedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    // AXI-Lite reset defaults
    initial begin
        s_axi_awaddr  = 0;
        s_axi_awvalid = 0;
        s_axi_wdata   = 0;
        s_axi_wstrb   = 0;
        s_axi_wvalid  = 0;
        s_axi_bready  = 0;
        s_axi_araddr  = 0;
        s_axi_arvalid = 0;
        s_axi_rready  = 0;
    end

// --------------------------
    // Main sequence
    // --------------------------
    initial begin
        logic [31:0] ctrl_reg;

        start = 0;
        done  = 0;

        wait(aresetn);
        repeat(10) @(posedge clk);

        dram_init_case0_min();
        repeat(5) @(posedge clk);

        // Program base addresses (optional; wrapper already resets to these defaults)
        axi_lite_write32(12'h010, WEIGHT_BASE);
        axi_lite_write32(12'h014, INPUT_BASE);
        axi_lite_write32(12'h018, QUANT_BASE);
        axi_lite_write32(12'h01C, PARAMETER_BASE);
        axi_lite_write32(12'h020, OUTPUT_BASE);

        // Run the core twice back-to-back (same DDR vectors). This validates start/done protocol robustness.
        for (int run_id = 0; run_id < 2; run_id++) begin
            $display("====================================================");
            $display("[%0t] >>> RUN %0d START", $time, run_id);

            // Kick off run (CONTROL[0]=1)
            start = 1;
            axi_lite_write32(12'h000, 32'h0000_0001);
            start = 0;

            // Poll done_sticky (CONTROL[1])
            ctrl_reg = 0;
            while (ctrl_reg[1] == 1'b0) begin
                axi_lite_read32(12'h000, ctrl_reg);
                @(posedge clk);
            end

            done_latched[run_id] = 1'b1;
            done = 1;
            $display("[%0t] <<< RUN %0d DONE (AXI-Lite done_sticky)", $time, run_id);

            repeat(10) @(posedge clk);
            done = 0;

            $display("[%0t] Dump counters: total=%0d, layer=%0d", $time,
                     u_vit.u_core.ctrl.dump_done_cnt, u_vit.u_core.ctrl.dump_done_cnt_layer);

            result_save_case0(run_id);
            result_save_classifier_case0(run_id);

            // Clear done_sticky (CONTROL[4]=1) so the next run can complete cleanly
            axi_lite_write32(12'h000, 32'h0000_0010);

            // Sanity: ensure done_sticky is actually cleared before next run
            ctrl_reg = 0;
            for (int k = 0; k < 100; k++) begin
                axi_lite_read32(12'h000, ctrl_reg);
                if (ctrl_reg[1] == 1'b0) break;
                @(posedge clk);
            end

            repeat(50) @(posedge clk);
        end

        repeat(20) @(posedge clk);
        $finish;
    end

    // --------------------------
    // Timeout watchdog (prevents silent deadlock)
    //   +TIMEOUT_CYCLES=<int>  (default: 8,000,000 cycles)
    // --------------------------
    int unsigned timeout_cycles;
    initial begin : WD
        int unsigned watch_cnt;
        int          watch_run;

        timeout_cycles = 80_000_000; // updated for ENC_BLKS=12
        void'($value$plusargs("TIMEOUT_CYCLES=%d", timeout_cycles));

        watch_cnt = 0;
        watch_run = 0;

        wait(aresetn);

        // Watch each run independently without blocking long enough to miss the next start pulse.
        forever begin
            @(posedge clk);

            if (watch_run >= 2) begin
                disable WD;
            end

            // Arm on TB 'start' marker (held for multiple cycles around the AXI-Lite start write)
            if ((watch_cnt == 0) && (start == 1'b1) && (done_latched[watch_run] == 1'b0)) begin
                watch_cnt = 1; // start counting from next cycle
            end else if (watch_cnt != 0) begin
                // Done observed for this run?
                if (done_latched[watch_run]) begin
                    watch_cnt = 0;
                    watch_run = watch_run + 1;
                end else begin
                    watch_cnt = watch_cnt + 1;
                    if (watch_cnt >= timeout_cycles) begin
                        $fatal(1, "[TB][TIMEOUT] run%0d not completed within %0d cycles (check for FSM deadlock under stalls)",
                               watch_run, timeout_cycles);
                    end
                end
            end
        end
    end

    // --------------------------
    // DDR init/save
    // --------------------------
    task automatic dram_init_case0_min();
        int load_w_words, load_in_words, load_p_words, load_q_words;

// STACKED layout (must match addr_map.vh used by RTL)
//   WEIGHT = PATCH + ENC_BLKS * ENC_BLK
//   PARAM  = PATCH + ENC_BLKS * ENC_BLK
load_w_words  = SIZE_W_PATCH_WGT + (ENC_BLKS * SIZE_W_ENC_BLK) + SIZE_W_CLS_ALL;
load_in_words = 5383; // patch input full size: 7*769
load_p_words  = 12 + (ENC_BLKS * 108) + (6 * 12); // + CLS bias: 6 layers * 12 words
load_q_words  = (ENC_BLKS * 16) + 16; // + CLS quant block: 16 words (layer_id 0..15)


        DDR.load_to_mem({`BASE_PATH, "/case0/vector/weight256.txt"},
                        WEIGHT_BASE, WEIGHT_BASE + load_w_words*WORD_BYTES);

        DDR.load_to_mem({`BASE_PATH, "/case0/vector/input256.txt"},
                        INPUT_BASE,  INPUT_BASE  + load_in_words*WORD_BYTES);

        DDR.load_to_mem({`BASE_PATH, "/case0/vector/parameter256.txt"},
                        PARAMETER_BASE,  PARAMETER_BASE + load_p_words*WORD_BYTES);
        DDR.load_to_mem({`BASE_PATH, "/case0/vector/quant256.txt"},
                        QUANT_BASE,  QUANT_BASE + load_q_words*WORD_BYTES);
    endtask

    
task automatic result_save_case0(input int run_id);
    string fn;
    logic [31:0] base_addr;
    logic [31:0] end_addr;

    // Save residual stack slots (slot0 = PATCH, slot(b+1) = FC2 out of block b)
    for (int s = 0; s <= ENC_BLKS; s++) begin
        base_addr = OUTPUT_BASE + (s * RESID_WORDS * WORD_BYTES);
        end_addr  = base_addr + (RESID_WORDS * WORD_BYTES);

        if (s == 0) begin
            fn = $sformatf("%s/case0/sim_result/residual00_patch_out_vit256_run%0d.txt", `BASE_PATH, run_id);
        end else begin
            fn = $sformatf("%s/case0/sim_result/residual%02d_fc2_out_blk%02d_vit256_run%0d.txt",
                           `BASE_PATH, s, (s-1), run_id);
        end

        $display("[%0t] Save RESID slot%0d: [0x%08x, 0x%08x) words=%0d -> %s",
                 $time, s, base_addr, end_addr, RESID_WORDS, fn);
        DDR.save_to_file(fn, base_addr, end_addr);
    end
endtask


// --------------------------
// Classifier output dump (i8 packed lanes, lane0=CLS only)
// - Saves DDR region written by CLS0..CLS5 layers
//   CLS0..CLS4: 192 words each (6 nblk * 32 cols)
//   CLS5      :  64 words     (2 nblk * 32 cols)  // padded to 1024 classes total
//
// Output format matches DDR.save_to_file: 1 line per 256b word (little-endian hex as stored)
// - Only lane0 is meaningful (writeback masks lane1..31 to 0 for classifier layers)
// - In CLS5, only the first 40 logits correspond to real classes if you use 1000-class model;
//   remaining 24 are padding.
// --------------------------
task automatic result_save_classifier_case0(input int run_id);
    string fn;
    logic [31:0] base_addr;
    logic [31:0] end_addr;

    logic [31:0] cls_base;
    cls_base = OUTPUT_BASE + (RESID_STACK_WORDS * WORD_BYTES); // == OFF_OUT_ENC_ALL_END in addr_map

    // CLS0..CLS4 (192 words each)
    for (int g = 0; g < 5; g++) begin
        base_addr = cls_base + (g * 192 * WORD_BYTES);
        end_addr  = base_addr + (192 * WORD_BYTES);
        fn = $sformatf("%s/case0/sim_result/output256_cls%0d_final_rtl_run%0d.txt", `BASE_PATH, g, run_id);

        $display("[%0t] Save CLS%0d OUT: [0x%08x, 0x%08x) words=%0d -> %s",
                 $time, g, base_addr, end_addr, 192, fn);
        DDR.save_to_file(fn, base_addr, end_addr);
    end

    // CLS5 (64 words)
    base_addr = cls_base + (5 * 192 * WORD_BYTES);
    end_addr  = base_addr + (64 * WORD_BYTES);
    fn = $sformatf("%s/case0/sim_result/output256_cls5_final_rtl_run%0d.txt", `BASE_PATH, run_id);

    $display("[%0t] Save CLS5 OUT: [0x%08x, 0x%08x) words=%0d -> %s",
             $time, base_addr, end_addr, 64, fn);
    DDR.save_to_file(fn, base_addr, end_addr);
endtask






    
    // --------------------------
    // FC1 PE (pre-writeback) dump (i32, 1024b per output column)
    // - Captures u_vit.u_core.pe_out_col_data_flat during layer=FC1
    // - Output data width: 32 lanes * 32b = 1024b => 256 hex chars per line
    //
    // Plusargs:
    //   +DUMP_FC1_BLK=<int>         (default: 1)  encoder block index to dump
    //   +DUMP_FC1_PE_WTILE=<int>    (optional) dump only this FC1 wtile (0..23). If absent => all
    // --------------------------
    localparam logic [3:0] L_MLP_FC1 = 4'd7;

    integer fh_fc1_prewb;
    integer fh_fc1_prewb_addr;

    int dump_fc1_blk;
    int dump_fc1_pe_wtile; // -1 => all

    int unsigned cnt_fc1_prewb;
    int unsigned cnt_fc1_prewb_addr;

    initial begin : OPEN_FC1_PE_DUMP
        string fn;
        dump_fc1_blk      = 1;
        dump_fc1_pe_wtile = -1;

        void'($value$plusargs("DUMP_FC1_BLK=%d", dump_fc1_blk));
        void'($value$plusargs("DUMP_FC1_PE_WTILE=%d", dump_fc1_pe_wtile));

        fn = $sformatf("%s/case0/sim_result/peout1024_fc1_blk%02d_prewb_i32_rtl.txt", `BASE_PATH, dump_fc1_blk);
        fh_fc1_prewb = $fopen(fn, "w");
        if (fh_fc1_prewb == 0) $display("[TB][WARN] failed to open %s", fn);

        fn = $sformatf("%s/case0/sim_result/peout1024_fc1_blk%02d_prewb_i32_rtl_addr.txt", `BASE_PATH, dump_fc1_blk);
        fh_fc1_prewb_addr = $fopen(fn, "w");
        if (fh_fc1_prewb_addr == 0) $display("[TB][WARN] failed to open %s", fn);

        cnt_fc1_prewb      = 0;
        cnt_fc1_prewb_addr = 0;
    end

    // Sniff FC1 pre-writeback i32 stream (pe_out_col_data_flat, 1024b per output column)
    always @(posedge clk) begin
        if (aresetn) begin
            if (u_vit.u_core.pe_out_col_valid && u_vit.u_core.pe_out_col_ready &&
                (u_vit.u_core.ctrl.enc_blk_idx == dump_fc1_blk) &&
                (u_vit.u_core.ctrl.layer_id == L_MLP_FC1)) begin

                int unsigned wtile_u;
                wtile_u = u_vit.u_core.ctrl.wb_ktile_idx;

                if ((dump_fc1_pe_wtile < 0) || (wtile_u == dump_fc1_pe_wtile)) begin
                    if (fh_fc1_prewb) $fdisplay(fh_fc1_prewb, "%0256h", u_vit.u_core.pe_out_col_data_flat);

                    if (fh_fc1_prewb_addr) begin
                        // meta: wtile / nblk / mblk / col_idx / enc_blk / data
                        $fdisplay(fh_fc1_prewb_addr,
                                  "%0d %0d %0d %0d %0d %0256h",
                                  u_vit.u_core.ctrl.wb_ktile_idx,
                                  u_vit.u_core.ctrl.wb_nblk_idx,
                                  u_vit.u_core.ctrl.wb_mblk_idx,
                                  u_vit.u_core.pe_out_col_idx,
                                  u_vit.u_core.ctrl.enc_blk_idx,
                                  u_vit.u_core.pe_out_col_data_flat);
                    end

                    cnt_fc1_prewb      = cnt_fc1_prewb + 1;
                    cnt_fc1_prewb_addr = cnt_fc1_prewb_addr + 1;
                end
            end
        end
    end

    initial begin : CLOSE_FC1_PE_DUMP
        wait(done);
        #50;
        if (fh_fc1_prewb) $fclose(fh_fc1_prewb);
        if (fh_fc1_prewb_addr) $fclose(fh_fc1_prewb_addr);

        $display("[TB] FC1 PE dump done: cnt=%0d (meta=%0d), blk=%0d, wtile_filter=%0d",
                 cnt_fc1_prewb, cnt_fc1_prewb_addr, dump_fc1_blk, dump_fc1_pe_wtile);
    end

endmodule


// ============================================================================
// AXI latency / stall inserter (simulation-only)
// - Inserts randomized bubbles on each AXI channel while remaining AXI-compliant
// - Designed for checking FSM robustness under slow/variable DDR
//
// Plusargs:
//   +SLOW_MEM
//   +AXI_SEED=<int>
//   +AW_STALL_MAX=<int> +W_STALL_MAX=<int> +B_STALL_MAX=<int>
//   +AR_STALL_MAX=<int> +R_STALL_MAX=<int>
// ============================================================================
module axi_latency_inserter #(
    parameter int AXI_ID_WIDTH   = 1,
    parameter int AXI_ADDR_WIDTH = 32,
    parameter int AXI_DATA_WIDTH = 256
)(
    input  wire ACLK,
    input  wire ARESETN,
    axi_if s_axi,
    axi_if m_axi
);
    // --------------------------
    // PRNG (deterministic)
    // --------------------------
    int unsigned seed;
    function automatic int unsigned prng_next(inout int unsigned s);
        s = (s * 32'd1103515245) + 32'd12345;
        return s;
    endfunction
    function automatic int unsigned rand_range(inout int unsigned s, int unsigned maxv);
        int unsigned v;
        v = prng_next(s);
        if (maxv == 0) rand_range = 0;
        else          rand_range = (v % (maxv + 1));
    endfunction

    // --------------------------
    // Config via plusargs
    // --------------------------
    // --------------------------
    // Config via plusargs (captured once in initial, then latched on reset)
    // --------------------------
    bit slow_mem;
    int unsigned seed_cfg;
    int unsigned aw_max, w_max, b_max, ar_max, r_max;
    int unsigned aw_max_cfg, w_max_cfg, b_max_cfg, ar_max_cfg, r_max_cfg;

    initial begin
        slow_mem = $test$plusargs("SLOW_MEM");

        // defaults
        seed_cfg = 32'd1;
        void'($value$plusargs("AXI_SEED=%d", seed_cfg));

        aw_max_cfg = 0; w_max_cfg = 0; b_max_cfg = 0; ar_max_cfg = 0; r_max_cfg = 0;
        if (0) begin
            aw_max_cfg = 20;
            ar_max_cfg = 20;
            w_max_cfg  = 8;
            r_max_cfg  = 8;
            b_max_cfg  = 30;
        end
        void'($value$plusargs("AW_STALL_MAX=%d", aw_max_cfg));
        void'($value$plusargs("AR_STALL_MAX=%d", ar_max_cfg));
        void'($value$plusargs("W_STALL_MAX=%d",  w_max_cfg));
        void'($value$plusargs("R_STALL_MAX=%d",  r_max_cfg));
        void'($value$plusargs("B_STALL_MAX=%d",  b_max_cfg));

        $display("[AXI_SLOW] slow_mem=%0d seed=%0d AW=%0d AR=%0d W=%0d R=%0d B=%0d",
                 slow_mem, seed_cfg, aw_max_cfg, ar_max_cfg, w_max_cfg, r_max_cfg, b_max_cfg);
    end


    // --------------------------
    // Default pass-through of payload fields
    // (VALID/READY are controlled by the state machines below)
    // --------------------------
    // AW
    assign m_axi.AWID    = s_axi.AWID;
    assign m_axi.AWADDR  = s_axi.AWADDR;
    assign m_axi.AWLEN   = s_axi.AWLEN;
    assign m_axi.AWSIZE  = s_axi.AWSIZE;
    assign m_axi.AWBURST = s_axi.AWBURST;
    assign m_axi.AWLOCK  = s_axi.AWLOCK;
    assign m_axi.AWCACHE = s_axi.AWCACHE;
    assign m_axi.AWPROT  = s_axi.AWPROT;
    assign m_axi.AWQOS   = s_axi.AWQOS;

    // W
    assign m_axi.WDATA = s_axi.WDATA;
    assign m_axi.WSTRB = s_axi.WSTRB;
    assign m_axi.WLAST = s_axi.WLAST;

    // AR
    assign m_axi.ARID    = s_axi.ARID;
    assign m_axi.ARADDR  = s_axi.ARADDR;
    assign m_axi.ARLEN   = s_axi.ARLEN;
    assign m_axi.ARSIZE  = s_axi.ARSIZE;
    assign m_axi.ARBURST = s_axi.ARBURST;
    assign m_axi.ARLOCK  = s_axi.ARLOCK;
    assign m_axi.ARCACHE = s_axi.ARCACHE;
    assign m_axi.ARPROT  = s_axi.ARPROT;
    assign m_axi.ARQOS   = s_axi.ARQOS;

    // R/B payload back
    assign s_axi.RID   = m_axi.RID;
    assign s_axi.RDATA = m_axi.RDATA;
    assign s_axi.RRESP = m_axi.RRESP;
    assign s_axi.RLAST = m_axi.RLAST;

    assign s_axi.BID   = m_axi.BID;
    assign s_axi.BRESP = m_axi.BRESP;

    // --------------------------
    // Channel control state
    // permit=1 => pass-through VALID/READY for that channel
    // permit=0 => hold off (VALID=0 or READY=0) until random delay expires
    // --------------------------
    logic aw_permit, aw_waiting;
    int unsigned aw_delay;
    logic ar_permit, ar_waiting;
    int unsigned ar_delay;
    logic w_permit,  w_waiting;
    int unsigned w_delay;
    logic r_permit,  r_waiting;
    int unsigned r_delay;
    logic b_permit,  b_waiting;
    int unsigned b_delay;

    // --------------------------
    // Combinational VALID/READY gating
    // --------------------------
    // AW
    assign m_axi.AWVALID = (aw_permit) ? s_axi.AWVALID : 1'b0;
    assign s_axi.AWREADY = (aw_permit) ? m_axi.AWREADY : 1'b0;

    // W
    assign m_axi.WVALID = (w_permit) ? s_axi.WVALID : 1'b0;
    assign s_axi.WREADY = (w_permit) ? m_axi.WREADY : 1'b0;

    // AR
    assign m_axi.ARVALID = (ar_permit) ? s_axi.ARVALID : 1'b0;
    assign s_axi.ARREADY = (ar_permit) ? m_axi.ARREADY : 1'b0;

    // R (response)
    assign s_axi.RVALID = (r_permit) ? m_axi.RVALID : 1'b0;
    assign m_axi.RREADY = (r_permit) ? s_axi.RREADY : 1'b0;

    // B (response)
    assign s_axi.BVALID = (b_permit) ? m_axi.BVALID : 1'b0;
    assign m_axi.BREADY = (b_permit) ? s_axi.BREADY : 1'b0;

    // --------------------------
    // Sequential control
    // --------------------------
    always_ff @(posedge ACLK) begin
        if (!ARESETN) begin
            // Latch runtime cfg on reset (prevents multi-procedural drivers in xsim/VRFC)
            seed   <= seed_cfg;
            aw_max <= aw_max_cfg;
            ar_max <= ar_max_cfg;
            w_max  <= w_max_cfg;
            r_max  <= r_max_cfg;
            b_max  <= b_max_cfg;
            aw_permit  <= 1'b1;  aw_waiting <= 1'b0; aw_delay <= 0;
            ar_permit  <= 1'b1;  ar_waiting <= 1'b0; ar_delay <= 0;
            w_permit   <= 1'b1;  w_waiting  <= 1'b0; w_delay  <= 0;
            r_permit   <= 1'b1;  r_waiting  <= 1'b0; r_delay  <= 0;
            b_permit   <= 1'b1;  b_waiting  <= 1'b0; b_delay  <= 0;
        end else begin
            // ---------------- AW ----------------
            if (aw_max > 0) begin
                if (!aw_permit) begin
                    if (!aw_waiting) begin
                        if (s_axi.AWVALID) begin
                            aw_waiting <= 1'b1;
                            aw_delay   <= rand_range(seed, aw_max);
                        end
                    end else begin
                        if (!s_axi.AWVALID) begin
                            aw_waiting <= 1'b0;
                            aw_delay   <= 0;
                        end else if (aw_delay == 0) begin
                            aw_permit  <= 1'b1;
                            aw_waiting <= 1'b0;
                        end else begin
                            aw_delay <= aw_delay - 1;
                        end
                    end
                end else begin
                    // permit=1: pass-through until handshake then drop permit
                    if (s_axi.AWVALID && m_axi.AWREADY) begin
                        aw_permit  <= 1'b0;
                        aw_waiting <= 1'b0;
                        aw_delay   <= 0;
                    end
                end
            end

            // ---------------- AR ----------------
            if (ar_max > 0) begin
                if (!ar_permit) begin
                    if (!ar_waiting) begin
                        if (s_axi.ARVALID) begin
                            ar_waiting <= 1'b1;
                            ar_delay   <= rand_range(seed, ar_max);
                        end
                    end else begin
                        if (!s_axi.ARVALID) begin
                            ar_waiting <= 1'b0;
                            ar_delay   <= 0;
                        end else if (ar_delay == 0) begin
                            ar_permit  <= 1'b1;
                            ar_waiting <= 1'b0;
                        end else begin
                            ar_delay <= ar_delay - 1;
                        end
                    end
                end else begin
                    if (s_axi.ARVALID && m_axi.ARREADY) begin
                        ar_permit  <= 1'b0;
                        ar_waiting <= 1'b0;
                        ar_delay   <= 0;
                    end
                end
            end

            // ---------------- W (per-beat) ----------------
            if (w_max > 0) begin
                if (!w_permit) begin
                    if (!w_waiting) begin
                        if (s_axi.WVALID) begin
                            w_waiting <= 1'b1;
                            w_delay   <= rand_range(seed, w_max);
                        end
                    end else begin
                        if (!s_axi.WVALID) begin
                            w_waiting <= 1'b0;
                            w_delay   <= 0;
                        end else if (w_delay == 0) begin
                            w_permit  <= 1'b1;
                            w_waiting <= 1'b0;
                        end else begin
                            w_delay <= w_delay - 1;
                        end
                    end
                end else begin
                    // After each accepted beat, drop permit to potentially insert bubbles
                    if (s_axi.WVALID && m_axi.WREADY) begin
                        w_permit  <= 1'b0;
                        w_waiting <= 1'b0;
                        w_delay   <= 0;
                    end
                end
            end

            // ---------------- R (per-beat response) ----------------
            if (r_max > 0) begin
                if (!r_permit) begin
                    if (!r_waiting) begin
                        if (m_axi.RVALID) begin
                            r_waiting <= 1'b1;
                            r_delay   <= rand_range(seed, r_max);
                        end
                    end else begin
                        if (!m_axi.RVALID) begin
                            r_waiting <= 1'b0;
                            r_delay   <= 0;
                        end else if (r_delay == 0) begin
                            r_permit  <= 1'b1;
                            r_waiting <= 1'b0;
                        end else begin
                            r_delay <= r_delay - 1;
                        end
                    end
                end else begin
                    // After beat is accepted by master, drop permit
                    if (m_axi.RVALID && s_axi.RREADY) begin
                        r_permit  <= 1'b0;
                        r_waiting <= 1'b0;
                        r_delay   <= 0;
                    end
                end
            end

            // ---------------- B (write response) ----------------
            if (b_max > 0) begin
                if (!b_permit) begin
                    if (!b_waiting) begin
                        if (m_axi.BVALID) begin
                            b_waiting <= 1'b1;
                            b_delay   <= rand_range(seed, b_max);
                        end
                    end else begin
                        if (!m_axi.BVALID) begin
                            b_waiting <= 1'b0;
                            b_delay   <= 0;
                        end else if (b_delay == 0) begin
                            b_permit  <= 1'b1;
                            b_waiting <= 1'b0;
                        end else begin
                            b_delay <= b_delay - 1;
                        end
                    end
                end else begin
                    if (m_axi.BVALID && s_axi.BREADY) begin
                        b_permit  <= 1'b0;
                        b_waiting <= 1'b0;
                        b_delay   <= 0;
                    end
                end
            end

            // If max==0 for a channel, keep permit asserted (no throttling)
            if (aw_max == 0) aw_permit <= 1'b1;
            if (ar_max == 0) ar_permit <= 1'b1;
            if (w_max  == 0) w_permit  <= 1'b1;
            if (r_max  == 0) r_permit  <= 1'b1;
            if (b_max  == 0) b_permit  <= 1'b1;
        end
    end
endmodule

`default_nettype wire
// ============================================================================
// FC1 SCOREBUF dump monitor (simulation-only)
// - Captures FC1 output that is written into SCOREBUF via writeback_controller
// - Stores per-ktile (w0..w23) snapshots to avoid overwrite, and flushes at done
//
// Plusargs:
//   +DUMP_FC1_BLK=<int>   (default: 1)
//   +DUMP_FC1_NOSPLIT     (if set: do not create per-wtile files, only stream+meta)
// ============================================================================
module wb_fc1_scorebuf_dump (
    input  wire         clk,
    input  wire         nRst,
    input  wire [3:0]   layer_id,
    input  wire [4:0]   ktile_idx,
    input  wire [2:0]   nblk_idx,
    input  wire [2:0]   mblk_idx,
    input  wire [4:0]   col_in_blk,

    input  wire         score_wr_valid,
    input  wire         score_wr_bank,
    input  wire [10:0]  score_wr_addr,
    input  wire [255:0] score_wr_data
);
    localparam [3:0] L_MLP_FC1 = 4'd7;

    // FC1 writes 7(mblk) x 32(col) = 224 words per output-tile(w)
    localparam int FC1_WORDS_PER_WTILE = (7*32);
    localparam int FC1_MAX_WTILES      = 24;

    // Per-wtile snapshot buffers (prevent overwrite)
    logic [255:0] fc1_buf     [0:FC1_MAX_WTILES-1][0:FC1_WORDS_PER_WTILE-1];
    logic         fc1_buf_vld [0:FC1_MAX_WTILES-1][0:FC1_WORDS_PER_WTILE-1];

    integer fh_stream;
    integer fh_stream_meta;
    integer fh_wtile      [0:FC1_MAX_WTILES-1];
    integer fh_wtile_addr [0:FC1_MAX_WTILES-1];

    int dump_blk;
    bit nosplit;

    // Open files
    initial begin : FC1_OPEN
        string fn;
        dump_blk = 1;
        void'($value$plusargs("DUMP_FC1_BLK=%d", dump_blk));
        nosplit = $test$plusargs("DUMP_FC1_NOSPLIT");

        // Stream (write-order) dump
        fn = $sformatf("%s/case0/sim_result/fc1_blk%02d_scorebuf_stream_vit256.txt", `BASE_PATH, dump_blk);
        fh_stream = $fopen(fn, "w");
        if (fh_stream == 0) $display("[TB][WARN] failed to open %s", fn);

        // Stream+meta dump: blk, wtile, (ktile/nblk/mblk/col), bank, addr, data
        fn = $sformatf("%s/case0/sim_result/fc1_blk%02d_scorebuf_stream_meta.txt", `BASE_PATH, dump_blk);
        fh_stream_meta = $fopen(fn, "w");
        if (fh_stream_meta == 0) $display("[TB][WARN] failed to open %s", fn);

        // Init buffers
        for (int w = 0; w < FC1_MAX_WTILES; w++) begin
            for (int a = 0; a < FC1_WORDS_PER_WTILE; a++) begin
                fc1_buf[w][a] = 0;
                fc1_buf_vld[w][a] = 1'b0;
            end
        end

        // Per-wtile files (address-order) dumps
        for (int w = 0; w < FC1_MAX_WTILES; w++) begin
            fh_wtile[w] = 0;
            fh_wtile_addr[w] = 0;
            if (!nosplit) begin
                fn = $sformatf("%s/case0/sim_result/fc1_blk%02d_w%02d_scorebuf_vit256.txt", `BASE_PATH, dump_blk, w);
                fh_wtile[w] = $fopen(fn, "w");
                if (fh_wtile[w] == 0) $display("[TB][WARN] failed to open %s", fn);

                fn = $sformatf("%s/case0/sim_result/fc1_blk%02d_w%02d_scorebuf_addr_vit256.txt", `BASE_PATH, dump_blk, w);
                fh_wtile_addr[w] = $fopen(fn, "w");
                if (fh_wtile_addr[w] == 0) $display("[TB][WARN] failed to open %s", fn);
            end
        end
    end

    // Capture FC1 SCOREBUF writes
    always @(posedge clk) begin
        if (nRst) begin
            if ((layer_id == L_MLP_FC1) && score_wr_valid) begin
                // Filter by encoder block (use tb_vit_slow's controller view)
                if ($root.tb_vit_slow.u_vit.u_core.ctrl.enc_blk_idx == dump_blk) begin
                    int unsigned w;
                    int unsigned a;
                    w = ktile_idx;
                    a = score_wr_addr;

                    if (fh_stream) $fdisplay(fh_stream, "%064h", score_wr_data);
                    if (fh_stream_meta) begin
                        $fdisplay(fh_stream_meta,
                                  "%0d %0d %0d %0d %0d %0d %0d %0d %064h",
                                  dump_blk, w,
                                  ktile_idx, nblk_idx, mblk_idx, col_in_blk,
                                  score_wr_bank, a, score_wr_data);
                    end

                    // Snapshot per wtile (only if within expected range)
                    if ((w < FC1_MAX_WTILES) && (a < FC1_WORDS_PER_WTILE)) begin
                        fc1_buf[w][a]     <= score_wr_data;
                        fc1_buf_vld[w][a] <= 1'b1;
                    end
                end
            end
        end
    end

    // Flush per-wtile snapshots at DONE
    initial begin : FC1_FLUSH
        wait($root.tb_vit_slow.done);
        #50;
        if (!nosplit) begin
            for (int w = 0; w < FC1_MAX_WTILES; w++) begin
                for (int a = 0; a < FC1_WORDS_PER_WTILE; a++) begin
                    if (fc1_buf_vld[w][a]) begin
                        logic [255:0] d;
                        d = fc1_buf[w][a];
                        if (fh_wtile[w]) $fdisplay(fh_wtile[w], "%064h", d);
                        if (fh_wtile_addr[w]) $fdisplay(fh_wtile_addr[w], "%0d %064h", a, d);
                    end
                end
            end
        end

        if (fh_stream) $fclose(fh_stream);
        if (fh_stream_meta) $fclose(fh_stream_meta);
        if (!nosplit) begin
            for (int w = 0; w < FC1_MAX_WTILES; w++) begin
                if (fh_wtile[w]) $fclose(fh_wtile[w]);
                if (fh_wtile_addr[w]) $fclose(fh_wtile_addr[w]);
            end
        end
    end

endmodule

// Bind monitor into ALL writeback_controller instances
bind writeback_controller wb_fc1_scorebuf_dump u_wb_fc1_scorebuf_dump (.*);