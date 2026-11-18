`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/08/24 10:12:27
// Design Name: 
// Module Name: SPI data formatter
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


module SPI_data_formatter #(
    parameter DWIDTH = 16,  // Width of each SPI transfer
    parameter AWIDTH = 15
)(
    //Test bench
    input [AWIDTH-1:0]Write_Address,
    input [DWIDTH-1:0]Write_Data,
    input Control_tb,
    input [AWIDTH-1:0]Read_Address,
    output reg [DWIDTH-1:0]Read_Data,
    output reg Status_tb,
    input Burst,
    
    //SPI Master
    input [DWIDTH-1:0]SPI_RX_data,
    input Status,
    output reg [DWIDTH-1:0]SPI_TX_data,
    output reg Control,
    output reg Start,
    //general inputs
    input clk,
    input nRst
    );
    
    reg [2:0] state;
    reg [AWIDTH-1:0]Write_Address_reg;
    reg [AWIDTH-1:0]Read_Address_reg;
    reg [DWIDTH-1:0]Write_Data_reg;
    
    always@(posedge clk or negedge nRst) begin
		if(~nRst||((~Read_Address)&&(~Write_Address))) begin
			Control <= 1'b0;
			Start <= 1'b0;
			state <= 3'd0;
			Status_tb <= 1'b0;
			Read_Address_reg <= {(AWIDTH){1'b0}};
			Read_Data <= {(DWIDTH){1'b0}};
			SPI_TX_data <= {(DWIDTH){1'b0}};
			Write_Address_reg <= {(AWIDTH){1'b0}};
			Write_Data_reg <= {(DWIDTH){1'b0}};
		end
	    else begin
				case(state)
				0: begin // Phase1
				    Status_tb <= 1'b0;
					if(Control_tb) begin //SPI on
					   Write_Address_reg <= Write_Address;
					   Read_Address_reg <= Read_Address;
		         	   Write_Data_reg <= Write_Data;
					    if(~Read_Address)begin // Read
					      SPI_TX_data <= {1'd0,Read_Address};
					   	  Control <= 1'b1; //master on(during burst)
					   	  Start <= 1'b1; //master restart
						  state <= 3'd2;// Read Phase2
					    end
					    else begin  // Write
						  SPI_TX_data <= {1'd1,Write_Address};
					   	  Control <= 1'b1; //master on(during burst)
					   	  Start <= 1'b1;  //master restart
						  state <= 3'd1;  // Write Phase 2
						end
					end
				end
				1: begin // Write Phase 2 start
				    Start <= 1'b0; 
				    if(Status) begin //Write address
						SPI_TX_data <= Write_Data;
						Start <= 1'b1; //master restart
						state <= 3'd3;
					end 
				end
				2: begin // Read Phase2 start
				    Start <= 1'b0;
					if(Status) begin   // Read address
					    Start <= 1'b1; //master restart
						state <= 3'd3;
					end 
				end
				3: begin 
				    Start <= 1'b0;
					if(Status) begin // Phase2 end
						state <= 3'd4;
						Status_tb<=1'b1; //next information
						if(~Burst)
						Control <= 1'b0; //master off
					end
				end
				4: begin // delay for Burst(checking next information)
					state <= 3'd5;
				    SPI_TX_data <= Write_Data;
				    Read_Data <= SPI_RX_data;
					Status_tb<=1'b0; //SPI off
				end
				5: begin // Burst
				    Start <= 1'b1; //master restart
				    if(~Read_Address_reg)begin //read
					  Read_Data <= SPI_RX_data;
					  Read_Address_reg <= Read_Address_reg+1;
					end
					else begin //write
					  SPI_TX_data <= Write_Data;
					end
					if((~Read_Address_reg&&~Write_Address)||(~Write_Address_reg&&~Read_Address))begin //change function
					  Control <= 1'b0;
					  state <= 3'd0;
					end
					else if(~Burst) begin
					  Control <= 1'b0;
					  state <= 3'd0;
					end
					else
					  state <= 3'd3;
				end
				default: begin
					state <= 3'd0;
				end
			endcase
	    end
	end
endmodule
