`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/08/31 18:02:32
// Design Name: 
// Module Name: SPI
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


module SPI #(
    parameter DWIDTH = 16,  // Width of each SPI transfer
    parameter AWIDTH = 15
)(
    //Test bench
    input [AWIDTH-1:0]Write_Address,
    input [DWIDTH-1:0]Write_Data,
    input Control_tb,
    input [AWIDTH-1:0]Read_Address,
    output [DWIDTH-1:0]Read_Data,
    output Status_tb,
    input Burst,
    //general inputs
    input clk,
    input nRst
    );
    
    wire CS;
    wire MISO;
    wire SCLK;
    wire MOSI;
    
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
