`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/08/28 16:43:03
// Design Name: 
// Module Name: Test bench
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module Test_bench(
    );
    parameter DWIDTH = 16;	//width of each SPI transfer
    parameter AWIDTH = 15;	
    
    reg [AWIDTH-1:0]Write_Address;
    reg [DWIDTH-1:0]Write_Data;
    reg Control_tb;
    reg [AWIDTH-1:0]Read_Address;
    wire [DWIDTH-1:0]Read_Data;
    wire Status_tb;
    reg clk;
    reg nRst;
    reg Burst;
    
    reg [7:0] state_cnt;
    reg [7:0] state;
    
    wire CS;
    wire MISO;
    wire SCLK;
    wire MOSI;
    
    //Clock/ Reset Generation
    always #10 clk= ~clk;
    initial begin
        clk = 1'd0;
        nRst = 1'd0;
        #90;
        nRst = 1'd1;
    end
     always@(posedge clk or negedge nRst) begin
        if(~nRst) begin
            Control_tb <= 1'b0;
            state_cnt <= 6'd0;
            state  <= 6'd0;
            Write_Address <= {(AWIDTH){1'b0}};
            Write_Data    <= {(DWIDTH){1'b0}};
            Read_Address  <= {(AWIDTH){1'b0}};
            Burst <= 1'b0;
        end else begin
                if((state_cnt >150)||(Status_tb)) begin
                    state_cnt <= 8'd0;
                    state  <= state +1;
                end else if(state_cnt<=150) begin
                    state_cnt <= state_cnt +1;
                end
        end
    end
    always @(*) begin
        case(state)
            0: begin // SPI off
                Control_tb <= 1'b0;
                Write_Address <= {(AWIDTH){1'b1}};
                Write_Data    <= "xx";
                Read_Address  <= {(AWIDTH){1'b1}};
                Burst <= 1'b0;
            end
            1: begin // SPI on (burst Write)
                Control_tb <= 1'b1;
                Write_Address <= 7'd1;
                Write_Data    <= "aa";
                Read_Address  <= {(AWIDTH){1'b1}};
                Burst <= 1'b1;
            end
            2: begin // SPI on (burst Write)
                Control_tb <= 1'b1;
                Write_Address <= 7'd2;
                Write_Data    <= "ab";
                Read_Address  <= {(AWIDTH){1'b1}};
                Burst <= 1'b1;
            end
            3: begin // SPI on (burst Write)
                Control_tb <= 1'b1;
                Write_Address <= 7'd3;
                Write_Data    <= "ac";
                Read_Address  <= {(AWIDTH){1'b1}};
                Burst <= 1'b1;
            end
            4: begin // SPI on (burst Write)
                Control_tb <= 1'b1;
                Write_Address <= 7'd4;
                Write_Data    <= "ad";
                Read_Address  <= {(AWIDTH){1'b1}};
                Burst <= 1'b1;
            end
            5: begin // SPI on (burst Read)
                Control_tb <= 1'b1;
                Write_Address <= {(AWIDTH){1'b1}};
                Write_Data    <= "ae";
                Read_Address  <= 7'd1;
                Burst <= 1'b1;
            end
            6: begin // SPI on (burst Read)
                Control_tb <= 1'b1;
                Write_Address <= {(AWIDTH){1'b1}};
                Write_Data    <= "af";
                Read_Address  <= 7'd2;
                Burst <= 1'b1;
            end
            7: begin // SPI on (burst Read)
                Control_tb <= 1'b1;
                Write_Address <= {(AWIDTH){1'b1}};
                Write_Data    <= "ag";
                Read_Address  <= 7'd3;
                Burst <= 1'b1;
            end
            8: begin // SPI on (burst Read)
                Control_tb <= 1'b1;
                Write_Address <= {(AWIDTH){1'b1}};
                Write_Data    <= "ah";
                Read_Address  <= 7'd4;
                Burst <= 1'b1;
            end
            9: begin // SPI on (burst Read)
                Control_tb <= 1'b1;
                Write_Address <= {(AWIDTH){1'b1}};
                Write_Data    <= "ai";
                Read_Address  <= 7'd5;
                Burst <= 1'b1;
            end
            10: begin // SPI on (write)
                Control_tb <= 1'b1;
                Write_Address <= 7'd5;
                Write_Data    <= "ae";
                Read_Address  <= {(AWIDTH){1'b1}};
                Burst <= 1'b0;
            end
            11: begin // SPI on (write)
                Control_tb <= 1'b1;
                Write_Address <= 7'd6;
                Write_Data    <= "af";
                Read_Address  <= {(AWIDTH){1'b1}};
                Burst <= 1'b0;
            end
            12: begin // SPI on (write)
                Control_tb <= 1'b1;
                Write_Address <= 7'd7;
                Write_Data    <= "ag";
                Read_Address  <= {(AWIDTH){1'b1}};
                Burst <= 1'b0;
            end
            13: begin // SPI on (read)
                Control_tb <= 1'b1;
                Write_Address <= {(AWIDTH){1'b1}};
                Write_Data    <= "ai";
                Read_Address  <= 7'd5;
                Burst <= 1'b0;
            end
            14: begin // SPI on (read)
                Control_tb <= 1'b1;
                Write_Address <= {(AWIDTH){1'b1}};
                Write_Data    <= "ai";
                Read_Address  <= 7'd6;
                Burst <= 1'b0;
            end
            15: begin // SPI on (read)
                Control_tb <= 1'b1;
                Write_Address <= {(AWIDTH){1'b1}};
                Write_Data    <= "ai";
                Read_Address  <= 7'd7;
                Burst <= 1'b0;
            end
            default: begin
                Control_tb <= 1'b0;
                Write_Address <= 'd0;
                Write_Data    <= 'd0;
                Read_Address  <= 'd0;
                Burst <= 1'b0;
            end
        endcase
    end
    
     Master_block Master_block(
    //Test bench
     .Write_Address(Write_Address),
     .Write_Data(Write_Data),
     .Control_tb(Control_tb),
     .Read_Address(Read_Address),
     .Read_Data(Read_Data),
     .Status_tb(Status_tb),
     .Burst(Burst),
    
    //Slave block
     .MISO(MISO),
     .CS(CS),
     .SCLK(SCLK),
     .MOSI(MOSI),
    
    //general inputs
     .clk(clk),
     .nRst(nRst)
    );
    
    Slave_block Slave_block(
    //Master block
     .CS(CS),
     .SCLK(SCLK),
     .SDI(MOSI),
     .SDO(MISO),
    
    //general inputs
     .clk(clk),
     .nRst(nRst)
    );
endmodule
