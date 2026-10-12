// SPDX-License-Identifier: GPL-2.0-or-later
// Functional model of the 1:1 clock PLL for the MiSTer-level test only.
// Analog lock behavior is validated by Quartus and on the FPGA.
module am_pll (
	input  wire refclk,
	output wire clk,
	output wire locked
);
reg [5:0] startup = 0;
always @(posedge refclk) if(!startup[5]) startup <= startup + 1'b1;
assign clk = refclk;
assign locked = startup[5];
endmodule
