`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/08/24 10:12:27
// Design Name: 
// Module Name: SPI Master
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


module SPI_Master #(
    parameter DWIDTH = 16,  // Width of each SPI transfer
    parameter AWIDTH = 15
)(
    //SPI data formatter
    input [DWIDTH-1:0]SPI_TX_data,
    input Control,
    input Start,
    output reg[DWIDTH-1:0]SPI_RX_data,
    output reg Status,
    
    //SPI Slave
    input MISO,
    output reg CS,
    output reg SCLK,
    output reg MOSI,
    
    //general inputs
    input clk,
    input nRst
    );
    
    reg [1:0] state;
    reg [DWIDTH-1:0] SPI_TX_data_reg;
    reg [7:0] sclk_cnt;
    reg SCLK_prev;
    
    always @(posedge clk or negedge nRst) begin
		if(~nRst) begin
			Status <=1'b0;
			SPI_TX_data_reg <= {(DWIDTH){1'b0}};
			state <= 2'd0;	
			CS <= 1'b1;
			sclk_cnt <= 8'd0;
		end else begin	//rising edge of clk
			case(state)
				0: begin	//idle
				    CS <= 1'b1;
					if(Control) begin //master on
					    CS <= 1'b0; 
					    if(Start) begin //for burst
						SPI_TX_data_reg <= SPI_TX_data;
						state <= 2'd1;
						end
					end
				end
				1: begin	//send
					if(sclk_cnt==DWIDTH) begin
						state <= 2'd2;	
						Status <= 1'b1;
					end
				end
				2: begin	//finish
				    Status <= 1'b0;
					state <= 2'd0;		
				end
			endcase
		end
	end
	
    always@(posedge clk or negedge nRst) begin
	  if(!nRst) begin
			SCLK <= 1'b1;
		end else begin
			if(state==2'd0 && Control) begin //idle
				SCLK <= 1'b1;
				sclk_cnt <= 'd0;
			end else	if((state == 2'd1) && (sclk_cnt<=DWIDTH)) begin //during send
					SCLK <= ~SCLK;
					if(SCLK)begin
					sclk_cnt <= sclk_cnt + 1; 
					end
			end
		end 
	end 
    
    always @ (posedge clk or negedge nRst) begin		//SPI_reception
		if(~nRst) begin
			SPI_RX_data <= {DWIDTH{1'b0}};
			MOSI <= 1'b0;
			SCLK_prev <= 1'b1;
		end else if(CS) begin	
		    SPI_RX_data <= {DWIDTH{1'b0}};
			MOSI <= 1'b0;
			SCLK_prev <= 1'b1;
		end else begin
			if(SCLK_prev&&~SCLK) begin 				//falling edge on SCK, MOSI
				MOSI <= SPI_TX_data_reg[DWIDTH-sclk_cnt];
			end else if (~SCLK_prev&&SCLK)begin 	//rising edge on SCK,  MISO
				SPI_RX_data[DWIDTH-sclk_cnt] <= MISO;
			end
			SCLK_prev <= SCLK;
		end
	end
	
endmodule
