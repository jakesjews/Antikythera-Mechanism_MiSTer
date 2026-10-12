// SPDX-License-Identifier: GPL-2.0-or-later
// MiSTer's Cyclone V video clock mux requires a PLL output, even at 50 MHz.
// Keep pll|pll_inst|altera_pll_i so the unmodified framework SDC groups it.
module am_pll (
	input  wire refclk,
	output wire clk,
	output wire locked
);
am_pll_output pll_inst (.refclk(refclk), .clk(clk), .locked(locked));
endmodule

module am_pll_output (
	input  wire refclk,
	output wire clk,
	output wire locked
);
altera_pll #(
	.fractional_vco_multiplier("false"),
	.reference_clock_frequency("50.0 MHz"),
	.operation_mode("direct"),
	.number_of_clocks(1),
	.output_clock_frequency0("50.0 MHz"),
	.phase_shift0("0 ps"),
	.duty_cycle0(50),
	.pll_type("General"),
	.pll_subtype("General")
) altera_pll_i (
	.refclk(refclk), .rst(1'b0), .fbclk(1'b0),
	.outclk(clk), .locked(locked), .fboutclk()
);
endmodule
