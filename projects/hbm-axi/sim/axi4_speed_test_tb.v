`timescale 1 ns / 1 ps

module axi4_speed_test_tb;
    // Parameters
    parameter C_S00_AXI_DATA_WIDTH = 32;
    parameter C_S00_AXI_ADDR_WIDTH = 5;
    parameter C_M00_AXI_TARGET_SLAVE_BASE_ADDR = 32'h00000000;
    parameter C_M00_AXI_BURST_LEN = 512;
    parameter C_M00_AXI_ID_WIDTH = 1;
    parameter C_M00_AXI_ADDR_WIDTH = 32;
    parameter C_M00_AXI_DATA_WIDTH = 512;
    parameter C_M00_AXI_AWUSER_WIDTH = 0;
    parameter C_M00_AXI_ARUSER_WIDTH = 0;
    parameter C_M00_AXI_WUSER_WIDTH = 0;
    parameter C_M00_AXI_RUSER_WIDTH = 0;
    parameter C_M00_AXI_BUSER_WIDTH = 0;

    // Testbench signals
    reg s00_axi_aclk;
    reg s00_axi_aresetn;
    reg [C_S00_AXI_ADDR_WIDTH-1:0] s00_axi_awaddr;
    reg [2:0] s00_axi_awprot;
    reg s00_axi_awvalid;
    wire s00_axi_awready;
    reg [C_S00_AXI_DATA_WIDTH-1:0] s00_axi_wdata;
    reg [(C_S00_AXI_DATA_WIDTH/8)-1:0] s00_axi_wstrb;
    reg s00_axi_wvalid;
    wire s00_axi_wready;
    wire [1:0] s00_axi_bresp;
    wire s00_axi_bvalid;
    reg s00_axi_bready;
    reg [C_S00_AXI_ADDR_WIDTH-1:0] s00_axi_araddr;
    reg [2:0] s00_axi_arprot;
    reg s00_axi_arvalid;
    wire s00_axi_arready;
    wire [C_S00_AXI_DATA_WIDTH-1:0] s00_axi_rdata;
    wire [1:0] s00_axi_rresp;
    wire s00_axi_rvalid;
    reg s00_axi_rready;

    reg m00_axi_aclk;
    reg m00_axi_aresetn;
    reg m00_axi_init_axi_txn;
    wire m00_axi_txn_done;
    wire m00_axi_error;

    wire [C_M00_AXI_ID_WIDTH-1:0] m00_axi_awid;
    wire [C_M00_AXI_ADDR_WIDTH-1:0] m00_axi_awaddr;
    wire [7:0] m00_axi_awlen;
    wire [2:0] m00_axi_awsize;
    wire [1:0] m00_axi_awburst;
    wire m00_axi_awlock;
    wire [3:0] m00_axi_awcache;
    wire [2:0] m00_axi_awprot;
    wire [3:0] m00_axi_awqos;
    wire [C_M00_AXI_AWUSER_WIDTH-1:0] m00_axi_awuser;
    wire m00_axi_awvalid;
    wire m00_axi_awready;
    wire [C_M00_AXI_DATA_WIDTH-1:0] m00_axi_wdata;
    wire [C_M00_AXI_DATA_WIDTH/8-1:0] m00_axi_wstrb;
    wire m00_axi_wlast;
    wire [C_M00_AXI_WUSER_WIDTH-1:0] m00_axi_wuser;
    wire m00_axi_wvalid;
    wire m00_axi_wready;
    wire [C_M00_AXI_ID_WIDTH-1:0] m00_axi_bid;
    wire [1:0] m00_axi_bresp;
    wire [C_M00_AXI_BUSER_WIDTH-1:0] m00_axi_buser;
    wire m00_axi_bvalid;
    wire m00_axi_bready;
    wire [C_M00_AXI_ID_WIDTH-1:0] m00_axi_arid;
    wire [C_M00_AXI_ADDR_WIDTH-1:0] m00_axi_araddr;
    wire [7:0] m00_axi_arlen;
    wire [2:0] m00_axi_arsize;
    wire [1:0] m00_axi_arburst;
    wire m00_axi_arlock;
    wire [3:0] m00_axi_arcache;
    wire [2:0] m00_axi_arprot;
    wire [3:0] m00_axi_arqos;
    wire [C_M00_AXI_ARUSER_WIDTH-1:0] m00_axi_aruser;
    wire m00_axi_arvalid;
    wire m00_axi_arready;
    wire [C_M00_AXI_ID_WIDTH-1:0] m00_axi_rid;
    wire [C_M00_AXI_DATA_WIDTH-1:0] m00_axi_rdata;
    wire [1:0] m00_axi_rresp;
    wire m00_axi_rlast;
    wire [C_M00_AXI_RUSER_WIDTH-1:0] m00_axi_ruser;
    wire m00_axi_rvalid;
    wire m00_axi_rready;
    wire [31:0]start;
    // AXI Slave Registers to control the DUT
    wire [C_S00_AXI_DATA_WIDTH-1:0] slv_reg0; // Burst Length
    wire [C_S00_AXI_DATA_WIDTH-1:0] slv_reg1; // Read/Write Mode
    wire [C_S00_AXI_DATA_WIDTH-1:0] slv_reg2; // Number of Transactions
    wire [C_S00_AXI_DATA_WIDTH-1:0] slv_reg3; // Start DRAM Communication Flag

    // Instantiate the DUT
    axi4_speed_test_v1_0 #(
        .C_S00_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
        .C_S00_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH),
        .C_M00_AXI_TARGET_SLAVE_BASE_ADDR(C_M00_AXI_TARGET_SLAVE_BASE_ADDR),
        .C_M00_AXI_BURST_LEN(C_M00_AXI_BURST_LEN),
        .C_M00_AXI_ID_WIDTH(C_M00_AXI_ID_WIDTH),
        .C_M00_AXI_ADDR_WIDTH(C_M00_AXI_ADDR_WIDTH),
        .C_M00_AXI_DATA_WIDTH(C_M00_AXI_DATA_WIDTH),
        .C_M00_AXI_AWUSER_WIDTH(C_M00_AXI_AWUSER_WIDTH),
        .C_M00_AXI_ARUSER_WIDTH(C_M00_AXI_ARUSER_WIDTH),
        .C_M00_AXI_WUSER_WIDTH(C_M00_AXI_WUSER_WIDTH),
        .C_M00_AXI_RUSER_WIDTH(C_M00_AXI_RUSER_WIDTH),
        .C_M00_AXI_BUSER_WIDTH(C_M00_AXI_BUSER_WIDTH)
    ) DUT (
        .start_out(start),
        .s00_axi_aclk(s00_axi_aclk),
        .s00_axi_aresetn(s00_axi_aresetn),
        .s00_axi_awaddr(s00_axi_awaddr),
        .s00_axi_awprot(s00_axi_awprot),
        .s00_axi_awvalid(s00_axi_awvalid),
        .s00_axi_awready(s00_axi_awready),
        .s00_axi_wdata(s00_axi_wdata),
        .s00_axi_wstrb(s00_axi_wstrb),
        .s00_axi_wvalid(s00_axi_wvalid),
        .s00_axi_wready(s00_axi_wready),
        .s00_axi_bresp(s00_axi_bresp),
        .s00_axi_bvalid(s00_axi_bvalid),
        .s00_axi_bready(s00_axi_bready),
        .s00_axi_araddr(s00_axi_araddr),
        .s00_axi_arprot(s00_axi_arprot),
        .s00_axi_arvalid(s00_axi_arvalid),
        .s00_axi_arready(s00_axi_arready),
        .s00_axi_rdata(s00_axi_rdata),
        .s00_axi_rresp(s00_axi_rresp),
        .s00_axi_rvalid(s00_axi_rvalid),
        .s00_axi_rready(s00_axi_rready),
        .m00_axi_aclk(m00_axi_aclk),
        .m00_axi_aresetn(m00_axi_aresetn),
        .m00_axi_init_axi_txn(m00_axi_init_axi_txn),
        .m00_axi_txn_done(m00_axi_txn_done),
        .m00_axi_error(m00_axi_error),
        .m00_axi_awid(m00_axi_awid),
        .m00_axi_awaddr(m00_axi_awaddr),
        .m00_axi_awlen(m00_axi_awlen),
        .m00_axi_awsize(m00_axi_awsize),
        .m00_axi_awburst(m00_axi_awburst),
        .m00_axi_awlock(m00_axi_awlock),
        .m00_axi_awcache(m00_axi_awcache),
        .m00_axi_awprot(m00_axi_awprot),
        .m00_axi_awqos(m00_axi_awqos),
        .m00_axi_awuser(m00_axi_awuser),
        .m00_axi_awvalid(m00_axi_awvalid),
        .m00_axi_awready(m00_axi_awready),
        .m00_axi_wdata(m00_axi_wdata),
        .m00_axi_wstrb(m00_axi_wstrb),
        .m00_axi_wlast(m00_axi_wlast),
        .m00_axi_wuser(m00_axi_wuser),
        .m00_axi_wvalid(m00_axi_wvalid),
        .m00_axi_wready(m00_axi_wready),
        .m00_axi_bid(m00_axi_bid),
        .m00_axi_bresp(m00_axi_bresp),
        .m00_axi_buser(m00_axi_buser),
        .m00_axi_bvalid(m00_axi_bvalid),
        .m00_axi_bready(m00_axi_bready),
        .m00_axi_arid(m00_axi_arid),
        .m00_axi_araddr(m00_axi_araddr),
        .m00_axi_arlen(m00_axi_arlen),
        .m00_axi_arsize(m00_axi_arsize),
        .m00_axi_arburst(m00_axi_arburst),
        .m00_axi_arlock(m00_axi_arlock),
        .m00_axi_arcache(m00_axi_arcache),
        .m00_axi_arprot(m00_axi_arprot),
        .m00_axi_arqos(m00_axi_arqos),
        .m00_axi_aruser(m00_axi_aruser),
        .m00_axi_arvalid(m00_axi_arvalid),
        .m00_axi_arready(m00_axi_arready),
        .m00_axi_rid(m00_axi_rid),
        .m00_axi_rdata(m00_axi_rdata),
        .m00_axi_rresp(m00_axi_rresp),
        .m00_axi_rlast(m00_axi_rlast),
        .m00_axi_ruser(m00_axi_ruser),
        .m00_axi_rvalid(m00_axi_rvalid),
        .m00_axi_rready(m00_axi_rready)
    );
// Instantiate the AXI Slave Test
    axi_slave_test #(
        .C_S_AXI_ID_WIDTH(C_M00_AXI_ID_WIDTH),
        .C_S_AXI_DATA_WIDTH(C_M00_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_M00_AXI_ADDR_WIDTH),
        .C_S_AXI_AWUSER_WIDTH(C_M00_AXI_AWUSER_WIDTH),
        .C_S_AXI_ARUSER_WIDTH(C_M00_AXI_ARUSER_WIDTH),
        .C_S_AXI_WUSER_WIDTH(C_M00_AXI_WUSER_WIDTH),
        .C_S_AXI_RUSER_WIDTH(C_M00_AXI_RUSER_WIDTH),
        .C_S_AXI_BUSER_WIDTH(C_M00_AXI_BUSER_WIDTH)
    ) SLAVE (
        .S_AXI_ACLK(m00_axi_aclk),
        .S_AXI_ARESETN(m00_axi_aresetn),
        .S_AXI_AWID(m00_axi_awid),
        .S_AXI_AWADDR(m00_axi_awaddr[C_M00_AXI_ADDR_WIDTH-1:0]),
        .S_AXI_AWLEN(m00_axi_awlen),
        .S_AXI_AWSIZE(m00_axi_awsize),
        .S_AXI_AWBURST(m00_axi_awburst),
        .S_AXI_AWLOCK(m00_axi_awlock),
        .S_AXI_AWCACHE(m00_axi_awcache),
        .S_AXI_AWPROT(m00_axi_awprot),
        .S_AXI_AWQOS(m00_axi_awqos),
        .S_AXI_AWREGION(4'b0),
        .S_AXI_AWUSER(m00_axi_awuser),
        .S_AXI_AWVALID(m00_axi_awvalid),
        .S_AXI_AWREADY(m00_axi_awready),
        .S_AXI_WDATA(m00_axi_wdata),
        .S_AXI_WSTRB(m00_axi_wstrb),
        .S_AXI_WLAST(m00_axi_wlast),
        .S_AXI_WUSER(m00_axi_wuser),
        .S_AXI_WVALID(m00_axi_wvalid),
        .S_AXI_WREADY(m00_axi_wready),
        .S_AXI_BID(m00_axi_bid),
        .S_AXI_BRESP(m00_axi_bresp),
        .S_AXI_BUSER(m00_axi_buser),
        .S_AXI_BVALID(m00_axi_bvalid),
        .S_AXI_BREADY(m00_axi_bready),
        .S_AXI_ARID(m00_axi_arid),
        .S_AXI_ARADDR(m00_axi_araddr[C_M00_AXI_ADDR_WIDTH-1:0]),
        .S_AXI_ARLEN(m00_axi_arlen),
        .S_AXI_ARSIZE(m00_axi_arsize),
        .S_AXI_ARBURST(m00_axi_arburst),
        .S_AXI_ARLOCK(m00_axi_arlock),
        .S_AXI_ARCACHE(m00_axi_arcache),
        .S_AXI_ARPROT(m00_axi_arprot),
        .S_AXI_ARQOS(m00_axi_arqos),
        .S_AXI_ARREGION(4'b0),
        .S_AXI_ARUSER(m00_axi_aruser),
        .S_AXI_ARVALID(m00_axi_arvalid),
        .S_AXI_ARREADY(m00_axi_arready),
        .S_AXI_RID(m00_axi_rid),
        .S_AXI_RDATA(m00_axi_rdata),
        .S_AXI_RRESP(m00_axi_rresp),
        .S_AXI_RLAST(m00_axi_rlast),
        .S_AXI_RUSER(m00_axi_ruser),
        .S_AXI_RVALID(m00_axi_rvalid),
        .S_AXI_RREADY(m00_axi_rready)
    );
    // Clock generation
    always #5 s00_axi_aclk = ~s00_axi_aclk;
    always #5 m00_axi_aclk = ~m00_axi_aclk;

// Testbench stimulus for Slave Configuration and Master AXI transactions
initial begin
    // Initialize signals
    s00_axi_aclk = 0;
    m00_axi_aclk = 0;
    s00_axi_aresetn = 0;
    m00_axi_aresetn = 0;
    m00_axi_init_axi_txn = 0;
    s00_axi_awvalid = 0;
    s00_axi_wvalid = 0;
    s00_axi_bready = 0;
    s00_axi_arvalid = 0;
    s00_axi_rready = 0;
    m00_axi_init_axi_txn = 1;
    // Reset sequence
    #100;
    s00_axi_aresetn = 1;
    m00_axi_aresetn = 1;
    #100;
// Write to AXI Slave Registers to configure the operation
// Set Burst Length (Register 0 at offset 0x00)
s00_axi_awaddr = 0; // Register 0 address
s00_axi_awvalid = 1;
s00_axi_wdata = 4;
s00_axi_wstrb = 4'b1111;
s00_axi_wvalid = 1;
#100;
s00_axi_awvalid = 0;
s00_axi_wvalid = 0;
s00_axi_bready = 1;
#100;
s00_axi_bready = 0;

// Set Read/Write Mode (Register 1 at offset 0x04)
s00_axi_awaddr = 4; // Register 1 address (0x04)
s00_axi_awvalid = 1;
s00_axi_wdata =  1; // Set to Write mode
s00_axi_wstrb = 4'b1111;
s00_axi_wvalid = 1;
#100;
s00_axi_awvalid = 0;
s00_axi_wvalid = 0;
s00_axi_bready = 1;
#100;
s00_axi_bready = 0;

// Set Number of Transactions (Register 2 at offset 0x08)
s00_axi_awaddr = 8; // Register 2 address (0x08)
s00_axi_awvalid = 1;
s00_axi_wdata = 128;
s00_axi_wstrb = 4'b1111;
s00_axi_wvalid = 1;
#100;
s00_axi_awvalid = 0;
s00_axi_wvalid = 0;
s00_axi_bready = 1;
#100;
s00_axi_bready = 0;

// Set Start DRAM Communication Flag (Register 3 at offset 0x0C)
s00_axi_awaddr = 12; // Register 3 address (0x0C)
s00_axi_awvalid = 1;
s00_axi_wdata = 1;
s00_axi_wstrb = 4'b1111;
s00_axi_wvalid = 1;
#100;
s00_axi_awvalid = 0;
s00_axi_wvalid = 0;
s00_axi_bready = 1;
#100;
s00_axi_bready = 0;



    // Wait for AXI Master to complete the transaction
    wait(m00_axi_txn_done == 1);
    if (m00_axi_error) begin
        $display("ERROR: Master AXI transaction failed.");
    end else begin
        $display("Master AXI transaction completed successfully.");
    end

    // Finish simulation
    $finish;
end

endmodule
