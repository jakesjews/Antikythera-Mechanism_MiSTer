// SPDX-License-Identifier: GPL-2.0-or-later
// Reads the dials for the operator: calendar dates, zodiac positions, the
// cells under the back-dial pointers, the eclipse glyphs and the parapegma.
// Runs once per frame after the longitudes are known.
(* multstyle = "logic" *)
module am_calendar (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire        clear,          // epoch reloaded: forget the previous positions
	input  wire        epoch,
	input  wire signed [39:0] ticks,
	input  wire        last_forward,
	input  wire        ring_lunar,
	input  wire        ring_auto,
	input  wire [19:0] ring_manual,
	input  wire [20*23-1:0] fracs,
	input  wire [19:0] lon_sun, lon_moon, lon_phase, lon_node,
	input  wire [19:0] lon_mercury, lon_venus, lon_mars, lon_jupiter, lon_saturn,
	input  wire signed [19:0] crank_turns,
	input  wire [7:0]  met_cell_in,
	input  wire [7:0]  sar_cell_in,
	output reg  [7:0]  jul_day_bcd,
	output reg  [3:0]  jul_month,          // 0..11
	output reg  [15:0] jul_year_bcd,
	output reg         jul_bc,
	output reg  [3:0]  egy_month,          // 0..11, 12 = epagomenal
	output reg  [7:0]  egy_day_bcd,
	output reg  [19:0] ring_offset,
	output reg  [8:0]  ring_index,         // division under the date pointer
	output reg  [35:0] body_sign,          // 9 x 4 bits
	output reg  [71:0] body_deg,           // 9 x 8-bit BCD
	output reg  [2:0]  phase_index,
	output reg  [7:0]  age_bcd,
	output reg  [7:0]  met_cell,           // 0..234
	output reg  [11:0] met_cell_bcd,
	output reg  [7:0]  met_year_bcd,
	output reg  [3:0]  met_month,
	output reg         met_repeat,
	output reg  [1:0]  cal_period,
	output reg  [1:0]  games_year,
	output reg  [7:0]  sar_cell,           // 0..222
	output reg  [11:0] sar_cell_bcd,
	output reg  [12:0] sar_glyph,
	output reg  [1:0]  exel_sector,
	output reg  [11:0] next_cell_bcd,
	output reg  [7:0]  next_months_bcd,
	output reg  [12:0] next_glyph,
	output reg  [4:0]  parapegma_index,
	output reg         eclipse_season,
	output reg  [4:0]  retrograde,
	output reg  [19:0] crank_bcd,
	output reg         crank_negative,
	output reg         done
);

`include "am_tables.svh"

function automatic [19:0] frac_of(input integer i);
	frac_of = fracs[i*20 +: 20];
endfunction

function automatic [23:0] bcd6(input [19:0] bin);
	integer k, d;
	reg [43:0] s;
	begin
		s = {24'd0, bin};
		for(k = 0; k < 20; k = k + 1) begin
			for(d = 0; d < 6; d = d + 1)
				if(s[20 + d*4 +: 4] >= 5) s[20 + d*4 +: 4] = s[20 + d*4 +: 4] + 4'd3;
			s = s << 1;
		end
		bcd6 = s[43:20];
	end
endfunction

function automatic [3:0] sign_of(input [8:0] deg);
	sign_of = deg >= 330 ? 4'd11 : deg >= 300 ? 4'd10 : deg >= 270 ? 4'd9 : deg >= 240 ? 4'd8 :
	          deg >= 210 ? 4'd7 : deg >= 180 ? 4'd6 : deg >= 150 ? 4'd5 : deg >= 120 ? 4'd4 :
	          deg >= 90 ? 4'd3 : deg >= 60 ? 4'd2 : deg >= 30 ? 4'd1 : 4'd0;
endfunction

function automatic [3:0] lunar_month_of(input [8:0] idx);
	lunar_month_of = idx >= 325 ? 4'd11 : idx >= 295 ? 4'd10 : idx >= 266 ? 4'd9 : idx >= 236 ? 4'd8 :
	                 idx >= 207 ? 4'd7 : idx >= 177 ? 4'd6 : idx >= 148 ? 4'd5 : idx >= 118 ? 4'd4 :
	                 idx >= 89 ? 4'd3 : idx >= 59 ? 4'd2 : idx >= 30 ? 4'd1 : 4'd0;
endfunction

function automatic [8:0] lunar_month_start(input [3:0] m);
	case(m)
		0: lunar_month_start = 0;    1: lunar_month_start = 30;   2: lunar_month_start = 59;
		3: lunar_month_start = 89;   4: lunar_month_start = 118;  5: lunar_month_start = 148;
		6: lunar_month_start = 177;  7: lunar_month_start = 207;  8: lunar_month_start = 236;
		9: lunar_month_start = 266;  10: lunar_month_start = 295; default: lunar_month_start = 325;
	endcase
endfunction

// Shared restoring divider, 32 / 16 bits.
reg div_start;
reg [31:0] div_a;
reg [15:0] div_b;
reg [31:0] div_q;
reg [15:0] div_r;
reg [5:0] div_count;
reg div_busy;
wire [16:0] div_trial = {div_r, div_q[31]};
always @(posedge clk) begin
	if(div_start) begin
		div_busy <= 1;
		div_count <= 0;
		div_q <= div_a;
		div_r <= 0;
	end else if(div_busy) begin
		if(div_trial >= {1'b0, div_b}) begin
			div_r <= 16'(div_trial - {1'b0, div_b});
			div_q <= {div_q[30:0], 1'b1};
		end else begin
			div_r <= div_trial[15:0];
			div_q <= {div_q[30:0], 1'b0};
		end
		if(div_count == 31) div_busy <= 0;
		div_count <= div_count + 1'b1;
	end
end

reg [19:0] bcd_in;
wire [23:0] bcd_out = bcd6(bcd_in);

reg [6:0] state;
reg [3:0] body;
reg [7:0] scan;
reg [23:0] jdn;
reg signed [23:0] day_count;
reg [25:0] e_value;
reg [15:0] q1, r1, q2, r2;
reg [3:0] m0;
reg signed [15:0] year;
reg [8:0] egy_index;
reg [19:0] lon_sel;
reg [28:0] deg_product;
reg [8:0] deg360;
reg [3:0] sign_sel;
reg [19:0] prev_lon [0:4];
reg [34:0] age_product;
reg [27:0] cell_product;
reg [19:0] ring_pos;
reg [28:0] ring_product;
reg [19:0] ring_lunar_term;
wire signed [39:0] tick_sum = ticks + $signed({24'd0, epoch_tick_offset(epoch)});
wire [19:0] wrap_a = lon_sun - lon_node;
wire [19:0] wrap_b = lon_sun - lon_node + 20'h80000;
wire [19:0] dist_a = wrap_a[19] ? -wrap_a : wrap_a;
wire [19:0] dist_b = wrap_b[19] ? -wrap_b : wrap_b;
reg [19:0] planet_lon;
always @* begin
	case(body)
		0: lon_sel = frac_of(SH_SUN_MEAN);
		1: lon_sel = lon_sun;
		2: lon_sel = lon_moon;
		3: lon_sel = lon_node;
		4: lon_sel = lon_mercury;
		5: lon_sel = lon_venus;
		6: lon_sel = lon_mars;
		7: lon_sel = lon_jupiter;
		default: lon_sel = lon_saturn;
	endcase
	case(body)
		0: planet_lon = lon_mercury;
		1: planet_lon = lon_venus;
		2: planet_lon = lon_mars;
		3: planet_lon = lon_jupiter;
		default: planet_lon = lon_saturn;
	endcase
end
wire [19:0] planet_delta = planet_lon - prev_lon[body[2:0]];
wire [7:0] next_cell = (sar_cell + scan >= 223) ? sar_cell + scan - 8'd223 : sar_cell + scan;
wire [9:0] met_info_now = metonic_info(met_cell);
wire [19:0] frac_callippic = frac_of(SH_CALLIPPIC);
wire [19:0] frac_games = frac_of(SH_GAMES);
wire [12:0] scan_glyph = saros_glyph(next_cell);

integer p;
always @(posedge clk) begin
	div_start <= 0;
	done <= 0;
	if(reset || clear) begin
		state <= 0;
		retrograde <= 0;
		for(p = 0; p < 5; p = p + 1) prev_lon[p] <= 0;
	end else case(state)
		0: if(start) state <= 1;
		// Julian calendar from the day count.
		1: begin
			day_count <= tick_sum[39:16];
			state <= 2;
		end
		2: begin
			jdn <= epoch_jdn(epoch) + 24'(day_count);
			state <= 3;
		end
		3: begin
			e_value <= 26'((jdn + 24'd1402) * 4 + 3);
			state <= 4;
		end
		4: begin
			div_a <= {6'd0, e_value};
			div_b <= 16'd1461;
			div_start <= 1;
			state <= 5;
		end
		5: if(!div_busy && !div_start) begin
			q1 <= div_q[15:0];
			div_a <= 32'(((div_r >> 2) * 5) + 2);     // h = 5g + 2
			div_b <= 16'd153;
			div_start <= 1;
			state <= 6;
		end
		6: if(!div_busy && !div_start) begin
			q2 <= div_q[15:0];
			r2 <= div_r;
			div_a <= {16'd0, div_r};
			div_b <= 16'd5;
			div_start <= 1;
			state <= 7;
		end
		7: if(!div_busy && !div_start) begin
			bcd_in <= 20'(div_q[7:0] + 8'd1);
			m0 <= (q2[3:0] + 4'd2 >= 12) ? q2[3:0] + 4'd2 - 4'd12 : q2[3:0] + 4'd2;
			state <= 8;
		end
		8: begin
			jul_day_bcd <= bcd_out[7:0];
			jul_month <= m0;
			year <= $signed({1'b0, q1[14:0]}) - 16'sd4716 + (m0 < 2 ? 16'sd1 : 16'sd0);
			state <= 9;
		end
		9: begin
			jul_bc <= year <= 0;
			bcd_in <= year <= 0 ? 20'(16'sd1 - year) : 20'(year);
			state <= 10;
		end
		10: begin
			jul_year_bcd <= bcd_out[15:0];
			// Egyptian civil calendar: days since Thoth 1 of Nabonassar year 1.
			div_a <= 32'(jdn - NABONASSAR_JDN + 24'(epoch_egyptian_adjust(epoch)));
			div_b <= 16'd365;
			div_start <= 1;
			state <= 11;
		end
		11: if(!div_busy && !div_start) begin
			egy_index <= div_r[8:0];
			// Centre of the current day division, as a fraction of a turn.
			div_a <= {3'd0, div_r[8:0], 1'b1, 19'd0};      // (2q + 1) << 19
			div_b <= 16'd365;
			div_start <= 1;
			ring_lunar_term <= 20'(((lon_phase * 17'd87462) >> 20) + 20'd1481);
			state <= 12;
		end
		12: if(!div_busy && !div_start) begin
			if(!ring_auto) ring_offset <= ring_manual;
			else if(ring_lunar) ring_offset <= frac_of(SH_SUN_MEAN) - ring_lunar_term;
			else ring_offset <= frac_of(SH_SUN_MEAN) - div_q[19:0];
			state <= 13;
		end
		13: begin
			ring_pos <= frac_of(SH_SUN_MEAN) - ring_offset;
			state <= 14;
		end
		14: begin
			ring_product <= ring_pos * (ring_lunar ? 9'd354 : 9'd365);
			state <= 15;
		end
		15: begin
			ring_index <= ring_product[28:20];
			state <= 16;
		end
		16: begin
			if(ring_lunar) begin
				egy_month <= lunar_month_of(ring_index);
				bcd_in <= 20'(ring_index - lunar_month_start(lunar_month_of(ring_index)) + 9'd1);
			end else begin
				egy_month <= ring_index >= 360 ? 4'd12 : ring_index >= 330 ? 4'd11 : ring_index >= 300 ? 4'd10 :
				             ring_index >= 270 ? 4'd9 : ring_index >= 240 ? 4'd8 : ring_index >= 210 ? 4'd7 :
				             ring_index >= 180 ? 4'd6 : ring_index >= 150 ? 4'd5 : ring_index >= 120 ? 4'd4 :
				             ring_index >= 90 ? 4'd3 : ring_index >= 60 ? 4'd2 : ring_index >= 30 ? 4'd1 : 4'd0;
				bcd_in <= 20'(ring_index >= 360 ? ring_index - 9'd359 :
				              ring_index - 9'(ring_index >= 330 ? 330 : ring_index >= 300 ? 300 : ring_index >= 270 ? 270 :
				              ring_index >= 240 ? 240 : ring_index >= 210 ? 210 : ring_index >= 180 ? 180 :
				              ring_index >= 150 ? 150 : ring_index >= 120 ? 120 : ring_index >= 90 ? 90 :
				              ring_index >= 60 ? 60 : ring_index >= 30 ? 30 : 0) + 9'd1);
			end
			body <= 0;
			state <= 17;
		end
		17: begin
			egy_day_bcd <= bcd_out[7:0];
			state <= 18;
		end
		// Zodiac sign and degree of each body.
		18: begin
			deg_product <= lon_sel * 9'd360;
			state <= 19;
		end
		19: begin
			deg360 <= deg_product[28:20];
			state <= 20;
		end
		20: begin
			sign_sel <= sign_of(deg360);
			bcd_in <= 20'(deg360 - 9'(sign_of(deg360) * 30));
			state <= 21;
		end
		21: begin
			body_sign[body*4 +: 4] <= sign_sel;
			body_deg[body*8 +: 8] <= bcd_out[7:0];
			if(body == 8) begin
				body <= 0;
				state <= 22;
			end else begin
				body <= body + 1'b1;
				state <= 18;
			end
		end
		// Moon phase and age.
		22: begin
			phase_index <= lon_phase[19:17] + {2'd0, lon_phase[16]};
			age_product <= lon_phase * 15'd30239;
			state <= 23;
		end
		23: begin
			bcd_in <= {15'd0, age_product[34:30]};
			state <= 24;
		end
		24: begin
			age_bcd <= bcd_out[7:0];
			met_cell <= met_cell_in;
			bcd_in <= 20'(met_cell_in + 8'd1);
			state <= 25;
		end
		25: begin
			met_cell_bcd <= bcd_out[11:0];
			bcd_in <= {15'd0, met_info_now[9:5]};
			met_month <= met_info_now[4:1];
			met_repeat <= met_info_now[0];
			cal_period <= frac_callippic[19:18];
			games_year <= frac_games[19:18];
			state <= 26;
		end
		26: begin
			met_year_bcd <= bcd_out[7:0];
			sar_cell <= sar_cell_in;
			bcd_in <= 20'(sar_cell_in + 8'd1);
			cell_product <= frac_of(SH_EXELIGMOS) * 8'd3;
			state <= 27;
		end
		27: begin
			sar_cell_bcd <= bcd_out[11:0];
			sar_glyph <= saros_glyph(sar_cell);
			exel_sector <= cell_product[21:20];
			scan <= 1;
			state <= 28;
		end
		// Next cell carrying an eclipse glyph.
		28: begin
			if(scan_glyph != 0 || scan == 223) begin
				next_glyph <= scan_glyph;
				bcd_in <= 20'(next_cell + 8'd1);
				state <= 29;
			end else scan <= scan + 1'b1;
		end
		29: begin
			next_cell_bcd <= bcd_out[11:0];
			bcd_in <= {12'd0, scan};
			state <= 30;
		end
		30: begin
			next_months_bcd <= bcd_out[7:0];
			parapegma_index <= 5'(NPARAPEGMA - 1);
			scan <= 0;
			state <= 31;
		end
		// Last parapegma event passed by the Sun (positions are sorted).
		31: begin
			if(parapegma_pos(scan) <= lon_sun[19:8]) parapegma_index <= scan[4:0];
			if(scan == NPARAPEGMA - 1) begin
				scan <= 0;
				body <= 0;
				state <= 32;
			end else scan <= scan + 1'b1;
		end
		32: begin
			eclipse_season <= (dist_a < 20'd49516) || (dist_b < 20'd49516);
			state <= 33;
		end
		// Retrograde flags from the change since the previous frame.
		33: begin
			if(planet_delta != 0) begin
				retrograde[body[2:0]] <= last_forward ? planet_delta[19] : !planet_delta[19];
				prev_lon[body[2:0]] <= planet_lon;
			end
			if(body == 4) begin
				body <= 0;
				state <= 34;
			end else body <= body + 1'b1;
		end
		34: begin
			crank_negative <= crank_turns[19];
			bcd_in <= crank_turns[19] ? -crank_turns : crank_turns;
			state <= 35;
		end
		35: begin
			crank_bcd <= bcd_out[19:0];
			done <= 1;
			state <= 0;
		end
		default: state <= 0;
	endcase
end

endmodule
