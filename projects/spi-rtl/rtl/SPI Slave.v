`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/08/24 10:12:27
// Design Name: 
// Module Name: SPI Slave
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


module SPI_Slave #(
    parameter DWIDTH = 16,  // Width of each SPI transfer
    parameter AWIDTH = 15
)(
    //SPI Master
    input CS,
    input SCLK,
    input SDI,
    output reg SDO,
    
    //Memory Access formatter
    input [DWIDTH-1:0]SPI_RX_data,
    input Status,
    output reg [DWIDTH-1:0]SPI_TX_data,
    output reg Control,
    
    //general inputs
    input clk,
    input nRst
    );
    
    reg [DWIDTH-1:0] SPI_TX_data_reg;
    reg [DWIDTH-1:0] sclk_cnt;
    reg SCLK_prev;
    always @ (posedge clk or negedge nRst) begin		//SPI_reception
		if(~nRst || CS) begin
			SPI_TX_data_reg <= {(DWIDTH){1'b0}};
			SPI_TX_data <= {(DWIDTH){1'b0}};
			sclk_cnt <= {(DWIDTH){1'b0}};
			Control <=1'b0;
			SDO <= 1'b0;
			SCLK_prev <= 1'b1;
		end else begin  // slave on
			if(SCLK_prev && ~SCLK) begin 				//falling edge on SCLK, MISO
				SDO <= SPI_RX_data[DWIDTH-sclk_cnt-1];
				Control <= 1'b1;
			end else if (~SCLK_prev && SCLK)begin 	//rising edge on SCLK, MOSI
				SPI_TX_data_reg[DWIDTH-sclk_cnt-1] <= SDI;
				//SCK counter
				if( sclk_cnt == (DWIDTH-1)) begin
					sclk_cnt <= 8'd0;
				end else begin	
					sclk_cnt <= sclk_cnt + 1;
				end			
			end else begin  // finish one cycle
				Control <= 1'b1;
				SPI_TX_data <= SPI_TX_data_reg;	
			end
			SCLK_prev <= SCLK;
		end
	end
    
endmodule
