// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module Two_Port_SRAM #(
    parameter DWIDTH = 16,  // Width of each SPI transfer
    parameter AWIDTH = 15
)(
    //Memory Access formatter
    input [AWIDTH-1:0]Write_Address,
    input [DWIDTH-1:0]Write_Data,
    input WE,
    input RE,
    input [DWIDTH-1:0]Read_Address,
    output reg [DWIDTH-1:0]Read_Data,
    
    //general inputs
    input clk,
    input nRst
    );
    
    reg [DWIDTH-1:0] mem [1:7];
    wire [1:0]state;
    
    assign state = {WE,RE};
    always @(posedge clk or negedge nRst) begin
		if(~nRst) begin
		    Read_Data <= {(DWIDTH){1'b0}};
            mem[1] <= "AA";
            mem[2] <= "AB";
            mem[3] <= "AC";
            mem[4] <= "AD";
            mem[5] <= "AE";
            mem[6] <= "AF";
            mem[7] <= "AG";
		end else begin	//rising edge of clk
			case(state)
				0: begin	//stop
				  Read_Data <= {(DWIDTH){1'b0}};
				end
				1: begin	//Read only
				  Read_Data <= mem[Read_Address[2:0]];
				end
				2: begin	//Write only
				  mem[Write_Address[2:0]] <= Write_Data;
				  Read_Data <= {(DWIDTH){1'b0}};
				end
				3: begin	//Write and Read
				  Read_Data <= mem[Read_Address[2:0]];
				  mem[Write_Address[2:0]] <= Write_Data;
				end
			endcase
		end
	end
    
endmodule