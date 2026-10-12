// SPDX-License-Identifier: GPL-2.0-or-later
// Portable core: the Antikythera Mechanism without any MiSTer dependencies.
module antikythera (
	input  wire        clk,
	input  wire        reset,
	input  wire        osd_open,
	input  wire [10:0] ps2_key,
	input  wire [7:0]  joystick,
	input  wire        menu_epoch,
	input  wire        menu_b1_224,
	input  wire        menu_ring_lunar,
	input  wire        menu_ring_manual,
	input  wire        menu_cosmos_off,
	input  wire [1:0]  menu_view,
	input  wire        menu_view_set,
	input  wire        menu_run,
	input  wire        menu_home,
	output wire        ce_pixel,
	output wire [7:0]  red,
	output wire [7:0]  green,
	output wire [7:0]  blue,
	output wire        hsync,
	output wire        vsync,
	output wire        de,
	output wire        hblank,
	output wire        vblank,
	output wire        running,
	output wire signed [39:0] ticks,
	output wire [20*23-1:0] fracs,
	output wire [19:0] lon_sun,
	output wire [19:0] lon_moon,
	output wire [19:0] lon_node,
	output wire [19:0] lon_mercury,
	output wire [19:0] lon_venus,
	output wire [19:0] lon_mars,
	output wire [19:0] lon_jupiter,
	output wire [19:0] lon_saturn,
	output wire [7:0]  met_cell,
	output wire [7:0]  sar_cell,
	output wire [19:0] debug_ring_offset,
	output wire        debug_ring_auto,
	output wire [8:0]  debug_ring_index,
	output wire        frame_done
);

wire toggle_run, nudge, nudge_forward, speed_up, speed_down, reverse, home;
wire view_set, view_next, help, ring_nudge, ring_forward;
wire [1:0] nudge_size, view_value;
reg [1:0] view;
reg old_menu_run, old_menu_home, old_menu_view_set, old_epoch;
reg ring_manual_mode;
reg [19:0] ring_manual;
wire forward, step, step_forward, load, last_forward, shafts_busy, fracs_valid, cosmos_done, calendar_done;
wire [2:0] speed;
wire [4:0] step_shift;
wire signed [19:0] crank_turns;
wire frame_start;
wire [19:0] lon_date, lon_phase, lon_apogee, moon_anomaly;
wire signed [15:0] phase_sin, phase_cos, moon_sin, moon_cos;
wire [19:0] ring_offset;
wire [7:0] jul_day_bcd, egy_day_bcd, met_year_bcd, age_bcd, next_months_bcd;
wire [3:0] jul_month, egy_month, met_month;
wire [15:0] jul_year_bcd;
wire jul_bc, met_repeat, eclipse_season, crank_negative;
wire [35:0] body_sign;
wire [71:0] body_deg;
wire [2:0] phase_index;
wire [11:0] met_cell_bcd, sar_cell_bcd, next_cell_bcd;
wire [1:0] cal_period, games_year, exel_sector;
wire [12:0] sar_glyph, next_glyph;
wire [4:0] parapegma_index, retrograde;
wire [19:0] crank_bcd;
wire [8:0] ring_index;
wire [7:0] met_cell_exact, sar_cell_exact;

reg old_ring_menu;
always @(posedge clk) old_ring_menu <= menu_ring_manual;
wire epoch_change = menu_epoch != old_epoch;
wire do_home = home || (menu_home && !old_menu_home) || epoch_change;

always @(posedge clk) begin
	old_menu_run <= menu_run;
	old_menu_home <= menu_home;
	old_menu_view_set <= menu_view_set;
	old_epoch <= menu_epoch;
	if(reset) begin
		view <= 0;
		ring_manual_mode <= 0;
		ring_manual <= 0;
	end else begin
		if(view_set) view <= view_value;
		if(view_next) view <= view == 2 ? 2'd0 : view + 1'b1;
		if(menu_view_set && !old_menu_view_set) view <= menu_view;
		// Turning the calendar ring by hand takes it out of automatic registration.
		if(ring_nudge) begin
			ring_manual_mode <= 1;
			ring_manual <= (ring_manual_mode ? ring_manual : ring_offset) + (ring_forward ? 20'd2873 : -20'd2873);
		end
		if(do_home || menu_ring_manual == 0 && ring_manual_mode && menu_ring_manual != old_ring_menu) ring_manual_mode <= 0;
	end
end
wire ring_auto = !(ring_manual_mode || menu_ring_manual);
assign debug_ring_offset = ring_offset;
assign debug_ring_auto = ring_auto;
assign debug_ring_index = ring_index;

am_controls controls (
	.clk(clk), .reset(reset), .osd_open(osd_open), .ps2_key(ps2_key), .joystick(joystick),
	.toggle_run(toggle_run), .nudge(nudge), .nudge_forward(nudge_forward), .nudge_size(nudge_size),
	.speed_up(speed_up), .speed_down(speed_down), .reverse(reverse), .home(home),
	.view_set(view_set), .view_value(view_value), .view_next(view_next), .help(help),
	.ring_nudge(ring_nudge), .ring_forward(ring_forward)
);

am_timebase timebase (
	.clk(clk), .reset(reset), .enable(!osd_open && !help), .shafts_busy(shafts_busy),
	.toggle_run(toggle_run || (menu_run && !old_menu_run)), .reverse(reverse), .home(do_home),
	.speed_up(speed_up), .speed_down(speed_down),
	.nudge(nudge), .nudge_forward(nudge_forward), .nudge_size(nudge_size),
	.running(running), .forward(forward), .speed(speed),
	.step(step), .step_forward(step_forward), .step_shift(step_shift),
	.ticks(ticks), .load(load), .last_forward(last_forward)
);

am_shafts shafts (
	.clk(clk), .reset(reset), .load(load), .epoch(menu_epoch), .b1_224(menu_b1_224),
	.step(step), .step_forward(step_forward), .step_shift(step_shift),
	.compute(frame_start), .busy(shafts_busy), .fracs(fracs), .fracs_valid(fracs_valid),
	.met_cell(met_cell_exact), .sar_cell(sar_cell_exact), .crank_turns(crank_turns)
);

am_cosmos cosmos (
	.clk(clk), .reset(reset), .start(fracs_valid), .fracs(fracs),
	.lon_date(lon_date), .lon_sun(lon_sun), .lon_moon(lon_moon), .lon_phase(lon_phase),
	.lon_node(lon_node), .lon_apogee(lon_apogee), .lon_mercury(lon_mercury), .lon_venus(lon_venus),
	.lon_mars(lon_mars), .lon_jupiter(lon_jupiter), .lon_saturn(lon_saturn),
	.moon_anomaly_out(moon_anomaly), .phase_sin(phase_sin), .phase_cos(phase_cos),
	.moon_sin(moon_sin), .moon_cos(moon_cos), .done(cosmos_done)
);

am_calendar calendar (
	.clk(clk), .reset(reset), .start(cosmos_done), .clear(load), .epoch(menu_epoch), .ticks(ticks),
	.last_forward(last_forward), .ring_lunar(menu_ring_lunar), .ring_auto(ring_auto), .ring_manual(ring_manual),
	.fracs(fracs), .lon_sun(lon_sun), .lon_moon(lon_moon), .lon_phase(lon_phase), .lon_node(lon_node),
	.lon_mercury(lon_mercury), .lon_venus(lon_venus), .lon_mars(lon_mars), .lon_jupiter(lon_jupiter),
	.lon_saturn(lon_saturn), .crank_turns(crank_turns), .met_cell_in(met_cell_exact), .sar_cell_in(sar_cell_exact),
	.jul_day_bcd(jul_day_bcd), .jul_month(jul_month), .jul_year_bcd(jul_year_bcd), .jul_bc(jul_bc),
	.egy_month(egy_month), .egy_day_bcd(egy_day_bcd), .ring_offset(ring_offset), .ring_index(ring_index),
	.body_sign(body_sign), .body_deg(body_deg), .phase_index(phase_index), .age_bcd(age_bcd),
	.met_cell(met_cell), .met_cell_bcd(met_cell_bcd), .met_year_bcd(met_year_bcd), .met_month(met_month),
	.met_repeat(met_repeat), .cal_period(cal_period), .games_year(games_year),
	.sar_cell(sar_cell), .sar_cell_bcd(sar_cell_bcd), .sar_glyph(sar_glyph), .exel_sector(exel_sector),
	.next_cell_bcd(next_cell_bcd), .next_months_bcd(next_months_bcd), .next_glyph(next_glyph),
	.parapegma_index(parapegma_index), .eclipse_season(eclipse_season), .retrograde(retrograde),
	.crank_bcd(crank_bcd), .crank_negative(crank_negative), .done(calendar_done)
);
assign frame_done = calendar_done;

am_video video (
	.clk(clk), .view(view), .help(help), .fracs_in(fracs),
	.lon_date_in(lon_date), .lon_sun_in(lon_sun), .lon_moon_in(lon_moon), .lon_phase_in(lon_phase),
	.lon_node_in(lon_node), .lon_mercury_in(lon_mercury), .lon_venus_in(lon_venus), .lon_mars_in(lon_mars),
	.lon_jupiter_in(lon_jupiter), .lon_saturn_in(lon_saturn), .moon_anomaly_in(moon_anomaly),
	.phase_sin_in(phase_sin), .phase_cos_in(phase_cos), .moon_sin_in(moon_sin), .moon_cos_in(moon_cos),
	.ring_offset_in(ring_offset), .ring_lunar(menu_ring_lunar), .ring_auto(ring_auto),
	.cosmos_on(!menu_cosmos_off), .epoch(menu_epoch), .b1_224(menu_b1_224),
	.running(running), .forward(forward), .speed(speed),
	.jul_day_bcd_in(jul_day_bcd), .jul_month_in(jul_month), .jul_year_bcd_in(jul_year_bcd), .jul_bc_in(jul_bc),
	.egy_month_in(egy_month), .egy_day_bcd_in(egy_day_bcd), .body_sign_in(body_sign), .body_deg_in(body_deg),
	.phase_index_in(phase_index), .age_bcd_in(age_bcd),
	.met_cell_in(met_cell), .met_cell_bcd_in(met_cell_bcd), .met_year_bcd_in(met_year_bcd),
	.met_month_in(met_month), .met_repeat_in(met_repeat), .cal_period_in(cal_period), .games_year_in(games_year),
	.sar_cell_in(sar_cell), .sar_cell_bcd_in(sar_cell_bcd), .sar_glyph_in(sar_glyph), .exel_sector_in(exel_sector),
	.next_cell_bcd_in(next_cell_bcd), .next_months_bcd_in(next_months_bcd), .next_glyph_in(next_glyph),
	.parapegma_index_in(parapegma_index), .eclipse_season_in(eclipse_season), .retrograde_in(retrograde),
	.crank_bcd_in(crank_bcd), .crank_negative_in(crank_negative),
	.ce_pixel(ce_pixel), .red(red), .green(green), .blue(blue), .hsync(hsync), .vsync(vsync), .de(de),
	.hblank(hblank), .vblank(vblank), .frame_start(frame_start)
);

endmodule
