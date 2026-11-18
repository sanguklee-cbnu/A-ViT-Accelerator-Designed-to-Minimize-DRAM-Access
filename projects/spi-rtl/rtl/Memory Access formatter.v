`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/08/24 10:12:27
// Design Name: 
// Module Name: Memory Access formatter
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


module Memory_Access_formatter #(
    parameter DWIDTH = 16,  // Width of each SPI transfer
    parameter AWIDTH = 15
)(
    //SPI Slave
    input [DWIDTH-1:0]SPI_TX_data,
    input Control,
    output reg [DWIDTH-1:0]SPI_RX_data,
    output reg Status,
    
    //Two Port SRAM
    input [DWIDTH-1:0]Read_Data,
    output reg [AWIDTH-1:0]Write_Address,
    output reg [DWIDTH-1:0]Write_Data,
    output reg WE,
    output reg RE,
    output reg [DWIDTH-1:0]Read_Address,
    
    //general inputs
    input clk,
    input nRst
    );
    
    reg [2:0] state;
    reg [7:0] cnt;
    
     always@(posedge clk or negedge nRst) begin
		if(~nRst || ~Control) begin
			Status <= 1'b0;
			state <= 3'd0;
			Read_Address <= {(AWIDTH){1'b0}};
			SPI_RX_data <= {(DWIDTH){1'b0}};
			Write_Address <= {(AWIDTH){1'b0}};
			Write_Data <= {(DWIDTH){1'b0}};
			WE <= 1'b0;
			RE <= 1'b0;
			cnt <= 8'd0;
		end else begin
			case(state)
				0: begin // receive address (write or read)
					if(Control) begin
					SPI_RX_data <= "ad"; //receive address
					    if(cnt==2*DWIDTH)begin 
					      state<=3'd1;
					      cnt <= 8'd0;
					      Status <= 1'b1;
					    end
					    else begin
						  cnt <= cnt+1;
					    end
					end
				end
				1: begin //Determine if it is a read or write address
				    Status <= 1'b0;
					if(SPI_TX_data[DWIDTH-1]==1) begin //write only
						Write_Address <= SPI_TX_data;
						SPI_RX_data <= "wr"; //receive data
						state <= 3'd5;//Write Phase2
					end 
					else begin //Read only
					    Read_Address <= SPI_TX_data;
					    RE <= 1'b1; //Sram read
						state <= 3'd2;//Read Phase2
					end
				end
				2: begin //Read Phase2
				    SPI_RX_data <= Read_Data;
				    if(cnt==2*DWIDTH)begin 
					    state<=3'd3; 
					    cnt <= 8'd0;
					    Status <= 1'b1;
					end
					else begin
						cnt <= cnt+1;
					end
				end
				3: begin //delay for Read
				        Status <= 1'b0;
						state <= 3'd4;
			    end
				4: begin //delay and address counter
				      Read_Address <= Read_Address+1;
				      RE <= 1'b1; //Sram Write
				      state <= 3'd2;
				end
				5: begin //Write Phase2
				    if(cnt==2*DWIDTH+1)begin 
					    state<=3'd6;
					    cnt <= 8'd0;
					    Status <= 1'b1;
					    Write_Data <= SPI_TX_data;
					    WE <= 1'b1; //Sram Write
					end
					else begin
						cnt <= cnt+1;
					end
				end
				6: begin //delay for Write
				      Status <= 1'b0;
				      state <= 3'd7;
				end
				7: begin //delay and address counter
				      WE <= 1'b0;
				      Write_Address <= Write_Address+1;
				      state <= 3'd5;
				end
				default: begin
					state <= 3'd0;
				end
			endcase
			
		end
	end
    
endmodule