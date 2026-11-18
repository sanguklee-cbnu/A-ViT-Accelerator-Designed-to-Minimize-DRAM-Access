`timescale 1ns/1ps
`default_nettype none

// AXI4-Lite control wrapper for ViT core
//  - start/done via AXI-Lite registers (start is latched internally, done is sticky)
//  - BASE_* addresses configurable at runtime (absolute byte address; internally converted to 256b word index)
//
// Notes:
//  - All base addresses are interpreted as absolute DDR byte addresses.
//  - Addresses are internally 32B-aligned (AXI_DATA_WIDTH=256 -> 32 bytes).
//  - Writes to configuration regs while busy are ignored (to avoid mid-run address change).
module vit_axi_top #(
    parameter integer AXI_ID_WIDTH   = 1,
    parameter integer AXI_ADDR_WIDTH = 32,
    parameter integer AXI_DATA_WIDTH = 256,
    parameter integer ADDR_LSB       = $clog2(AXI_DATA_WIDTH/8),

    // AXI-Lite
    parameter integer S_AXI_ADDR_WIDTH = 12,
    parameter integer S_AXI_DATA_WIDTH = 32,

    // DDR base used by AXI_Master inside vit_core
    parameter [AXI_ADDR_WIDTH-1:0] DDR_TARGET_SLAVE_BASE_ADDR = 32'h0000_0000,

    // Default base absolute addresses
    parameter [AXI_ADDR_WIDTH-1:0] BASE_W_ADDR_RESET   = 32'h1000_0000,
    parameter [AXI_ADDR_WIDTH-1:0] BASE_IN_ADDR_RESET  = 32'h1100_0000,
    parameter [AXI_ADDR_WIDTH-1:0] BASE_Q_ADDR_RESET   = 32'h1200_0000,
    parameter [AXI_ADDR_WIDTH-1:0] BASE_B_ADDR_RESET   = 32'h1300_0000,
    parameter [AXI_ADDR_WIDTH-1:0] BASE_OUT_ADDR_RESET = 32'h1400_0000
)(
    input  wire clk,
    input  wire aresetn,

    // ========= AXI4-Lite Slave (control) =========
    input  wire [S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,

    input  wire [S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,

    output wire [1:0]                  s_axi_bresp,
    output wire                        s_axi_bvalid,
    input  wire                        s_axi_bready,

    input  wire [S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,

    output wire [S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0]                  s_axi_rresp,
    output wire                        s_axi_rvalid,
    input  wire                        s_axi_rready,

    // ========= AXI Master Interface (DDR) =========
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

    // ------------------------------------------------------------
    // AXI-Lite minimal register file
    // ------------------------------------------------------------
    localparam [11:0] REG_CONTROL     = 12'h000;
    localparam [11:0] REG_BASE_W_ADDR = 12'h010;
    localparam [11:0] REG_BASE_IN    = 12'h014;
    localparam [11:0] REG_BASE_Q     = 12'h018;
    localparam [11:0] REG_BASE_B     = 12'h01C;
    localparam [11:0] REG_BASE_OUT   = 12'h020;
    localparam [11:0] REG_CYC_LO     = 12'h024; // RO: cycle counter (low 32)
    localparam [11:0] REG_CYC_HI     = 12'h028; // RO: cycle counter (high 32)
    localparam [11:0] REG_CYC_STAT   = 12'h02C; // RO: [2]=valid, [1]=running

    localparam [11:0] REG_VERSION    = 12'h0FC;

    // AXI-Lite write channel holding regs
    reg                         aw_holding;
    reg [S_AXI_ADDR_WIDTH-1:0]  awaddr_r;

    reg                         w_holding;
    reg [S_AXI_DATA_WIDTH-1:0]  wdata_r;
    reg [S_AXI_DATA_WIDTH/8-1:0] wstrb_r;

    reg                         bvalid_r;
    reg [1:0]                   bresp_r;

    // AXI-Lite read channel regs
    reg                         rvalid_r;
    reg [S_AXI_DATA_WIDTH-1:0]  rdata_r;
    reg [1:0]                   rresp_r;

    assign s_axi_awready = (!aw_holding) && (!bvalid_r);
    assign s_axi_wready  = (!w_holding)  && (!bvalid_r);

    assign s_axi_bvalid  = bvalid_r;
    assign s_axi_bresp   = bresp_r;

    assign s_axi_arready = (!rvalid_r);
    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rdata   = rdata_r;
    assign s_axi_rresp   = rresp_r;

    wire aw_fire = s_axi_awvalid && s_axi_awready;
    wire w_fire  = s_axi_wvalid  && s_axi_wready;

    // Commit write when both address+data are captured and no response pending
    wire wr_commit = aw_holding && w_holding && (!bvalid_r);
    wire [11:0] wr_addr_aligned = {awaddr_r[11:2], 2'b00};

    wire sw_start_pulse    = wr_commit && (wr_addr_aligned == REG_CONTROL) && wdata_r[0];
    wire sw_done_clr_pulse = wr_commit && (wr_addr_aligned == REG_CONTROL) && wdata_r[4];
    wire sw_start_accept   = sw_start_pulse && (!busy);


    // ------------------------------------------------------------
    // Control + config regs
    // ------------------------------------------------------------
    reg start_latched;
    reg done_sticky;
    reg busy;

    // ------------------------------------------------------------
    // Start->Done cycle counter (latched)
    //  - timer_cnt counts clk cycles while running
    //  - timer_latched captures timer_cnt at core_done_pulse
    //  - value is held until next completion (or reset)
    // ------------------------------------------------------------
    reg        timer_running;
    reg        timer_valid;
    reg [63:0] timer_cnt;
    reg [63:0] timer_latched;
    wire [63:0] timer_ro = timer_running ? timer_cnt : timer_latched;

    reg auto_restart; // optional (not used yet; reserved)

    reg [AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_w_word_reg;
    reg [AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_in_word_reg;
    reg [AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_q_word_reg;
    reg [AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_b_word_reg;
    reg [AXI_ADDR_WIDTH-ADDR_LSB-1:0] base_out_word_reg;

    // Convert absolute address -> word index relative to DDR_TARGET_SLAVE_BASE_ADDR
    function [AXI_ADDR_WIDTH-ADDR_LSB-1:0] addr_to_word;
        input [AXI_ADDR_WIDTH-1:0] abs_addr;
        reg   [AXI_ADDR_WIDTH-1:0] aligned;
        begin
                        aligned = {abs_addr[AXI_ADDR_WIDTH-1:ADDR_LSB], {ADDR_LSB{1'b0}}};
            if (aligned < DDR_TARGET_SLAVE_BASE_ADDR)
                addr_to_word = 0;
            else
                addr_to_word = (aligned - DDR_TARGET_SLAVE_BASE_ADDR) >> ADDR_LSB;
        end
    endfunction

    function [AXI_ADDR_WIDTH-1:0] word_to_addr;
        input [AXI_ADDR_WIDTH-ADDR_LSB-1:0] word_idx;
        begin
            word_to_addr = DDR_TARGET_SLAVE_BASE_ADDR + ({{(ADDR_LSB){1'b0}}, word_idx} << ADDR_LSB);
        end
    endfunction
    // write side decoded pulses (combinational)
    // ------------------------------------------------------------
    // vit_core instance
    // ------------------------------------------------------------
    wire core_done;
    wire core_start = start_latched;
    reg  core_done_d;
    wire core_done_pulse = core_done && !core_done_d; // rising-edge detect of core done

    vit #(
        .AXI_ID_WIDTH  (AXI_ID_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .ADDR_LSB      (ADDR_LSB),
        .DDR_TARGET_SLAVE_BASE_ADDR(DDR_TARGET_SLAVE_BASE_ADDR)
    ) u_core (
        .clk(clk),
        .aresetn(aresetn),

        .start(core_start),
        .done (core_done),

        .base_w_word  (base_w_word_reg),
        .base_in_word (base_in_word_reg),
        .base_q_word  (base_q_word_reg),
        .base_b_word  (base_b_word_reg),
        .base_out_word(base_out_word_reg),

        .m00_axi_awid   (m00_axi_awid),
        .m00_axi_awaddr (m00_axi_awaddr),
        .m00_axi_awlen  (m00_axi_awlen),
        .m00_axi_awsize (m00_axi_awsize),
        .m00_axi_awburst(m00_axi_awburst),
        .m00_axi_awlock (m00_axi_awlock),
        .m00_axi_awcache(m00_axi_awcache),
        .m00_axi_awprot (m00_axi_awprot),
        .m00_axi_awqos  (m00_axi_awqos),
        .m00_axi_awvalid(m00_axi_awvalid),
        .m00_axi_awready(m00_axi_awready),

        .m00_axi_wdata (m00_axi_wdata),
        .m00_axi_wstrb (m00_axi_wstrb),
        .m00_axi_wlast (m00_axi_wlast),
        .m00_axi_wvalid(m00_axi_wvalid),
        .m00_axi_wready(m00_axi_wready),

        .m00_axi_bid   (m00_axi_bid),
        .m00_axi_bresp (m00_axi_bresp),
        .m00_axi_bvalid(m00_axi_bvalid),
        .m00_axi_bready(m00_axi_bready),

        .m00_axi_arid   (m00_axi_arid),
        .m00_axi_araddr (m00_axi_araddr),
        .m00_axi_arlen  (m00_axi_arlen),
        .m00_axi_arsize (m00_axi_arsize),
        .m00_axi_arburst(m00_axi_arburst),
        .m00_axi_arlock (m00_axi_arlock),
        .m00_axi_arcache(m00_axi_arcache),
        .m00_axi_arprot (m00_axi_arprot),
        .m00_axi_arqos  (m00_axi_arqos),
        .m00_axi_arvalid(m00_axi_arvalid),
        .m00_axi_arready(m00_axi_arready),

        .m00_axi_rid   (m00_axi_rid),
        .m00_axi_rdata (m00_axi_rdata),
        .m00_axi_rresp (m00_axi_rresp),
        .m00_axi_rlast (m00_axi_rlast),
        .m00_axi_rvalid(m00_axi_rvalid),
        .m00_axi_rready(m00_axi_rready)
    );

    // ------------------------------------------------------------
    // Core control FSM (start latch + done sticky)
    // ------------------------------------------------------------
    always @(posedge clk) begin
        if (!aresetn) begin
            start_latched   <= 0;
            done_sticky     <= 0;
            busy            <= 0;
            core_done_d     <= 0;

            timer_running   <= 0;
            timer_valid     <= 0;
            timer_cnt       <= 0;
            timer_latched   <= 0;
        end else begin
            core_done_d <= core_done;

            // done sticky clear (does NOT clear timer_latched)
            if (sw_done_clr_pulse) begin
                done_sticky <= 0;
            end

            // Start accepted only when not busy
            if (sw_start_accept) begin
                start_latched <= 1;
                done_sticky   <= 0;
                busy          <= 1;

                // start timing window
                timer_running <= 1;
                timer_cnt     <= 0;
            end else if (timer_running) begin
                // count cycles while running
                timer_cnt <= timer_cnt + 1;
            end

            // When core enters DONE state, latch it and drop start so core can return to IDLE
            if (core_done_pulse) begin
                done_sticky   <= 1;
                start_latched <= 0;
                busy          <= 0;

                if (timer_running) begin
                    // include this cycle in the count
                    timer_latched <= timer_cnt + 1;
                    timer_valid   <= 1;
                    timer_running <= 0;
                end else begin
                    // fallback (shouldn't happen)
                    timer_latched <= timer_cnt;
                    timer_valid   <= 1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // AXI-Lite write channel
    // ------------------------------------------------------------
    always @(posedge clk) begin
        if (!aresetn) begin
            aw_holding <= 0;
            awaddr_r   <= 0;
            w_holding  <= 0;
            wdata_r    <= 0;
            wstrb_r    <= 0;

            bvalid_r   <= 0;
            bresp_r    <= 2'b00;
        end else begin
            // capture AW
            if (aw_fire) begin
                aw_holding <= 1;
                awaddr_r   <= s_axi_awaddr;
            end

            // capture W
            if (w_fire) begin
                w_holding <= 1;
                wdata_r   <= s_axi_wdata;
                wstrb_r   <= s_axi_wstrb;
            end

            // issue B when commit
            if (wr_commit) begin
                bvalid_r  <= 1;
                bresp_r   <= 2'b00; // OKAY
                aw_holding <= 0;
                w_holding  <= 0;
            end else if (bvalid_r && s_axi_bready) begin
                bvalid_r <= 0;
            end
        end
    end

    // ------------------------------------------------------------
    // Register write side effects (on wr_commit)
    // ------------------------------------------------------------
    // Apply WSTRB to a 32-bit register
    function [31:0] apply_wstrb32;
        input [31:0] oldv;
        input [31:0] newv;
        input [3:0]  strb;
        reg [31:0] v;
        begin
            v = oldv;
            if (strb[0]) v[7:0]   = newv[7:0];
            if (strb[1]) v[15:8]  = newv[15:8];
            if (strb[2]) v[23:16] = newv[23:16];
            if (strb[3]) v[31:24] = newv[31:24];
            apply_wstrb32 = v;
        end
    endfunction

    reg [31:0] waddr_abs_reg;
    reg [31:0] inaddr_abs_reg;
    reg [31:0] qaddr_abs_reg;
    reg [31:0] baddr_abs_reg;
    reg [31:0] outaddr_abs_reg;

    always @(posedge clk) begin
        if (!aresetn) begin
            auto_restart     <= 0;

            base_w_word_reg   <= (BASE_W_ADDR_RESET   - DDR_TARGET_SLAVE_BASE_ADDR) >> ADDR_LSB;
            base_in_word_reg  <= (BASE_IN_ADDR_RESET  - DDR_TARGET_SLAVE_BASE_ADDR) >> ADDR_LSB;
            base_q_word_reg   <= (BASE_Q_ADDR_RESET   - DDR_TARGET_SLAVE_BASE_ADDR) >> ADDR_LSB;
            base_b_word_reg   <= (BASE_B_ADDR_RESET   - DDR_TARGET_SLAVE_BASE_ADDR) >> ADDR_LSB;
            base_out_word_reg <= (BASE_OUT_ADDR_RESET - DDR_TARGET_SLAVE_BASE_ADDR) >> ADDR_LSB;

            waddr_abs_reg   <= BASE_W_ADDR_RESET;
            inaddr_abs_reg  <= BASE_IN_ADDR_RESET;
            qaddr_abs_reg   <= BASE_Q_ADDR_RESET;
            baddr_abs_reg   <= BASE_B_ADDR_RESET;
            outaddr_abs_reg <= BASE_OUT_ADDR_RESET;
        end else begin
            if (wr_commit) begin
                case (wr_addr_aligned)
                    REG_CONTROL: begin
                        // bit0: start (W1P)
                        // bit4: done_clear (W1P)
                        // bit7: auto_restart (RW, reserved)
                        auto_restart <= wdata_r[7];
                    end

                    REG_BASE_W_ADDR: begin
                        if (!busy) begin
                            waddr_abs_reg  <= apply_wstrb32(waddr_abs_reg, wdata_r, wstrb_r);
                            base_w_word_reg <= addr_to_word(apply_wstrb32(waddr_abs_reg, wdata_r, wstrb_r));
                        end
                    end
                    REG_BASE_IN: begin
                        if (!busy) begin
                            inaddr_abs_reg   <= apply_wstrb32(inaddr_abs_reg, wdata_r, wstrb_r);
                            base_in_word_reg <= addr_to_word(apply_wstrb32(inaddr_abs_reg, wdata_r, wstrb_r));
                        end
                    end
                    REG_BASE_Q: begin
                        if (!busy) begin
                            qaddr_abs_reg  <= apply_wstrb32(qaddr_abs_reg, wdata_r, wstrb_r);
                            base_q_word_reg <= addr_to_word(apply_wstrb32(qaddr_abs_reg, wdata_r, wstrb_r));
                        end
                    end
                    REG_BASE_B: begin
                        if (!busy) begin
                            baddr_abs_reg  <= apply_wstrb32(baddr_abs_reg, wdata_r, wstrb_r);
                            base_b_word_reg <= addr_to_word(apply_wstrb32(baddr_abs_reg, wdata_r, wstrb_r));
                        end
                    end
                    REG_BASE_OUT: begin
                        if (!busy) begin
                            outaddr_abs_reg  <= apply_wstrb32(outaddr_abs_reg, wdata_r, wstrb_r);
                            base_out_word_reg <= addr_to_word(apply_wstrb32(outaddr_abs_reg, wdata_r, wstrb_r));
                        end
                    end

                    default: begin
                        // no-op
                    end
                endcase
            end
        end
    end

    // ------------------------------------------------------------
    // AXI-Lite read channel
    // ------------------------------------------------------------
    wire ar_fire = s_axi_arvalid && s_axi_arready;
    wire [11:0] rd_addr_aligned = {s_axi_araddr[11:2], 2'b00};

    always @(posedge clk) begin
        if (!aresetn) begin
            rvalid_r <= 0;
            rdata_r  <= 0;
            rresp_r  <= 2'b00;
        end else begin
            if (ar_fire) begin
                rvalid_r <= 1;
                rresp_r  <= 2'b00; // OKAY
                case (rd_addr_aligned)
                    REG_CONTROL: begin
                        // [0] start_latched (RO)
                        // [1] done_sticky   (RO)
                        // [2] idle          (RO)
                        // [3] busy          (RO)
                        // [7] auto_restart  (RW)
                        rdata_r <= {24'd0,
                                   auto_restart,
                                   2'd0,
                                   busy,
                                   (!busy),
                                   done_sticky,
                                   start_latched};
                    end
                    REG_BASE_W_ADDR: rdata_r <= waddr_abs_reg;
                    REG_BASE_IN:     rdata_r <= inaddr_abs_reg;
                    REG_BASE_Q:      rdata_r <= qaddr_abs_reg;
                    REG_BASE_B:      rdata_r <= baddr_abs_reg;
                    REG_BASE_OUT:    rdata_r <= outaddr_abs_reg;

                    REG_CYC_LO:     rdata_r <= timer_ro[31:0];
                    REG_CYC_HI:     rdata_r <= timer_ro[63:32];
                    REG_CYC_STAT:   rdata_r <= {29'd0, timer_valid, timer_running, 1'b0};

                    REG_VERSION:     rdata_r <= 32'h0001_0000; // v1.0.0
                    default:         rdata_r <= 0;
                endcase
            end else if (rvalid_r && s_axi_rready) begin
                rvalid_r <= 0;
            end
        end
    end

endmodule

`default_nettype wire