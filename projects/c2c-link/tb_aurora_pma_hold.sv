`timescale 1ns/1ps

module tb_aurora_pma_hold;
    bit init_clk = 0;
    bit reset_n = 1;
    wire pma_init;

    aurora_pma_hold dut (.init_clk(init_clk), .reset_n(reset_n), .pma_init(pma_init));
    always #5 init_clk = ~init_clk;

    task automatic check_level(input bit expected);
        if (pma_init !== expected)
            $fatal(1, "pma_init=%b expected=%b at %t", pma_init, expected, $time);
    endtask

    initial begin
        #2 reset_n = 0;
        #1 check_level(1);
        @(negedge init_clk) reset_n = 1;
        repeat (1_048_575) begin
            @(posedge init_clk);
            #1 check_level(1);
        end
        @(posedge init_clk);
        #1 check_level(0);
        repeat (16) begin
            @(posedge init_clk);
            #1 check_level(0);
        end
        #1 reset_n = 0;
        #1 check_level(1);
        $display("PMA hold checks passed");
        $finish;
    end
endmodule
