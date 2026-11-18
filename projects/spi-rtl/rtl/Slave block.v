`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/08/24 10:12:27
// Design Name: 
// Module Name: Slave block
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


module Slave_block(
    //Master block
    input CS,
    input SCLK,
    input SDI,
    output SDO,
    
    //general inputs
    input clk,
    input nRst
    );
    parameter DWIDTH = 16;	//width of each SPI transfer
    parameter AWIDTH = 15;
    
    wire [DWIDTH-1:0]SPI_TX_data;
    wire Control;
    wire [DWIDTH-1:0]SPI_RX_data;
    wire Status;
    wire [DWIDTH-1:0]Read_Data;
    wire [AWIDTH-1:0]Write_Address;
    wire [DWIDTH-1:0]Write_Data;
    wire WE;
    wire RE;
    wire [DWIDTH-1:0]Read_Address;
    
    SPI_Slave SPI_Slave(
    //SPI Master
    .CS(CS),
    .SCLK(SCLK),
    .SDI(SDI),
    .SDO(SDO),
    
    //Memory Access formatter
    .SPI_RX_data(SPI_RX_data),
    .Status(Status),
    .SPI_TX_data(SPI_TX_data),
    .Control(Control),
    
    //general inputs
    .clk(clk),
    .nRst(nRst)
    );
    
    Memory_Access_formatter Memory_Access_formatter(
    //SPI Slave
    .SPI_TX_data(SPI_TX_data),
    .Control(Control),
    .SPI_RX_data(SPI_RX_data),
    .Status(Status),
    
    //Two Port SRAM
    .Read_Data(Read_Data),
    .Write_Address(Write_Address),
    .Write_Data(Write_Data),
    .WE(WE),
    .RE(RE),
    .Read_Address(Read_Address),
    
    //general inputs
    .clk(clk),
    .nRst(nRst)
    );
    
    Two_Port_SRAM Two_Port_SRAM(
    //Memory Access formatter
    .Write_Address(Write_Address),
    .Write_Data(Write_Data),
    .WE(WE),
    .RE(RE),
    .Read_Address(Read_Address),
    .Read_Data(Read_Data),
    
    //general inputs
    .clk(clk),
    .nRst(nRst)
    );
endmodule
