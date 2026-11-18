/******************************************************************************
*
* Copyright (C) 2009 - 2014 Xilinx, Inc.  All rights reserved.
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* Use of the Software is limited solely to applications:
* (a) running on a Xilinx device, or
* (b) that interact with a Xilinx device through a bus or interconnect.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
* XILINX  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
* WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF
* OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*
* Except as contained in this notice, the name of the Xilinx shall not be used
* in advertising or otherwise to promote the sale, use or other dealings in
* this Software without prior written authorization from Xilinx.
*
******************************************************************************/

/*
 * helloworld.c: simple test application
 *
 * This application configures UART 16550 to baud rate 9600.
 * PS7 UART (Zynq) is not initialized by this application, since
 * bootrom/bsp configures it to baud rate 115200
 *
 * ------------------------------------------------
 * | UART TYPE   BAUD RATE                        |
 * ------------------------------------------------
 *   uartns550   9600
 *   uartlite    Configurable only in HW design
 *   ps7_uart    115200 (configured by bootrom/bsp)
 */


#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"
#include "xuartlite.h"
#include "xparameters.h" // Base address
#include "xil_io.h"

#define BURST_LENGTH_REG_OFFSET 0x00
#define RW_MODE_REG_OFFSET 0x04
#define NUM_TRANSACTIONS_REG_OFFSET 0x08
#define START_DRAM_COMM_REG_OFFSET 0x0C
#define TIME_ELAPSED_REG_OFFSET 0x10
#define STATE_REG_OFFSET 0x14
#define address_OFFSET 0x18
void delay(int count) {
    for (int i = 0; i < count; i++) {
        asm("nop");
    }
}
int main() {
    // Initialize the burst length for all AXI instances
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_0_BASEADDR + BURST_LENGTH_REG_OFFSET, 8);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_1_BASEADDR + BURST_LENGTH_REG_OFFSET, 8);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_2_BASEADDR + BURST_LENGTH_REG_OFFSET, 8);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_3_BASEADDR + BURST_LENGTH_REG_OFFSET, 8);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_4_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_5_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_6_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_7_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_8_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_9_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_10_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_11_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_12_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_13_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_14_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_15_BASEADDR + BURST_LENGTH_REG_OFFSET, 4);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_16_BASEADDR + BURST_LENGTH_REG_OFFSET, 1);
    xil_printf("Set Burst length for all instances\r\n");

    // Set read/write mode (0 for Read, 1 for Write) for all AXI instances
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_0_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_1_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_2_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_3_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_4_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_5_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_6_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_7_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_8_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_9_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_10_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_11_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_12_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_13_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_14_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_15_BASEADDR + RW_MODE_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_16_BASEADDR + RW_MODE_REG_OFFSET, 0);
    xil_printf("Set mode for all instances\r\n");

    // Set the number of transactions for all AXI instances
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_0_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_1_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_2_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_3_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_4_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_5_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_6_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_7_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_8_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_9_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_10_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_11_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_12_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_13_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_14_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_15_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_16_BASEADDR + NUM_TRANSACTIONS_REG_OFFSET, 128);
    xil_printf("Number of transactions set to 128 for all instances\r\n");

    // Set address
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_0_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_1_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_2_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_3_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_4_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_5_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_6_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_7_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_8_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_9_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_10_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_11_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_12_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_13_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_14_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_15_BASEADDR + address_OFFSET, 0x00000000);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_16_BASEADDR + address_OFFSET, 0x00000000);
    xil_printf("Set address \r\n");

    // Set the start flag to initiate DRAM communication for all AXI instances
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_0_BASEADDR + START_DRAM_COMM_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_1_BASEADDR + START_DRAM_COMM_REG_OFFSET, 1);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_2_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_3_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_4_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_5_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_6_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_7_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_8_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_9_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_10_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_11_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_12_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_13_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_14_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_15_BASEADDR + START_DRAM_COMM_REG_OFFSET, 0);
    Xil_Out32(XPAR_AXI4_SPEED_TEST_V1_0_16_BASEADDR + START_DRAM_COMM_REG_OFFSET, 1);
    xil_printf("Start DRAM communication for all instances\r\n");

    // Reading values for verification for all AXI instances
    for (int i = 0; i < 17; i++) {
        unsigned int base_addr;
        switch(i) {
            case 0: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_0_BASEADDR; break;
            case 1: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_1_BASEADDR; break;
            case 2: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_2_BASEADDR; break;
            case 3: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_3_BASEADDR; break;
            case 4: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_4_BASEADDR; break;
            case 5: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_5_BASEADDR; break;
            case 6: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_6_BASEADDR; break;
            case 7: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_7_BASEADDR; break;
            case 8: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_8_BASEADDR; break;
            case 9: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_9_BASEADDR; break;
            case 10: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_10_BASEADDR; break;
            case 11: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_11_BASEADDR; break;
            case 12: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_12_BASEADDR; break;
            case 13: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_13_BASEADDR; break;
            case 14: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_14_BASEADDR; break;
            case 15: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_15_BASEADDR; break;
            case 16: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_16_BASEADDR; break;
            default: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_0_BASEADDR; break;
        }
        unsigned int burst_length = Xil_In32(base_addr + BURST_LENGTH_REG_OFFSET);
        unsigned int rw_mode = Xil_In32(base_addr + RW_MODE_REG_OFFSET);
        unsigned int num_transactions = Xil_In32(base_addr + NUM_TRANSACTIONS_REG_OFFSET);
        unsigned int start = Xil_In32(base_addr + START_DRAM_COMM_REG_OFFSET);
        unsigned int state = Xil_In32(base_addr + STATE_REG_OFFSET);
        unsigned int address = Xil_In32(base_addr + address_OFFSET);

        xil_printf("Instance %d:\r\n", i);
        xil_printf("  Burst length(%d): %d\r\n", i, burst_length);
        xil_printf("  RW mode(%d): %d\r\n", i, rw_mode);
        xil_printf("  Num transactions(%d): %d\r\n", i, num_transactions);
        xil_printf("  start address(%d): %x\r\n", i, address);
        xil_printf("  Start(%d): %d\r\n", i, start);
        xil_printf("  State(%d): %d\r\n", i, state);
    }

    xil_printf("DRAM communication completed\r\n");

    // Add delay using a loop (approximation)

    for (int i = 0; i < 16; i++) {
        unsigned int base_addr;
        switch(i) {
            case 0: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_0_BASEADDR; break;
            case 1: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_1_BASEADDR; break;
            case 2: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_2_BASEADDR; break;
            case 3: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_3_BASEADDR; break;
            case 4: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_4_BASEADDR; break;
            case 5: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_5_BASEADDR; break;
            case 6: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_6_BASEADDR; break;
            case 7: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_7_BASEADDR; break;
            case 8: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_8_BASEADDR; break;
            case 9: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_9_BASEADDR; break;
            case 10: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_10_BASEADDR; break;
            case 11: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_11_BASEADDR; break;
            case 12: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_12_BASEADDR; break;
            case 13: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_13_BASEADDR; break;
            case 14: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_14_BASEADDR; break;
            case 15: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_15_BASEADDR; break;
            case 16: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_16_BASEADDR; break;
            default: base_addr = XPAR_AXI4_SPEED_TEST_V1_0_0_BASEADDR; break;
        }
        unsigned int elapsed_time = Xil_In32(base_addr + TIME_ELAPSED_REG_OFFSET);
        xil_printf("Elapsed time(%d): %d clock cycles\r\n", i, elapsed_time);
    }

    return 0;
}



