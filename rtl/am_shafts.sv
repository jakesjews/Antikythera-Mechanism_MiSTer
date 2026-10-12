// SPDX-License-Identifier: GPL-2.0-or-later
// The gear train as exact modular arithmetic. Every shaft keeps an
// accumulator F in [0, D) with D = denominator * ticks per turn of b1, and
// advances by its numerator for every tick of 1/65536 day. The angle of the
// shaft is F/D turns, with no rounding anywhere, so the ratios between the
// pointers are exactly the ratios of the tooth counts.
//
// Steps are powers of two up to 2^16 ticks (one day) and are applied to one
// shaft per clock. Once per frame the accumulators are converted to 20-bit
// binary fractions of a turn by sequential division.
(* multstyle = "logic" *)
module am_shafts (
	input  wire        clk,
	input  wire        reset,
	input  wire        load,          // reload the epoch
	input  wire        epoch,
	input  wire        b1_224,
	input  wire        step,
	input  wire        step_forward,
	input  wire [4:0]  step_shift,
	input  wire        compute,
	output wire        busy,
	output reg  [20*23-1:0] fracs,
	output reg         fracs_valid,
	output reg  [7:0]  met_cell,       // exact floor(235 * metonic fraction)
	output reg  [7:0]  sar_cell,       // exact floor(223 * saros fraction)
	output reg  signed [19:0] crank_turns
);

`include "am_tables.svh"

reg [39:0] f [0:NSHAFT-1];
reg [4:0] index;
reg stepping = 0, dividing = 0;
reg [4:0] bit_count;
reg [40:0] rem;
reg [19:0] quotient;
reg fwd;
reg [4:0] shift;
reg [1:0] load_pending = 0;
reg compute_pending = 0;
reg celling = 0;
reg [3:0] cell_step;
reg [47:0] cell_rem;
reg [7:0] cell_q;

assign busy = stepping || dividing || celling || load_pending != 0 || compute_pending;

wire [39:0] modulus = shaft_mod(index);
wire [32:0] increment = {16'd0, shaft_num(index, b1_224)} << shift;
wire direction = fwd ^ shaft_neg(index);
wire [40:0] sum = {1'b0, f[index]} + {8'd0, increment};
wire [40:0] diff = {1'b0, f[index]} - {8'd0, increment};
wire [40:0] sum_wrapped = (sum >= {1'b0, modulus}) ? sum - {1'b0, modulus} : sum;
wire [40:0] diff_wrapped = diff[40] ? diff + {1'b0, modulus} : diff;
wire [40:0] rem2 = {rem[39:0], 1'b0};
// Exact cell numbers: floor(F * cells / D) by restoring division, 8 quotient bits.
wire [39:0] cell_mod = shaft_mod(cell_step[3] ? SH_SAROS : SH_METONIC);
wire [47:0] cell_trial = {8'd0, cell_mod} << (3'd7 - cell_step[2:0]);
wire cell_ge = cell_rem >= cell_trial;

integer i;
always @(posedge clk) begin
	fracs_valid <= 0;
	if(compute) compute_pending <= 1;
	if(reset || load) begin
		for(i = 0; i < NSHAFT; i = i + 1) f[i] <= epoch_f0(epoch, i);
		stepping <= 0;
		dividing <= 0;
		index <= 0;
		crank_turns <= 0;
		load_pending <= 2;
	end else if(load_pending != 0) begin
		load_pending <= load_pending - 1'b1;
	end else if(stepping) begin
		f[index] <= direction ? sum_wrapped[39:0] : diff_wrapped[39:0];
		if(index == SH_CRANK) begin
			if(direction && sum >= {1'b0, modulus}) crank_turns <= crank_turns + 1'b1;
			if(!direction && diff[40]) crank_turns <= crank_turns - 1'b1;
		end
		if(index == NSHAFT - 1) begin
			stepping <= 0;
			index <= 0;
		end else index <= index + 1'b1;
	end else if(dividing) begin
		// Restoring division: 20 quotient bits of f/modulus.
		if(rem2 >= {1'b0, modulus}) begin
			rem <= rem2 - {1'b0, modulus};
			quotient <= {quotient[18:0], 1'b1};
		end else begin
			rem <= rem2;
			quotient <= {quotient[18:0], 1'b0};
		end
		if(bit_count == 19) begin
			fracs[index*20 +: 20] <= rem2 >= {1'b0, modulus} ? {quotient[18:0], 1'b1} : {quotient[18:0], 1'b0};
			bit_count <= 0;
			rem <= {1'b0, f[index == NSHAFT - 1 ? 0 : index + 1]};
			if(index == NSHAFT - 1) begin
				dividing <= 0;
				celling <= 1;
				cell_step <= 0;
				cell_rem <= {8'd0, f[SH_METONIC]} * 48'd235;
				cell_q <= 0;
				index <= 0;
			end else index <= index + 1'b1;
		end else bit_count <= bit_count + 1'b1;
	end else if(celling) begin
		if(cell_ge) cell_rem <= cell_rem - cell_trial;
		cell_q <= {cell_q[6:0], cell_ge};
		if(cell_step == 7) begin
			met_cell <= {cell_q[6:0], cell_ge};
			cell_rem <= {8'd0, f[SH_SAROS]} * 48'd223;
			cell_q <= 0;
		end
		if(cell_step == 15) begin
			sar_cell <= {cell_q[6:0], cell_ge};
			celling <= 0;
			fracs_valid <= 1;
		end
		cell_step <= cell_step + 1'b1;
	end else if(step) begin
		stepping <= 1;
		index <= 0;
		fwd <= step_forward;
		shift <= step_shift;
	end else if(compute_pending || compute) begin
		compute_pending <= 0;
		dividing <= 1;
		index <= 0;
		bit_count <= 0;
		rem <= {1'b0, f[0]};
		quotient <= 0;
	end
end

endmodule
