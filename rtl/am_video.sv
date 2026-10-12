// SPDX-License-Identifier: GPL-2.0-or-later
// 640x480 picture, drawn once per field. Two rasters from the 50 MHz clock:
// 15 kHz interlaced (two fields of 240 lines, pixel enable every fourth
// clock) for analog displays, or 31 kHz progressive (pixel enable every
// second clock) when MiSTer.ini asks for a scandoubler or the menu does.
// Every pixel is converted to polar coordinates about the dial it belongs
// to by a pipelined CORDIC; rings, spirals, pointers and the curved dial
// inscriptions are then comparisons on radius and angle. All registers in
// this module are enabled by the pixel clock enable, so the logic between
// them has at least two 50 MHz cycles (see the .sdc).
(* multstyle = "logic" *)
module am_video (
	input  wire        clk,
	input  wire        progressive,
	input  wire [1:0]  view,
	input  wire        help,
	input  wire        eclipse_pulse,
	input  wire [20*24-1:0] fracs_in,
	input  wire [19:0] lon_date_in, lon_sun_in, lon_moon_in, lon_phase_in, lon_node_in,
	input  wire [19:0] lon_mercury_in, lon_venus_in, lon_mars_in, lon_jupiter_in, lon_saturn_in, moon_anomaly_in,
	input  wire signed [15:0] phase_sin_in, phase_cos_in, moon_sin_in, moon_cos_in,
	input  wire [19:0] ring_offset_in,
	input  wire        ring_lunar,
	input  wire        ring_auto,
	input  wire        cosmos_on,
	input  wire        epoch,
	input  wire        b1_224,
	input  wire        sound_on,
	input  wire        running,
	input  wire        forward,
	input  wire [2:0]  speed,
	input  wire [7:0]  jul_day_bcd_in,
	input  wire [3:0]  jul_month_in,
	input  wire [15:0] jul_year_bcd_in,
	input  wire        jul_bc_in,
	input  wire [3:0]  egy_month_in,
	input  wire [7:0]  egy_day_bcd_in,
	input  wire [35:0] body_sign_in,
	input  wire [71:0] body_deg_in,
	input  wire [2:0]  phase_index_in,
	input  wire [7:0]  age_bcd_in,
	input  wire [7:0]  met_cell_in,
	input  wire [11:0] met_cell_bcd_in,
	input  wire [7:0]  met_year_bcd_in,
	input  wire [3:0]  met_month_in,
	input  wire        met_repeat_in,
	input  wire [1:0]  cal_period_in,
	input  wire [1:0]  games_year_in,
	input  wire [7:0]  sar_cell_in,
	input  wire [11:0] sar_cell_bcd_in,
	input  wire [12:0] sar_glyph_in,
	input  wire [1:0]  exel_sector_in,
	input  wire [11:0] next_cell_bcd_in,
	input  wire [7:0]  next_months_bcd_in,
	input  wire [12:0] next_glyph_in,
	input  wire [4:0]  parapegma_index_in,
	input  wire        eclipse_season_in,
	input  wire [4:0]  retrograde_in,
	input  wire [19:0] crank_bcd_in,
	input  wire        crank_negative_in,
	output reg         ce_pixel = 0,
	output reg  [7:0]  red = 0,
	output reg  [7:0]  green = 0,
	output reg  [7:0]  blue = 0,
	output reg         hsync = 1,      // negative pulses (VGA polarity)
	output reg         vsync = 1,
	output reg         de = 0,
	output reg         hblank = 1,     // positive, for the framework's video_mixer
	output reg         vblank = 1,
	output reg         field = 0,      // second field of an interlaced frame
	output wire        frame_start
);

`include "am_tables.svh"

localparam integer POLAR_STAGES = 13;
localparam integer POLAR_LATENCY = POLAR_STAGES + 3;
localparam integer LAT = POLAR_LATENCY + 1;
localparam integer QDEPTH = LAT + 3;

// Palette.
localparam [23:0] CASE = 24'h0b1416, PANEL = 24'h152426, RULE = 24'h536356;
localparam [23:0] BRONZE = 24'ha07a46, BRONZE_DK = 24'h6e5230, BRONZE_LT = 24'hc9a66b, BRONZE_MID = 24'h8a683c;
localparam [23:0] BRONZE_ALT = 24'hb8955c, ENGRAVE = 24'h3b2a16, GOLD = 24'hf2c45c, SILVER = 24'hdfe3e6, LIGHT = 24'hecdbad;
localparam [23:0] MUTED = 24'h8a9a92, RED = 24'hdf7251, GREEN = 24'h8fd4a4, PAPER = 24'hecdec0;
localparam [23:0] LAPIS = 24'h2f5fd0, TURQUOISE = 24'h45c8cc, ONYX = 24'hc8432a, OBSIDIAN = 24'h1c1c22;
localparam [23:0] CRYSTAL = 24'hf0f4f8, DRAGON = 24'h2e6a3e, MOON_W = 24'hf6f6f2, MOON_B = 24'h141414;
localparam [23:0] LUNAR_CELL = 24'hb9c6cf, SOLAR_CELL = 24'he6bd5a, TRACK = 24'h7c5e38, WHITE = 24'hffffff;

// ---------------------------------------------------------------------------
// Raster: 800 pixels per line in both modes.
// ---------------------------------------------------------------------------
reg prog_r = 1;
reg [1:0] cdiv = 0;
wire ce = prog_r ? cdiv[0] : (cdiv == 2'd3);
reg [9:0] h = 0, line = 0;
wire [9:0] lines_in_field = prog_r ? 10'd525 : (field ? 10'd263 : 10'd262);
wire [9:0] visible_lines = prog_r ? 10'd480 : 10'd240;
wire [9:0] frame_line = prog_r ? line : {line[8:0], field};
wire hs_now = prog_r ? (h >= 656 && h < 752) : (h >= 660 && h < 720);
wire vs_now = prog_r ? (line >= 490 && line < 492) :
              field ? ((line == 245 && h >= 400) || line == 246 || line == 247 || (line == 248 && h < 400))
                    : (line >= 245 && line < 248);
assign frame_start = h == 0 && line == visible_lines && ce;
wire snapshot = h == 0 && line == visible_lines + 10'd6 && ce;

// ---------------------------------------------------------------------------
// Per-field snapshot of the mechanism state.
// ---------------------------------------------------------------------------
reg [20*24-1:0] fracs;
reg [19:0] lon_date, lon_sun, lon_moon, lon_phase, lon_node;
reg [19:0] lon_mercury, lon_venus, lon_mars, lon_jupiter, lon_saturn, moon_anomaly;
reg signed [15:0] phase_sin, phase_cos, moon_sin, moon_cos;
reg [19:0] ring_offset;
reg [7:0] jul_day_bcd; reg [3:0] jul_month; reg [15:0] jul_year_bcd; reg jul_bc;
reg [3:0] egy_month; reg [7:0] egy_day_bcd;
reg [35:0] body_sign; reg [71:0] body_deg;
reg [2:0] phase_index; reg [7:0] age_bcd;
reg [7:0] met_cell; reg [11:0] met_cell_bcd; reg [7:0] met_year_bcd; reg [3:0] met_month; reg met_repeat;
reg [1:0] cal_period, games_year;
reg [7:0] sar_cell; reg [11:0] sar_cell_bcd; reg [12:0] sar_glyph; reg [1:0] exel_sector;
reg [11:0] next_cell_bcd; reg [7:0] next_months_bcd; reg [12:0] next_glyph;
reg [4:0] parapegma_index; reg eclipse_season; reg [4:0] retrograde;
reg [19:0] crank_bcd; reg crank_negative;
reg signed [10:0] ball_x, ball_y;
reg [7:0] flash = 0;                 // fields of eclipse announcement left
reg pulse_latch = 0;
wire signed [31:0] ball_sx = R_MOON * moon_sin_in;
wire signed [31:0] ball_sy = R_MOON * moon_cos_in;

always @(posedge clk) begin
	if(eclipse_pulse) pulse_latch <= 1;
	if(snapshot) begin
		pulse_latch <= 0;
		if(pulse_latch) flash <= 8'd180;
		else if(flash != 0) flash <= flash - 1'b1;
		fracs <= fracs_in;
		lon_date <= lon_date_in; lon_sun <= lon_sun_in; lon_moon <= lon_moon_in; lon_phase <= lon_phase_in;
		lon_node <= lon_node_in; lon_mercury <= lon_mercury_in; lon_venus <= lon_venus_in; lon_mars <= lon_mars_in;
		lon_jupiter <= lon_jupiter_in; lon_saturn <= lon_saturn_in; moon_anomaly <= moon_anomaly_in;
		phase_sin <= phase_sin_in; phase_cos <= phase_cos_in; moon_sin <= moon_sin_in; moon_cos <= moon_cos_in;
		ring_offset <= ring_offset_in;
		jul_day_bcd <= jul_day_bcd_in; jul_month <= jul_month_in; jul_year_bcd <= jul_year_bcd_in; jul_bc <= jul_bc_in;
		egy_month <= egy_month_in; egy_day_bcd <= egy_day_bcd_in;
		body_sign <= body_sign_in; body_deg <= body_deg_in;
		phase_index <= phase_index_in; age_bcd <= age_bcd_in;
		met_cell <= met_cell_in; met_cell_bcd <= met_cell_bcd_in; met_year_bcd <= met_year_bcd_in;
		met_month <= met_month_in; met_repeat <= met_repeat_in;
		cal_period <= cal_period_in; games_year <= games_year_in;
		sar_cell <= sar_cell_in; sar_cell_bcd <= sar_cell_bcd_in; sar_glyph <= sar_glyph_in; exel_sector <= exel_sector_in;
		next_cell_bcd <= next_cell_bcd_in; next_months_bcd <= next_months_bcd_in; next_glyph <= next_glyph_in;
		parapegma_index <= parapegma_index_in; eclipse_season <= eclipse_season_in; retrograde <= retrograde_in;
		crank_bcd <= crank_bcd_in; crank_negative <= crank_negative_in;
		ball_x <= 11'(FRONT_CX) + 11'(ball_sx >>> 14);
		ball_y <= 11'(FRONT_CY) - 11'(ball_sy >>> 14);
	end
end

wire [19:0] frac_of_met = fracs[SH_METONIC*20 +: 20];
wire [19:0] frac_of_sar = fracs[SH_SAROS*20 +: 20];
wire [19:0] frac_of_games = fracs[SH_GAMES*20 +: 20];
wire [19:0] frac_of_cal = fracs[SH_CALLIPPIC*20 +: 20];
wire [19:0] frac_of_exel = fracs[SH_EXELIGMOS*20 +: 20];
wire [19:0] frac_of_crank = fracs[SH_CRANK*20 +: 20];

// ---------------------------------------------------------------------------
// Stage 0: which dial (or wheel) does the pixel belong to.
// ---------------------------------------------------------------------------
wire [39:0] ginfo [0:NGEAR-1];
wire [15:0] glabel [0:NGEAR-1];
genvar gi;
generate
	for(gi = 0; gi < NGEAR; gi = gi + 1) begin : gears
		assign ginfo[gi] = gear_info(gi);
		assign glabel[gi] = gear_label(gi);
	end
endgenerate

wire [9:0] v = frame_line;
wire [19:0] axis_d2 [0:NAXIS-1];
generate
	for(gi = 0; gi < NAXIS; gi = gi + 1) begin : axes
		wire [18:0] apos = axis_pos(gi);
		wire signed [10:0] adx = $signed({1'b0, h}) - $signed({1'b0, apos[18:9]});
		wire signed [10:0] ady = $signed({1'b0, v}) - $signed({1'b0, apos[8:0]});
		assign axis_d2[gi] = 20'(adx * adx) + 20'(ady * ady);
	end
endgenerate

integer k;
reg [5:0] best_gear;
reg [7:0] best_r;
reg outline_hit;
reg [19:0] gd2;
reg [6:0] gr;
always @* begin
	best_gear = 6'd31;
	best_r = 8'd255;
	outline_hit = 0;
	for(k = 0; k < NGEAR; k = k + 1) begin
		gd2 = axis_d2[gear_axis(k)];
		gr = ginfo[k][20:14];
		if(gd2 <= 20'(gr * gr) && {1'b0, gr} < best_r) begin
			best_r = {1'b0, gr};
			best_gear = 6'(k);
		end
		if(gd2 >= 20'((gr - 7'd1) * (gr - 7'd1)) && gd2 <= 20'((gr + 7'd1) * (gr + 7'd1))) outline_hit = 1;
	end
end

// Small crank dial in the status block of each view.
wire [9:0] crank_cx = view == 1 ? 10'd420 : 10'd612;
wire [9:0] crank_cy = view == 0 ? 10'd296 : view == 1 ? 10'd248 : 10'd164;
wire in_crank_box = h >= crank_cx - 10'd11 && h <= crank_cx + 10'd11 && v >= crank_cy - 10'd11 && v <= crank_cy + 10'd11;

reg [9:0] cx0, cy0;
reg [2:0] region0;
reg [5:0] gear0;
always @* begin
	region0 = 0;
	cx0 = 10'(FRONT_CX); cy0 = 10'(FRONT_CY);
	gear0 = {outline_hit, 5'd31};
	case(view)
		0: begin cx0 = 10'(FRONT_CX); cy0 = 10'(FRONT_CY); end
		1: begin
			if(h >= GAMES_CX - SUB_R - 1 && h <= GAMES_CX + SUB_R + 1 && v >= GAMES_CY - SUB_R - 1 && v <= GAMES_CY + SUB_R + 1) begin
				region0 = 2; cx0 = 10'(GAMES_CX); cy0 = 10'(GAMES_CY);
			end else if(h >= CAL_CX - SUB_R - 1 && h <= CAL_CX + SUB_R + 1 && v >= CAL_CY - SUB_R - 1 && v <= CAL_CY + SUB_R + 1) begin
				region0 = 3; cx0 = 10'(CAL_CX); cy0 = 10'(CAL_CY);
			end else if(h >= EXEL_CX - SUB_R - 1 && h <= EXEL_CX + SUB_R + 1 && v >= EXEL_CY - SUB_R - 1 && v <= EXEL_CY + SUB_R + 1) begin
				region0 = 4; cx0 = 10'(EXEL_CX); cy0 = 10'(EXEL_CY);
			end else if(v < BACK_SPLIT) begin
				region0 = 0; cx0 = 10'(MET_CX); cy0 = 10'(MET_CY);
			end else begin
				region0 = 1; cx0 = 10'(SAR_CX); cy0 = 10'(SAR_CY);
			end
		end
		default: begin
			gear0 = {outline_hit, best_gear[4:0]};
			if(best_gear != 31) begin
				cx0 = ginfo[best_gear][39:30]; cy0 = ginfo[best_gear][29:21];
			end
		end
	endcase
	if(in_crank_box) begin
		region0 = 5; cx0 = crank_cx; cy0 = crank_cy;
	end
end

// Stage 1 registers and the polar pipeline.
reg [9:0] cx1, cy1, h1, v1;
reg signed [10:0] dx1, dy1;
reg [9:0] hq [0:QDEPTH];
reg [9:0] vq [0:QDEPTH];
reg hsq [0:QDEPTH];
reg vsq [0:QDEPTH];
reg visq [0:QDEPTH];
reg hbq [0:QDEPTH];
reg vbq [0:QDEPTH];
reg [2:0] regq [0:QDEPTH];
reg [5:0] gearq [0:QDEPTH];
wire [9:0] radius;
wire [15:0] theta;
am_polar #(.STAGES(POLAR_STAGES)) polar (.clk(clk), .ce(ce), .dx(dx1), .dy(dy1), .radius(radius), .theta(theta));

// Drop shadows: features of the picture line two above, two pixels left.
// Three line buffers rotate per drawn line, so the line being read is never
// the one being written: two drawn lines back when progressive, one when
// interlaced (the previous line of the same field).
reg shadow_mem [0:3071];
reg shadow_read;
reg [1:0] wsel = 0;
wire [1:0] rsel = prog_r ? (wsel == 2'd2 ? 2'd0 : wsel + 2'd1) : (wsel == 2'd0 ? 2'd2 : wsel - 2'd1);
wire [9:0] hd = hq[LAT];
wire [9:0] vd = vq[LAT];
wire [9:0] h_ahead = hq[LAT-1];
wire [11:0] shadow_raddr = {rsel, h_ahead - 10'd2};
reg casts;

// ---------------------------------------------------------------------------
// Drawing stage (queue index LAT).
// ---------------------------------------------------------------------------
wire [2:0] region = regq[LAT];
wire [5:0] gear = gearq[LAT];
wire [9:0] r = radius;
wire [15:0] th = theta;
wire [15:0] t1 = angle_per_pixel(r[8:0]);
wire [16:0] t2 = {t1, 1'b0};
wire [17:0] t3 = {t1, 1'b0} + {2'b0, t1};
wire [17:0] t4 = {t1, 2'b0};
wire [19:0] r2 = r * r;
wire [3:0] grain = lathe_noise(r[8:0]);

function automatic [15:0] angdist(input [15:0] a, input [15:0] b);
	reg [15:0] d;
	begin
		d = a - b;
		angdist = d[15] ? -d : d;
	end
endfunction

function automatic [7:0] hour_bcd(input [3:0] hour);
	hour_bcd = hour >= 10 ? {4'd1, 4'(hour - 4'd10)} : {4'd0, hour};
endfunction

// Turned-metal grain: a few levels of brightness in fine concentric rings.
function automatic [23:0] textured(input [23:0] color, input [3:0] g);
	reg [8:0] cr, cg, cb;
	begin
		cr = {1'b0, color[23:16]} + {5'd0, g} - 9'd8;
		cg = {1'b0, color[15:8]} + {5'd0, g} - 9'd8;
		cb = {1'b0, color[7:0]} + {5'd0, g} - 9'd8;
		textured = {cr[7:0], cg[7:0], cb[7:0]};
	end
endfunction

function automatic [23:0] shaded(input [23:0] color);
	shaded = {color[23:16] - color[23:18], color[15:8] - color[15:10], color[7:0] - color[7:2]};
endfunction

function automatic [23:0] brighter(input [23:0] color, input [5:0] amount);
	reg [8:0] cr, cg, cb;
	begin
		cr = {1'b0, color[23:16]} + {3'd0, amount};
		cg = {1'b0, color[15:8]} + {3'd0, amount};
		cb = {1'b0, color[7:0]} + {3'd0, amount};
		brighter = {cr[8] ? 8'hff : cr[7:0], cg[8] ? 8'hff : cg[7:0], cb[8] ? 8'hff : cb[7:0]};
	end
endfunction

// Text column grid: every string starts on a multiple of 6 pixels.
wire [9:0] tcol_w = hd / 10'd6;
wire [6:0] tcol = tcol_w[6:0];
wire [2:0] tx = 3'(hd - 10'(tcol * 6));

reg [23:0] background;
reg [23:0] foreground;
reg [11:0] char_addr;
reg direct;
reg [7:0] direct_code;
reg [2:0] glyph_x, glyph_y;
reg text_hit;
reg [15:0] ring_angle;
reg [7:0] ring_chars;
reg [11:0] ring_base;
reg [9:0] ring_top;
reg ring_active;
wire [23:0] ring_product = ring_angle * ring_chars;
wire [7:0] ring_char = ring_product[23:16];
wire [18:0] ring_col6 = ring_product[15:0] * 3'd6;
wire [2:0] ring_col = ring_col6[18:16];

task automatic text_rom(input integer col, top, length, base, input [23:0] color);
	begin
		if(tcol >= 7'(col) && tcol < 7'(col + length) && vd >= 10'(top) && vd < 10'(top + 8)) begin
			char_addr = 12'(base + int'(tcol) - col);
			glyph_x = tx;
			glyph_y = 3'(vd - 10'(top));
			foreground = color;
			text_hit = 1;
			direct = 0;
		end
	end
endtask

// Double-size text: 12 x 16 pixel cells.
task automatic text_rom2(input integer col, top, length, base, input [23:0] color);
	reg [6:0] rel;
	begin
		rel = 0;
		if(tcol >= 7'(col) && tcol < 7'(col + 2 * length) && vd >= 10'(top) && vd < 10'(top + 16)) begin
			rel = tcol - 7'(col);
			char_addr = 12'(base + int'(rel[6:1]));
			glyph_x = rel[0] ? 3'(3'd3 + {1'b0, tx[2:1]}) : {1'b0, tx[2:1]};
			glyph_y = 3'((vd - 10'(top)) >> 1);
			foreground = color;
			text_hit = 1;
			direct = 0;
		end
	end
endtask

task automatic text_table(input integer col, top, length, base, input [7:0] index, input integer stride, input [23:0] color);
	begin
		text_rom(col, top, length, base + int'(index) * stride, color);
	end
endtask

task automatic text_code(input integer col, top, input [7:0] code, input [23:0] color);
	begin
		if(tcol == 7'(col) && vd >= 10'(top) && vd < 10'(top + 8)) begin
			direct_code = code;
			direct = 1;
			glyph_x = tx;
			glyph_y = 3'(vd - 10'(top));
			foreground = color;
			text_hit = 1;
		end
	end
endtask

task automatic text_digits(input integer col, top, digits, input [23:0] value, input [23:0] color, input blank);
	integer d;
	reg [3:0] nib;
	reg leading;
	begin
		if(vd >= 10'(top) && vd < 10'(top + 8) && tcol >= 7'(col) && tcol < 7'(col + digits)) begin
			d = digits - 1 - (int'(tcol) - col);
			nib = value[d*4 +: 4];
			leading = blank && d != 0 && (value >> (d*4)) == 0;
			direct_code = leading ? 8'h20 : 8'h30 + {4'd0, nib};
			direct = 1;
			glyph_x = tx;
			glyph_y = 3'(vd - 10'(top));
			foreground = color;
			text_hit = 1;
		end
	end
endtask

// Dial scales.
wire [15:0] th_egy = th - ring_offset[19:4];
wire [24:0] egy_prod = th_egy * (ring_lunar ? 9'd354 : 9'd365);
wire [8:0] egy_day = egy_prod[24:16];
wire [15:0] egy_frac = egy_prod[15:0];
wire [24:0] egy_tick_w = t1 * 9'd365;
wire [24:0] zod_prod = th * 9'd360;
wire [15:0] zod_frac = zod_prod[15:0];
wire [21:0] zod36 = th * 6'd36;
wire [19:0] zod12 = th * 4'd12;
wire [24:0] zod_tick_w = t1 * 9'd360;
wire [21:0] zod_tick36 = t1 * 6'd36;
wire [19:0] zod_tick12 = t1 * 4'd12;
wire egy_month_edge = egy_day == 0 || egy_day == 30 || egy_day == 60 || egy_day == 90 || egy_day == 120 ||
                      egy_day == 150 || egy_day == 180 || egy_day == 210 || egy_day == 240 || egy_day == 270 ||
                      egy_day == 300 || egy_day == 330 || egy_day == 360;
wire lun_month_edge = egy_day == 0 || egy_day == 30 || egy_day == 59 || egy_day == 89 || egy_day == 118 ||
                      egy_day == 148 || egy_day == 177 || egy_day == 207 || egy_day == 236 || egy_day == 266 ||
                      egy_day == 295 || egy_day == 325;
wire egy_month_odd = ring_lunar ?
	((egy_day >= 30) ^ (egy_day >= 59) ^ (egy_day >= 89) ^ (egy_day >= 118) ^ (egy_day >= 148) ^ (egy_day >= 177) ^
	 (egy_day >= 207) ^ (egy_day >= 236) ^ (egy_day >= 266) ^ (egy_day >= 295) ^ (egy_day >= 325)) :
	((egy_day >= 30) ^ (egy_day >= 60) ^ (egy_day >= 90) ^ (egy_day >= 120) ^ (egy_day >= 150) ^ (egy_day >= 180) ^
	 (egy_day >= 210) ^ (egy_day >= 240) ^ (egy_day >= 270) ^ (egy_day >= 300) ^ (egy_day >= 330) ^ (egy_day >= 360));
wire zod_sign_odd = zod12[16];

// Spirals: u = turns of the spiral at this radius minus the angle.
wire [9:0] r_in = r - 10'(MET_R0);
wire [15:0] th_met = th + 16'h8000;                 // Metonic starts at the bottom
wire [18:0] met_ru = r_in[6:0] * 13'(MET_PITCH_INV);
wire [18:0] sar_ru = r_in[6:0] * 13'(SAR_PITCH_INV);
wire signed [19:0] met_u = $signed({1'b0, met_ru}) - $signed({4'd0, th_met});
wire signed [19:0] sar_u = $signed({1'b0, sar_ru}) - $signed({4'd0, th});
wire met_valid = !met_u[19] && met_u[18:16] < 5 && r <= MET_R1 + 1;
wire sar_valid = !sar_u[19] && sar_u[18:16] < 4 && r <= SAR_R1 + 1;
wire [2:0] met_turn = met_u[18:16];
wire [1:0] sar_turn = sar_u[17:16];
wire [18:0] met_total = {met_turn, th_met};
wire [17:0] sar_total = {sar_turn, th};
wire [24:0] met_cells = met_total * 6'd47;
wire [25:0] sar_cells = sar_total * 8'd223;
wire [7:0] met_pix_cell = met_cells[23:16];
wire [15:0] met_cell_frac = met_cells[15:0];
wire [7:0] sar_pix_cell = sar_cells[25:18];
wire [15:0] sar_cell_frac = sar_cells[17:2];
wire [9:0] met_info = metonic_info(met_pix_cell);
wire [12:0] sar_pix_glyph = saros_glyph(sar_pix_cell);
wire [21:0] met_tick_w = t1 * 6'd47;
wire [21:0] sar_tick_w = t1 * 6'd56;
wire [22:0] met_pointer_total = frac_of_met * 3'd5;
wire [15:0] met_pointer = met_pointer_total[19:4] + 16'h8000;
wire [15:0] sar_pointer = frac_of_sar[17:2];
wire [25:0] met_follow = frac_of_met * 6'(SPIRAL_SPAN);
wire [25:0] sar_follow = frac_of_sar * 6'(SPIRAL_SPAN);
wire [9:0] met_follow_r = 10'(MET_R0) + 10'(met_follow[25:20]);
wire [9:0] sar_follow_r = 10'(SAR_R0) + 10'(sar_follow[25:20]);
wire [15:0] games_pointer = 16'h8000 - frac_of_games[19:4];
wire [15:0] cal_pointer = 16'h8000 + frac_of_cal[19:4];
wire [15:0] exel_pointer = frac_of_exel[19:4] + 16'd5461;
wire [15:0] crank_pointer = frac_of_crank[19:4];
wire cell_pulse = flash != 0 && flash[3];

// Moon phase ball.
wire signed [10:0] ex = $signed({1'b0, hd}) - ball_x;
wire signed [10:0] ey = $signed({1'b0, vd}) - ball_y;
wire signed [21:0] ex2 = ex * ex;
wire signed [21:0] ey2 = ey * ey;
wire signed [21:0] ball_d2 = ex2 + ey2;
wire in_ball = ball_d2 <= 22'sd49;
wire signed [27:0] t_perp_w = ex * moon_cos + ey * moon_sin;
wire signed [13:0] t_perp = t_perp_w[27:14];
wire [3:0] t_abs = t_perp[13] ? 4'(-t_perp[3:0]) : t_perp[3:0];
function automatic [3:0] ball_z(input [3:0] t);
	case(t)
		0: ball_z = 7; 1: ball_z = 7; 2: ball_z = 7; 3: ball_z = 6; 4: ball_z = 6;
		5: ball_z = 5; 6: ball_z = 4; default: ball_z = 0;
	endcase
endfunction
wire signed [27:0] lit_w = t_perp * phase_sin - $signed({10'd0, ball_z(t_abs)}) * phase_cos;
wire ball_lit = lit_w > 0;

// Gear view: angle and band of the selected wheel.
wire [39:0] gsel = ginfo[gear[4:0] == 31 ? 0 : gear[4:0]];
wire [4:0] gshaft = gsel[5:1];
wire gdir = gsel[0];
reg [19:0] gear_angle;
always @* begin
	case(gshaft)
		SH_MOON_TRUE: gear_angle = lon_moon;
		SH_N: gear_angle = met_pointer_total[19:0];
		SH_G: gear_angle = {frac_of_sar[17:0], 2'b0};
		SH_K1: gear_angle = fracs[SH_APSIDES*20 +: 20] - fracs[SH_MOON_ANOMALY*20 +: 20];
		SH_K2: gear_angle = fracs[SH_APSIDES*20 +: 20] - fracs[SH_MOON_ANOMALY*20 +: 20] - moon_anomaly;
		default: gear_angle = gshaft < NSHAFT ? fracs[gshaft*20 +: 20] : 20'd0;
	endcase
	if(!gdir) gear_angle = -gear_angle;
end
wire [15:0] gear_mark = gear_angle[19:4];
wire [6:0] gear_r = gsel[20:14];
reg [6:0] gear_band_in;
always @* begin
	gear_band_in = 0;
	for(k = 0; k < NGEAR; k = k + 1)
		if(ginfo[k][39:21] == gsel[39:21] && ginfo[k][20:14] < gear_r && ginfo[k][20:14] > gear_band_in)
			gear_band_in = ginfo[k][20:14];
end

function automatic [23:0] gear_fill(input [4:0] shaft);
	case(shaft)
		SH_CRANK: gear_fill = 24'h8a7a5a;
		SH_SUN_MEAN: gear_fill = 24'h9c7a3c;
		SH_MOON_MEAN, SH_C, SH_D, SH_MOON_TRUE: gear_fill = 24'h8c8c8c;
		SH_K1, SH_K2, SH_APSIDES: gear_fill = 24'h5a7a9c;
		SH_M, SH_N, SH_P, SH_GAMES, SH_CALLIPPIC: gear_fill = 24'h9a8a58;
		default: gear_fill = 24'h8c6a6a;
	endcase
endfunction

// Stones on the Cosmos rings: 0 outside, 1 stone, 2 highlight.
function automatic [1:0] bead(input [15:0] a, input [9:0] rr, input [15:0] lon, input integer ring);
	reg [9:0] dr;
	reg on_stone;
	begin
		dr = rr > 10'(ring) ? rr - 10'(ring) : 10'(ring) - rr;
		on_stone = (dr == 0 && {2'b0, angdist(a, lon)} <= t4) ||
		         (dr <= 2 && dr != 0 && {2'b0, angdist(a, lon)} <= t3) ||
		         (dr <= 4 && dr > 2 && {3'b0, angdist(a, lon)} <= {2'b0, t2});
		bead = !on_stone ? 2'd0 : (rr < 10'(ring) && dr <= 2 && angdist(a, lon - t1) <= t1) ? 2'd2 : 2'd1;
	end
endfunction

function automatic sunray(input [15:0] a, input [9:0] rr, input [15:0] lon, input integer ring);
	reg [9:0] dr;
	begin
		dr = rr > 10'(ring) ? rr - 10'(ring) : 10'(ring) - rr;
		sunray = dr >= 5 && dr <= 8 && (angdist(a, lon) <= t1 || angdist(a, lon + 16'd16384) <= t1 ||
		                                angdist(a, lon + 16'd32768) <= t1 || angdist(a, lon + 16'd49152) <= t1);
	end
endfunction

function automatic hairline(input [15:0] a, input [15:0] lon, input [9:0] rr, input integer r_in_, r_out_);
	hairline = rr >= 10'(r_in_) && rr <= 10'(r_out_) && angdist(a, lon) <= t1;
endfunction

// A line of the readout: label, zodiac sign and degrees.
task automatic body_line(input integer col, top, body, label, label_len, input [23:0] color);
	begin
		text_rom(col, top, label_len, label, color);
		text_table(col + 9, top, 11, TAB_ZODIAC_EN, {4'd0, body_sign[body*4 +: 4]}, TAB_ZODIAC_EN_STRIDE, LIGHT);
		text_digits(col + 21, top, 2, {16'd0, body_deg[body*8 +: 8]}, LIGHT, 1);
		text_rom(col + 23, top, 1, STR_L_DEG, LIGHT);
	end
endtask

task automatic glyph_line(input integer col, top, input [12:0] g);
	begin
		if(g == 0) text_rom(col, top, LEN_L_NONE, STR_L_NONE, MUTED);
		else begin
			if(g[11]) begin
				text_rom(col, top, LEN_L_LUNAR, STR_L_LUNAR, LUNAR_CELL);
				text_rom(col + 8, top, LEN_L_HOUR, STR_L_HOUR, MUTED);
				text_digits(col + 10, top, 2, {16'd0, hour_bcd(g[9:6])}, LIGHT, 1);
				if(g[10]) text_rom(col + 13, top, LEN_L_DAY, STR_L_DAY, MUTED);
				else text_rom(col + 13, top, LEN_L_NIGHT, STR_L_NIGHT, MUTED);
			end
			if(g[5]) begin
				text_rom(col + 17, top, LEN_L_SOLAR, STR_L_SOLAR, SOLAR_CELL);
				text_rom(col + 25, top, LEN_L_HOUR, STR_L_HOUR, MUTED);
				text_digits(col + 27, top, 2, {16'd0, hour_bcd(g[3:0])}, LIGHT, 1);
				if(g[4]) text_rom(col + 30, top, LEN_L_DAY, STR_L_DAY, MUTED);
				else text_rom(col + 30, top, LEN_L_NIGHT, STR_L_NIGHT, MUTED);
			end
			if(g[12]) text_rom(col + 34, top, LEN_L_INSCRIBED, STR_L_INSCRIBED, MUTED);
			else text_rom(col + 34, top, LEN_L_MODEL, STR_L_MODEL, MUTED);
		end
	end
endtask

task automatic status_block(input integer col0, top);
	begin
		text_rom(col0, top, LEN_L_CRANK, STR_L_CRANK, MUTED);
		text_rom(col0 + 6, top, LEN_L_TURNS, STR_L_TURNS, MUTED);
		if(crank_negative) text_code(col0 + 12, top, 8'h2d, LIGHT);
		text_digits(col0 + 13, top, 5, {4'd0, crank_bcd}, LIGHT, 1);
		text_rom(col0 + 19, top, LEN_L_B1, STR_L_B1, MUTED);
		text_code(col0 + 22, top, 8'h32, LIGHT);
		text_code(col0 + 23, top, 8'h32, LIGHT);
		text_code(col0 + 24, top, b1_224 ? 8'h34 : 8'h33, LIGHT);
		if(running) text_rom(col0, top + 12, LEN_L_RUN, STR_L_RUN, GREEN);
		else text_rom(col0, top + 12, LEN_L_PAUSED, STR_L_PAUSED, LIGHT);
		text_table(col0 + 10, top + 12, 11, TAB_SPEED, {5'd0, speed}, TAB_SPEED_STRIDE, MUTED);
		if(!forward) text_rom(col0 + 22, top + 12, LEN_L_BACK, STR_L_BACK, RED);
		if(epoch) text_rom(col0, top + 24, LEN_L_EP178, STR_L_EP178, MUTED);
		else text_rom(col0, top + 24, LEN_L_EP205, STR_L_EP205, MUTED);
		if(prog_r) text_rom(col0, top + 36, LEN_L_SCAN31, STR_L_SCAN31, MUTED);
		else text_rom(col0, top + 36, LEN_L_SCAN15, STR_L_SCAN15, MUTED);
		if(sound_on) text_rom(col0 + 10, top + 36, LEN_L_SOUND, STR_L_SOUND, MUTED);
	end
endtask

task automatic title(input integer col, top, input wide);
	begin
		if(wide) text_rom2(col, top, LEN_TITLE, STR_TITLE, BRONZE_LT);
		else begin
			text_rom2(col, top, LEN_TITLE_A, STR_TITLE_A, BRONZE_LT);
			text_rom(col + 23, top + 8, LEN_TITLE_B, STR_TITLE_B, BRONZE_LT);
		end
	end
endtask

task automatic gear_labels();
	integer g;
	reg [9:0] x0, y0;
	reg [3:0] col_in;
	begin
		x0 = 0; y0 = 0; col_in = 0;
		for(g = 0; g < NGEAR; g = g + 1) begin
			x0 = 10'(ginfo[g][39:30]) - 10'd6;
			y0 = 10'(ginfo[g][29:21]) - 10'd4;
			if(hd >= x0 && hd < x0 + 10'd12 && vd >= y0 && vd < y0 + 10'd8 && gear[4:0] == 5'(g)) begin
				col_in = 4'(hd - x0);
				direct_code = col_in < 6 ? glabel[g][15:8] : glabel[g][7:0];
				direct = 1;
				glyph_x = col_in < 6 ? col_in[2:0] : 3'(col_in - 4'd6);
				glyph_y = 3'(vd - y0);
				foreground = ENGRAVE;
				text_hit = 1;
			end
		end
	end
endtask

// Horizontal rules are two lines tall so they do not flicker when interlaced.
task automatic rule(input integer left, right, top);
	begin
		if((vd == 10'(top) || vd == 10'(top + 1)) && hd >= 10'(left) && hd < 10'(right)) background = RULE;
	end
endtask

task automatic date_line(input integer col, top);
	begin
		text_rom(col, top, LEN_L_DATE, STR_L_DATE, MUTED);
		text_digits(col + 10, top, 2, {16'd0, jul_day_bcd}, LIGHT, 1);
		text_table(col + 13, top, 3, TAB_JMONTH, {4'd0, jul_month}, TAB_JMONTH_STRIDE, LIGHT);
		text_digits(col + 17, top, 4, {8'd0, jul_year_bcd}, LIGHT, 1);
		text_table(col + 22, top, 2, TAB_ERA, {7'd0, jul_bc}, TAB_ERA_STRIDE, LIGHT);
	end
endtask

task automatic egypt_line(input integer col, top);
	begin
		if(ring_lunar) text_rom(col, top, LEN_L_LUNAR_RING, STR_L_LUNAR_RING, MUTED);
		else text_rom(col, top, LEN_L_EGYPT, STR_L_EGYPT, MUTED);
		text_table(col + 10, top, 10, TAB_EGYPT_EN, {4'd0, egy_month}, TAB_EGYPT_EN_STRIDE, LIGHT);
		text_digits(col + 21, top, 2, {16'd0, egy_day_bcd}, LIGHT, 1);
	end
endtask

task automatic crank_dial();
	begin
		if(r <= 9) begin
			background = textured(BRONZE, grain);
			if(r == 9 || r < 2) background = ENGRAVE;
			if(r >= 2 && r <= 7 && {1'b0, angdist(th, crank_pointer)} <= t2) begin background = running ? GOLD : LIGHT; casts = 1; end
			if(r >= 6 && r <= 8 && {2'b0, angdist(th, crank_pointer)} <= t3) begin background = running ? GOLD : LIGHT; casts = 1; end
		end
	end
endtask

always @* begin
	background = PANEL;
	foreground = LIGHT;
	char_addr = 0;
	direct = 0;
	direct_code = 8'h20;
	glyph_x = 0;
	glyph_y = 0;
	text_hit = 0;
	casts = 0;
	ring_active = 0;
	ring_angle = th;
	ring_chars = 8'(ZOD_RING_CHARS);
	ring_base = 12'(STR_ZOD_RING);
	ring_top = 10'(R_ZOD_TEXT);

	if(hd < 6 || hd >= 634 || vd < 6 || vd >= 474) background = CASE;

	case(view)
	// ------------------------------------------------------------------
	0: begin // Front dial
		if(hd < 436) begin
			if(r <= R_EGY_OUT + 3) background = BRONZE_DK;
			if(r <= R_EGY_OUT) begin
				// Egyptian (or lunar) calendar ring.
				background = textured(egy_month_odd ? BRONZE : BRONZE_ALT, grain);
				if(r >= R_EGY_OUT - 4 && {9'd0, egy_frac} < egy_tick_w) background = ENGRAVE;
				if((ring_lunar ? lun_month_edge : egy_month_edge) && {8'd0, egy_frac, 1'b0} < {egy_tick_w, 1'b0}) background = ENGRAVE;
				if(r >= R_EGY_IN - 1 && r <= R_EGY_IN) background = ENGRAVE;
				ring_active = r <= R_EGY_TEXT && r >= R_EGY_TEXT - 6;
				ring_angle = th_egy;
				ring_chars = 8'(EGY_RING_CHARS);
				ring_base = ring_lunar ? 12'(STR_LUNAR_RING) : 12'(STR_EGY_RING);
				ring_top = 10'(R_EGY_TEXT);
			end
			if(r < R_EGY_IN) begin
				// Zodiac ring.
				background = textured(zod_sign_odd ? 24'hc09a5e : BRONZE_LT, grain);
				if(r >= R_ZOD_OUT - 3 && {9'd0, zod_frac} < zod_tick_w) background = ENGRAVE;
				if(r >= R_ZOD_OUT - 6 && {6'd0, zod36[15:0]} < zod_tick36) background = ENGRAVE;
				if({5'd0, zod12[15:0]} < {zod_tick12, 1'b0}) background = ENGRAVE;
				if(r <= R_ZOD_IN + 1) background = ENGRAVE;
				ring_active = r <= R_ZOD_TEXT && r >= R_ZOD_TEXT - 6;
				ring_angle = th;
				ring_chars = 8'(ZOD_RING_CHARS);
				ring_base = 12'(STR_ZOD_RING);
				ring_top = 10'(R_ZOD_TEXT);
			end
			if(r < R_ZOD_IN) begin
				// Parapegma index letters.
				background = textured(BRONZE, grain);
				ring_active = r <= R_PARA_TEXT && r >= R_PARA_TEXT - 6;
				ring_angle = th;
				ring_chars = 8'(PARA_RING_CHARS);
				ring_base = 12'(STR_PARA_RING);
				ring_top = 10'(R_PARA_TEXT);
				if(r == R_PARA_IN) background = ENGRAVE;
			end
			if(r < R_PARA_IN) begin
				// Cosmos display.
				background = textured(BRONZE_MID, grain);
				if(cosmos_on && (r == R_SATURN || r == R_JUPITER || r == R_MARS || r == R_VENUS || r == R_MERCURY)) background = TRACK;
				if(r == R_SUN) background = TRACK;
				// The Earth: a shaded dome with a glint from the upper left.
				if(r < R_DOME) begin
					background = brighter(24'h4c3a1e, 6'((20'd1936 - r2) >> 5));
					if(r >= 10 && r <= 22 && angdist(th, 16'd57344) <= 16'd5000) background = brighter(background, 6'd20);
				end
				// Dragon Hand: the line of nodes through the centre, head at the ascending node.
				if(cosmos_on && r >= 12 && r <= R_DRAGON) begin
					if(angdist(th, lon_node[19:4]) <= t1 || angdist(th, lon_node[19:4] + 16'h8000) <= t1) begin background = DRAGON; casts = 1; end
					if(r >= R_DRAGON - 9 && r <= R_DRAGON - 2 && {2'b0, angdist(th, lon_node[19:4])} <= t3) begin background = DRAGON; casts = 1; end
				end
			end
			// Date pointer (mean Sun) reaches the calendar ring.
			if(r >= R_DOME && r <= R_DATE && angdist(th, lon_date[19:4]) <= t1) begin background = LIGHT; casts = 1; end
			if(r >= R_DATE - 5 && r <= R_DATE - 2 && {2'b0, angdist(th, lon_date[19:4])} <= t3) begin background = LIGHT; casts = 1; end
			if(r < R_PARA_IN) begin
				if(hairline(th, lon_sun[19:4], r, R_DOME, R_SUN - 6)) begin background = GOLD; casts = 1; end
				if(hairline(th, lon_moon[19:4], r, R_DOME, R_MOON - 6)) begin background = SILVER; casts = 1; end
				if(cosmos_on) begin
					if(hairline(th, lon_mercury[19:4], r, R_DOME, R_MERCURY - 4)) begin background = TURQUOISE; casts = 1; end
					if(hairline(th, lon_venus[19:4], r, R_DOME, R_VENUS - 4)) begin background = LAPIS; casts = 1; end
					if(hairline(th, lon_mars[19:4], r, R_DOME, R_MARS - 4)) begin background = ONYX; casts = 1; end
					if(hairline(th, lon_jupiter[19:4], r, R_DOME, R_JUPITER - 4)) begin background = CRYSTAL; casts = 1; end
					if(hairline(th, lon_saturn[19:4], r, R_DOME, R_SATURN - 4)) begin background = OBSIDIAN; casts = 1; end
					case(bead(th, r, lon_mercury[19:4], R_MERCURY)) 1: begin background = TURQUOISE; casts = 1; end 2: begin background = WHITE; casts = 1; end default: ; endcase
					case(bead(th, r, lon_venus[19:4], R_VENUS)) 1: begin background = LAPIS; casts = 1; end 2: begin background = 24'h9fb8ff; casts = 1; end default: ; endcase
					case(bead(th, r, lon_mars[19:4], R_MARS)) 1: begin background = ONYX; casts = 1; end 2: begin background = 24'hffa080; casts = 1; end default: ; endcase
					case(bead(th, r, lon_jupiter[19:4], R_JUPITER)) 1: begin background = CRYSTAL; casts = 1; end 2: begin background = WHITE; casts = 1; end default: ; endcase
					case(bead(th, r, lon_saturn[19:4], R_SATURN)) 1: begin background = OBSIDIAN; casts = 1; end 2: begin background = 24'h707078; casts = 1; end default: ; endcase
				end
				case(bead(th, r, lon_sun[19:4], R_SUN)) 1: begin background = GOLD; casts = 1; end 2: begin background = 24'hfff4c0; casts = 1; end default: ; endcase
				if(sunray(th, r, lon_sun[19:4], R_SUN)) begin background = GOLD; casts = 1; end
				if(in_ball) begin
					background = ball_lit ? MOON_W : MOON_B;
					if(ball_lit && ball_d2 <= 22'sd12 && ex < 0 && ey < 0) background = WHITE;
					casts = 1;
				end
			end
		end else begin
			// Readout panel.
			if(region == 5) crank_dial();
			title(73, 20, 1'b0);
			rule(440, 632, 40);
			date_line(74, 44);
			egypt_line(74, 56);
			text_rom(74, 68, LEN_L_RINGADJ, STR_L_RINGADJ, MUTED);
			text_table(79, 68, 12, TAB_RING_KIND, {7'd0, ring_lunar}, TAB_RING_KIND_STRIDE, MUTED);
			if(ring_auto) text_rom(92, 68, LEN_L_AUTO, STR_L_AUTO, MUTED);
			else text_rom(92, 68, LEN_L_MANUAL, STR_L_MANUAL, GOLD);
			rule(440, 632, 80);
			body_line(74, 88, 0, STR_L_MEAN, LEN_L_MEAN, LIGHT);
			body_line(74, 100, 1, STR_L_SUN, LEN_L_SUN, GOLD);
			body_line(74, 112, 2, STR_L_MOON, LEN_L_MOON, SILVER);
			text_rom(74, 124, LEN_L_PHASE, STR_L_PHASE, MUTED);
			text_table(83, 124, 15, TAB_PHASE, {5'd0, phase_index}, TAB_PHASE_STRIDE, LIGHT);
			text_rom(74, 136, LEN_L_AGE, STR_L_AGE, MUTED);
			text_digits(83, 136, 2, {16'd0, age_bcd}, LIGHT, 1);
			text_rom(86, 136, LEN_L_DAYS, STR_L_DAYS, MUTED);
			body_line(74, 148, 3, STR_L_NODE, LEN_L_NODE, cosmos_on ? 24'h7fd08f : MUTED);
			if(flash != 0) begin
				if(cell_pulse) text_rom(74, 160, LEN_L_ECLIPSE_NOW, STR_L_ECLIPSE_NOW, GOLD);
				if(sar_glyph[11]) text_rom(82, 160, LEN_L_LUNAR, STR_L_LUNAR, LUNAR_CELL);
				if(sar_glyph[5]) text_rom(90, 160, LEN_L_SOLAR, STR_L_SOLAR, SOLAR_CELL);
			end else if(eclipse_season) text_rom(74, 160, LEN_L_ECLIPSE, STR_L_ECLIPSE, RED);
			rule(440, 632, 172);
			if(cosmos_on) begin
				text_rom(74, 180, LEN_L_PLANETS, STR_L_PLANETS, MUTED);
				body_line(74, 192, 4, TAB_PLANET_EN + 0 * TAB_PLANET_EN_STRIDE, 7, TURQUOISE);
				body_line(74, 204, 5, TAB_PLANET_EN + 1 * TAB_PLANET_EN_STRIDE, 7, 24'h6f8fe8);
				body_line(74, 216, 6, TAB_PLANET_EN + 2 * TAB_PLANET_EN_STRIDE, 7, ONYX);
				body_line(74, 228, 7, TAB_PLANET_EN + 3 * TAB_PLANET_EN_STRIDE, 7, CRYSTAL);
				body_line(74, 240, 8, TAB_PLANET_EN + 4 * TAB_PLANET_EN_STRIDE, 7, 24'hb0b0b8);
				if(retrograde[0]) text_rom(99, 192, 1, STR_L_RETRO, RED);
				if(retrograde[1]) text_rom(99, 204, 1, STR_L_RETRO, RED);
				if(retrograde[2]) text_rom(99, 216, 1, STR_L_RETRO, RED);
				if(retrograde[3]) text_rom(99, 228, 1, STR_L_RETRO, RED);
				if(retrograde[4]) text_rom(99, 240, 1, STR_L_RETRO, RED);
			end
			rule(440, 632, 252);
			text_rom(74, 260, LEN_L_PARAPEGMA, STR_L_PARAPEGMA, MUTED);
			text_table(74, 272, 1, TAB_PARA_LETTER, {3'd0, parapegma_index}, TAB_PARA_LETTER_STRIDE, GOLD);
			text_table(76, 272, 28, TAB_PARAPEGMA, {3'd0, parapegma_index}, TAB_PARAPEGMA_STRIDE, LIGHT);
			rule(440, 632, 284);
			status_block(74, 292);
		end
	end
	// ------------------------------------------------------------------
	1: begin // Back dials
		if(hd < 246) begin
			background = BRONZE_DK;
			case(region)
			0: begin
				if(r <= MET_R1 + 3) background = textured(BRONZE, grain);
				if(met_valid && r >= MET_R0 - 1) begin
					background = textured(met_info[4:0] == 5'd0 ? BRONZE_LT : (met_info[0] ? 24'hb08a5a : BRONZE), grain);
					if(met_pix_cell == met_cell) background = PAPER;
					if({6'd0, met_cell_frac} < met_tick_w) background = ENGRAVE;
					if(met_u[15:0] < 16'(MET_PITCH_INV * 2)) background = ENGRAVE;
				end
				if(r > MET_R1 && r <= MET_R1 + 1) background = ENGRAVE;
				if(r >= 8 && r <= met_follow_r + 2 && {1'b0, angdist(th, met_pointer)} <= t2) begin background = SILVER; casts = 1; end
				if(r >= met_follow_r - 3 && r <= met_follow_r + 3 && {2'b0, angdist(th, met_pointer)} <= t3) begin background = GOLD; casts = 1; end
				if(r < 8) background = ENGRAVE;
			end
			1: begin
				if(r <= SAR_R1 + 3) background = textured(BRONZE, grain);
				if(sar_valid && r >= SAR_R0 - 1) begin
					background = textured(BRONZE, grain);
					if(sar_pix_glyph[11] && sar_u[15:0] >= 16'd32768) background = LUNAR_CELL;
					if(sar_pix_glyph[5] && sar_u[15:0] < 16'd32768) background = SOLAR_CELL;
					if(sar_pix_cell == sar_cell) background = (sar_pix_glyph != 0) ? (cell_pulse ? GOLD : 24'hfff0c0) : PAPER;
					if({6'd0, sar_cell_frac} < sar_tick_w) background = ENGRAVE;
					if(sar_u[15:0] < 16'(SAR_PITCH_INV * 2)) background = ENGRAVE;
				end
				if(r > SAR_R1 && r <= SAR_R1 + 1) background = ENGRAVE;
				if(r >= 8 && r <= sar_follow_r + 2 && {1'b0, angdist(th, sar_pointer)} <= t2) begin background = SILVER; casts = 1; end
				if(r >= sar_follow_r - 3 && r <= sar_follow_r + 3 && {2'b0, angdist(th, sar_pointer)} <= t3) begin background = GOLD; casts = 1; end
				if(r < 8) background = ENGRAVE;
			end
			5: crank_dial();
			default: begin
				background = textured(BRONZE, grain);
				if(r <= SUB_R) begin
					background = textured(BRONZE_LT, grain);
					if(r == SUB_R) background = ENGRAVE;
					ring_active = r <= SUB_R - 3 && r >= SUB_R - 9;
					ring_chars = 8'(SUB_RING_CHARS);
					ring_top = 10'(SUB_R - 3);
					ring_angle = th;
					if(region == 4) begin
						ring_base = 12'(STR_EXEL_RING);
						if(r > 4 && (angdist(th, 16'd5461) <= t1 || angdist(th, 16'd27307) <= t1 || angdist(th, 16'd49152) <= t1)) background = ENGRAVE;
						if(r >= 3 && r <= SUB_R - 2 && angdist(th, exel_pointer) <= t1) begin background = SILVER; casts = 1; end
					end else begin
						ring_base = region == 2 ? 12'(STR_GAMES_RING) : 12'(STR_CAL_RING);
						if(r > 4 && (angdist(th, 16'd0) <= t1 || angdist(th, 16'd16384) <= t1 || angdist(th, 16'd32768) <= t1 || angdist(th, 16'd49152) <= t1)) background = ENGRAVE;
						if(r >= 3 && r <= SUB_R - 2 && angdist(th, region == 2 ? games_pointer : cal_pointer) <= t1) begin background = SILVER; casts = 1; end
					end
					if(r < 3) background = ENGRAVE;
				end
			end
			endcase
		end else begin
			if(region == 5) crank_dial();
			title(42, 20, 1'b1);
			rule(250, 632, 40);
			date_line(42, 44);
			egypt_line(70, 44);
			// Metonic dial.
			text_rom(42, 64, LEN_L_METONIC, STR_L_METONIC, BRONZE_LT);
			text_rom(42, 76, LEN_L_CELL, STR_L_CELL, MUTED);
			text_digits(47, 76, 3, {12'd0, met_cell_bcd}, LIGHT, 1);
			text_rom(50, 76, LEN_L_OF235, STR_L_OF235, MUTED);
			text_rom(56, 76, LEN_L_YEAR, STR_L_YEAR, MUTED);
			text_digits(61, 76, 2, {16'd0, met_year_bcd}, LIGHT, 1);
			text_rom(42, 88, LEN_L_MONTH, STR_L_MONTH, MUTED);
			text_table(48, 88, 11, TAB_CORINTH_GR, {4'd0, met_month}, TAB_CORINTH_GR_STRIDE, GOLD);
			text_table(60, 88, 11, TAB_CORINTH_EN, {4'd0, met_month}, TAB_CORINTH_EN_STRIDE, LIGHT);
			if(met_repeat) text_rom(72, 88, LEN_L_INTERCAL, STR_L_INTERCAL, MUTED);
			text_rom(42, 100, LEN_L_CALLIPPIC, STR_L_CALLIPPIC, MUTED);
			text_rom(52, 100, LEN_L_PERIOD, STR_L_PERIOD, MUTED);
			text_code(59, 100, 8'h31 + {6'd0, cal_period}, LIGHT);
			text_rom(60, 100, LEN_L_OF4, STR_L_OF4, MUTED);
			text_rom(42, 112, LEN_L_GAMES, STR_L_GAMES, MUTED);
			text_rom(53, 112, LEN_L_YEAR, STR_L_YEAR, MUTED);
			text_code(58, 112, 8'h31 + {6'd0, games_year}, LIGHT);
			text_table(60, 112, 13, TAB_GAMES_GR, {6'd0, games_year}, TAB_GAMES_GR_STRIDE, GOLD);
			text_table(74, 112, 16, TAB_GAMES_EN, {6'd0, games_year}, TAB_GAMES_EN_STRIDE, LIGHT);
			rule(250, 632, 124);
			// Saros dial.
			text_rom(42, 132, LEN_L_SAROS, STR_L_SAROS, BRONZE_LT);
			text_rom(42, 144, LEN_L_CELL, STR_L_CELL, MUTED);
			text_digits(47, 144, 3, {12'd0, sar_cell_bcd}, LIGHT, 1);
			text_rom(50, 144, LEN_L_OF223, STR_L_OF223, MUTED);
			text_rom(56, 144, LEN_L_EXEL, STR_L_EXEL, MUTED);
			text_table(66, 144, 9, TAB_EXEL, {6'd0, exel_sector}, TAB_EXEL_STRIDE, LIGHT);
			if(flash != 0 && cell_pulse) text_rom(42, 156, LEN_L_ECLIPSE_NOW, STR_L_ECLIPSE_NOW, GOLD);
			else text_rom(42, 156, LEN_L_THISMONTH, STR_L_THISMONTH, MUTED);
			glyph_line(53, 156, sar_glyph);
			text_rom(42, 168, LEN_L_NEXT, STR_L_NEXT, MUTED);
			text_rom(55, 168, LEN_L_CELL, STR_L_CELL, MUTED);
			text_digits(60, 168, 3, {12'd0, next_cell_bcd}, LIGHT, 1);
			text_rom(64, 168, LEN_L_IN, STR_L_IN, MUTED);
			text_digits(67, 168, 2, {16'd0, next_months_bcd}, LIGHT, 1);
			text_rom(70, 168, LEN_L_INMONTHS, STR_L_INMONTHS, MUTED);
			glyph_line(53, 180, next_glyph);
			rule(250, 632, 192);
			body_line(42, 200, 1, STR_L_SUN, LEN_L_SUN, GOLD);
			body_line(42, 212, 2, STR_L_MOON, LEN_L_MOON, SILVER);
			text_rom(42, 224, LEN_L_PHASE, STR_L_PHASE, MUTED);
			text_table(51, 224, 15, TAB_PHASE, {5'd0, phase_index}, TAB_PHASE_STRIDE, LIGHT);
			rule(250, 632, 236);
			status_block(42, 244);
		end
	end
	// ------------------------------------------------------------------
	default: begin // Gear train
		if(hd < 436) begin
			if(gear[4:0] != 31) begin
				background = textured(gear_fill(gshaft), grain);
				if(r >= gear_band_in && r <= gear_r) begin
					if(r >= gear_r - 1) background = ENGRAVE;
					if(r > gear_band_in + 2 && r < gear_r - 1 && angdist(th, gear_mark) <= t1) begin background = LIGHT; casts = 1; end
				end
				if(r <= 2) background = ENGRAVE;
			end
			if(gear[5]) background = ENGRAVE;
			gear_labels();
		end else begin
			if(region == 5) crank_dial();
			title(73, 20, 1'b0);
			rule(440, 632, 40);
			text_rom(74, 44, LEN_L_GEARS, STR_L_GEARS, MUTED);
			text_rom(74, 64, LEN_G_CRANK, STR_G_CRANK, 24'h8a7a5a);
			text_rom(74, 76, LEN_G_SUN, STR_G_SUN, 24'h9c7a3c);
			text_rom(74, 88, LEN_G_MOON, STR_G_MOON, 24'h8c8c8c);
			text_rom(74, 100, LEN_G_PINSLOT, STR_G_PINSLOT, 24'h5a7a9c);
			text_rom(74, 112, LEN_G_METONIC, STR_G_METONIC, 24'h9a8a58);
			text_rom(74, 124, LEN_G_SAROS, STR_G_SAROS, 24'h8c6a6a);
			rule(440, 632, 136);
			date_line(74, 144);
			status_block(74, 160);
		end
	end
	endcase

	// Drop shadow from the features two lines up and two pixels left.
	if(shadow_read && !casts && !text_hit && hd >= 6 && (view == 1 ? hd < 246 : hd < 436)) background = shaded(background);

	// Footer.
	rule(20, 620, 440);
	text_rom(4, 450, LEN_L_KEYS, STR_L_KEYS, MUTED);

	// Ring inscriptions engraved into the dials.
	if(ring_active && !text_hit) begin
		char_addr = ring_base + {4'd0, ring_char};
		glyph_x = ring_col;
		glyph_y = 3'(ring_top - r);
		foreground = ENGRAVE;
		text_hit = 1;
		direct = 0;
	end

	// Help card.
	if(help && hd >= 56 && hd < 584 && vd >= 60 && vd < 420) begin
		background = PAPER;
		text_hit = 0;
		direct = 0;
		if(hd == 58 || hd == 581 || vd == 62 || vd == 63 || vd == 416 || vd == 417) background = BRONZE_LT;
		text_rom(14, 80, LEN_H_TITLE, STR_H_TITLE, ENGRAVE);
		text_rom(14, 104, LEN_H_1, STR_H_1, ENGRAVE);
		text_rom(14, 118, LEN_H_2, STR_H_2, ENGRAVE);
		text_rom(14, 132, LEN_H_3, STR_H_3, ENGRAVE);
		text_rom(14, 146, LEN_H_4, STR_H_4, ENGRAVE);
		text_rom(14, 160, LEN_H_5, STR_H_5, ENGRAVE);
		text_rom(14, 174, LEN_H_6, STR_H_6, ENGRAVE);
		text_rom(14, 188, LEN_H_7, STR_H_7, ENGRAVE);
		text_rom(14, 202, LEN_H_8, STR_H_8, ENGRAVE);
		text_rom(14, 216, LEN_H_9, STR_H_9, ENGRAVE);
		text_rom(14, 230, LEN_H_10, STR_H_10, ENGRAVE);
		text_rom(14, 258, LEN_H_11, STR_H_11, ENGRAVE);
		text_rom(14, 272, LEN_H_12, STR_H_12, ENGRAVE);
		text_rom(14, 390, LEN_H_13, STR_H_13, 24'h85633c);
	end
end

// ---------------------------------------------------------------------------
// Pipeline registers, text ROM, font and output.
// ---------------------------------------------------------------------------
reg [23:0] bg_d1, fg_d1, bg_d2, fg_d2;
reg direct_d1, direct_d2, hit_d1, hit_d2;
reg [7:0] code_d1, code_d2;
reg [2:0] gx_d1, gy_d1, gx_d2, gy_d2;
reg [11:0] rom_addr;
wire [7:0] rom_data;
am_strings strings (.clk(clk), .ce(ce), .address(rom_addr), .data(rom_data));
wire [7:0] font_code = direct_d2 ? code_d2 : rom_data;
wire font_pixel;
am_font font (.character(font_code), .x(gx_d2), .y(gy_d2), .pixel(font_pixel));

always @(posedge clk) begin
	cdiv <= cdiv + 1'b1;
	ce_pixel <= ce;
	if(ce) begin
		prog_r <= progressive;
		if(h == 799) begin
			h <= 0;
			if(line >= lines_in_field - 1'b1) begin
				line <= 0;
				field <= prog_r ? 1'b0 : !field;
			end else line <= line + 1'b1;
		end else h <= h + 1'b1;
		// Stage 0 -> 1: centre selection.
		cx1 <= cx0; cy1 <= cy0; h1 <= h; v1 <= v;
		hq[0] <= h; vq[0] <= v;
		hsq[0] <= !hs_now;
		vsq[0] <= !vs_now;
		visq[0] <= h < 640 && line < visible_lines;
		hbq[0] <= h >= 640;
		vbq[0] <= line >= visible_lines;
		regq[0] <= region0;
		gearq[0] <= gear0;
		// Stage 1 -> polar input.
		dx1 <= $signed({1'b0, h1}) - $signed({1'b0, cx1});
		dy1 <= $signed({1'b0, v1}) - $signed({1'b0, cy1});
		for(k = 1; k <= QDEPTH; k = k + 1) begin
			hq[k] <= hq[k-1]; vq[k] <= vq[k-1];
			hsq[k] <= hsq[k-1]; vsq[k] <= vsq[k-1]; visq[k] <= visq[k-1];
			hbq[k] <= hbq[k-1]; vbq[k] <= vbq[k-1];
			regq[k] <= regq[k-1]; gearq[k] <= gearq[k-1];
		end
		// Shadow buffer: read an earlier picture line a stage ahead, write this one.
		shadow_read <= shadow_mem[shadow_raddr];
		shadow_mem[{wsel, hd}] <= casts;
		if(hd == 799) wsel <= (wsel == 2'd2) ? 2'd0 : wsel + 2'd1;
		// Drawing stage -> ROM stage.
		rom_addr <= char_addr;
		bg_d1 <= background; fg_d1 <= foreground;
		direct_d1 <= direct; code_d1 <= direct_code; hit_d1 <= text_hit;
		gx_d1 <= glyph_x; gy_d1 <= glyph_y;
		// ROM stage -> font stage.
		bg_d2 <= bg_d1; fg_d2 <= fg_d1;
		direct_d2 <= direct_d1; code_d2 <= code_d1; hit_d2 <= hit_d1;
		gx_d2 <= gx_d1; gy_d2 <= gy_d1;
		// Output.
		hsync <= hsq[LAT+2];
		vsync <= vsq[LAT+2];
		de <= visq[LAT+2];
		hblank <= hbq[LAT+2];
		vblank <= vbq[LAT+2];
		{red, green, blue} <= visq[LAT+2] ? ((hit_d2 && font_pixel) ? fg_d2 : bg_d2) : 24'd0;
	end
end

endmodule
