`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/08/24 10:12:27
// Design Name: 
// Module Name: Master block
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


module Master_block #(
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
    
    //Slave block
    input MISO,
    output CS,
    output SCLK,
    output MOSI,
    
    //general inputs
    input clk,
    input nRst
    );
    
    wire [DWIDTH-1:0]SPI_TX_data;
    wire Status;
    wire [DWIDTH-1:0]SPI_RX_data;
    wire Control;
    
    SPI_data_formatter SPI_data_formatter(
    //Test bench
    .Write_Address(Write_Address),
    .Write_Data(Write_Data),
    .Control_tb(Control_tb),
    .Read_Address(Read_Address),
    .Read_Data(Read_Data),
    .Status_tb(Status_tb),
    .Burst(Burst),
    
    //SPI Master
    .SPI_RX_data(SPI_RX_data),
    .Status(Status),
    .SPI_TX_data(SPI_TX_data),
    .Control(Control),
    .Start(Start),
    //general inputs
    .clk(clk),
    .nRst(nRst)
    );
    
    SPI_Master SPI_Master(
    //SPI data formatter
    .SPI_TX_data(SPI_TX_data),
    .Control(Control),
    .SPI_RX_data(SPI_RX_data),
    .Status(Status),
    .Start(Start),
    //SPI Slave
    .MISO(MISO),
    .CS(CS),
    .SCLK(SCLK),
    .MOSI(MOSI),
    
    //general inputs
    .clk(clk),
    .nRst(nRst)
    );
endmodule