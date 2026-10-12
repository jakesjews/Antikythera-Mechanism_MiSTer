// SPDX-License-Identifier: GPL-2.0-or-later
// The anomalies: Hipparchan eccentres for the Sun and Moon (the k1/k2
// pin-and-slot) and epicycles for the five planets, all evaluated with one
// shared CORDIC once per frame. Longitudes are 20-bit fractions of a turn,
// zero at the first point of Aries, increasing clockwise on the dial.
(* multstyle = "logic" *)
module am_cosmos (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [20*23-1:0] fracs,
	output reg  [19:0] lon_date,
	output reg  [19:0] lon_sun,
	output reg  [19:0] lon_moon,
	output reg  [19:0] lon_phase,
	output reg  [19:0] lon_node,
	output reg  [19:0] lon_apogee,
	output reg  [19:0] lon_mercury,
	output reg  [19:0] lon_venus,
	output reg  [19:0] lon_mars,
	output reg  [19:0] lon_jupiter,
	output reg  [19:0] lon_saturn,
	output reg  [19:0] moon_anomaly_out,   // pin-and-slot output angle for the gear view
	output reg  signed [15:0] phase_sin,
	output reg  signed [15:0] phase_cos,
	output reg  signed [15:0] moon_sin,
	output reg  signed [15:0] moon_cos,
	output reg         done
);

`include "am_tables.svh"

function automatic [19:0] frac_of(input integer i);
	frac_of = fracs[i*20 +: 20];
endfunction

localparam signed [31:0] INV_GAIN = 32'sd10188013; // 1/1.6468 in Q24

reg [3:0] body;
reg [2:0] state;
reg cordic_start, cordic_vectoring;
reg signed [31:0] cx, cy;
reg signed [19:0] cz;
wire signed [31:0] ox, oy;
wire signed [19:0] oz;
wire cordic_done;

am_cordic cordic (
	.clk(clk), .start(cordic_start), .vectoring(cordic_vectoring),
	.x_in(cx), .y_in(cy), .z_in(cz), .x_out(ox), .y_out(oy), .z_out(oz), .done(cordic_done)
);

reg [19:0] alpha, base;
reg eccentric;
always @* begin
	case(body)
		0: begin base = frac_of(SH_SUN_MEAN); alpha = frac_of(SH_SUN_ANOMALY); eccentric = 1; end
		1: begin base = frac_of(SH_MOON_MEAN); alpha = frac_of(SH_MOON_ANOMALY); eccentric = 1; end
		2: begin base = frac_of(SH_SUN_MEAN); alpha = frac_of(SH_MERCURY); eccentric = 0; end
		3: begin base = frac_of(SH_SUN_MEAN); alpha = frac_of(SH_VENUS); eccentric = 0; end
		4: begin base = frac_of(SH_MARS); alpha = frac_of(SH_SUN_MEAN) - frac_of(SH_MARS); eccentric = 0; end
		5: begin base = frac_of(SH_JUPITER); alpha = frac_of(SH_SUN_MEAN) - frac_of(SH_JUPITER); eccentric = 0; end
		6: begin base = frac_of(SH_SATURN); alpha = frac_of(SH_SUN_MEAN) - frac_of(SH_SATURN); eccentric = 0; end
		7: begin base = 0; alpha = lon_moon - lon_sun; eccentric = 0; end   // phase
		default: begin base = 0; alpha = lon_moon; eccentric = 0; end       // moon pointer direction
	endcase
end

wire [47:0] e_scaled = body_eccentricity(body) * 32'd10188013; // Q14 * Q24 / 2^14 = Q24
wire signed [19:0] q20 = oz;

always @(posedge clk) begin
	cordic_start <= 0;
	done <= 0;
	if(reset) begin
		state <= 0;
		body <= 0;
	end else case(state)
		0: if(start) begin
			state <= 1;
			body <= 0;
			lon_date <= frac_of(SH_SUN_MEAN);
			lon_node <= frac_of(SH_NODES);
			lon_apogee <= frac_of(SH_APSIDES);
		end
		1: begin // rotate the epicycle radius (or the unit vector) by alpha
			cx <= body < 7 ? $signed({7'b0, e_scaled[38:14]}) : INV_GAIN;
			cy <= 0;
			cz <= alpha;
			cordic_vectoring <= 0;
			cordic_start <= 1;
			state <= 2;
		end
		2: if(cordic_done) state <= 3;
		3: begin
			if(body < 7) begin
				cx <= 32'sd16777216 + ox;    // deferent radius plus epicycle vector
				cy <= oy;
				cz <= 0;
				cordic_vectoring <= 1;
				cordic_start <= 1;
				state <= 4;
			end else begin
				if(body == 7) begin
					phase_cos <= ox[25:10];      // Q24 -> Q14
					phase_sin <= oy[25:10];
					body <= 8;
					state <= 1;
				end else begin
					moon_cos <= ox[25:10];
					moon_sin <= oy[25:10];
					done <= 1;
					state <= 0;
				end
			end
		end
		4: if(cordic_done) state <= 5;
		5: begin
			case(body)
				0: lon_sun <= base - q20;
				1: begin lon_moon <= base - q20; moon_anomaly_out <= -q20; end
				2: lon_mercury <= base + q20;
				3: lon_venus <= base + q20;
				4: lon_mars <= base + q20;
				5: lon_jupiter <= base + q20;
				default: lon_saturn <= base + q20;
			endcase
			if(body == 6) begin
				lon_phase <= lon_moon - lon_sun;
				body <= 7;
			end else body <= body + 1'b1;
			state <= 1;
		end
		default: state <= 0;
	endcase
end

endmodule
