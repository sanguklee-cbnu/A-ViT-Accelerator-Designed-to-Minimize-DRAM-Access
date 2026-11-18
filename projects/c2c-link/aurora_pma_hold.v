`timescale 1ns/1ps

// Behavioral example of the initialization delay used at both C2C endpoints.
module aurora_pma_hold (
    input  wire init_clk,
    input  wire reset_n,
    output wire pma_init
);
    reg [20:0] elapsed;

    always @(posedge init_clk or negedge reset_n) begin
        if (!reset_n)
            elapsed <= 21'd0;
        else if (pma_init)
            elapsed <= elapsed + 1'b1;
    end

    assign pma_init = !elapsed[20];
endmodule
