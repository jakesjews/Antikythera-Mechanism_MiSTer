// SPDX-License-Identifier: GPL-2.0-or-later
// Turns the crank: converts the operator's commands and the selected speed
// into power-of-two tick steps for the shaft accumulators, and keeps the
// signed count of ticks since the epoch for the calendar.
module am_timebase (
	input  wire        clk,
	input  wire        reset,
	input  wire        enable,         // false while the OSD or help is open
	input  wire        shafts_busy,
	input  wire        toggle_run,
	input  wire        reverse,
	input  wire        home,
	input  wire        speed_up,
	input  wire        speed_down,
	input  wire        nudge,          // one-off step request
	input  wire        nudge_forward,
	input  wire [1:0]  nudge_size,     // 0 day, 1 lunar month, 2 year
	output reg         running,
	output reg         forward,
	output reg  [2:0]  speed,
	output reg         step,
	output reg         step_forward,
	output reg  [4:0]  step_shift,
	output reg  signed [39:0] ticks,
	output reg         load,
	output reg         last_forward
);

`include "am_tables.svh"

localparam [24:0] MONTH_TICKS = 25'd1935334;      // the Mechanism's month: 19/235 of its year
localparam [24:0] DAY_TICKS_C = 25'd65536;

function automatic [21:0] rate_q16(input [2:0] s);
	// ticks per 50 MHz clock in Q6.16
	case(s)
		0: rate_q16 = 22'd86;        // one day per second
		1: rate_q16 = 22'd601;       // one week
		2: rate_q16 = 22'd2537;      // one lunar month
		3: rate_q16 = 22'd31376;     // one year
		4: rate_q16 = 22'd125504;    // four years
		5: rate_q16 = 22'd596147;    // nineteen years
		6: rate_q16 = 22'd2384588;   // seventy-six years
		default: rate_q16 = 22'd3137510; // a century
	endcase
endfunction

reg [15:0] acc;
reg signed [31:0] pending;
wire [31:0] magnitude = pending[31] ? -pending : pending;
reg [4:0] top;
integer b;
always @* begin
	top = 0;
	for(b = 0; b < 17; b = b + 1) if(magnitude[b]) top = 5'(b);
	if(|magnitude[31:17]) top = 16;
end

wire [31:0] nudge_ticks = nudge_size == 0 ? 32'(DAY_TICKS_C) : nudge_size == 1 ? 32'(MONTH_TICKS) : {4'd0, YEAR_TICKS};
wire [21:0] rate = rate_q16(speed);
wire [16:0] next_acc = {1'b0, acc} + {1'b0, rate[15:0]};
wire [31:0] run_ticks = {25'd0, rate[21:16]} + {31'd0, next_acc[16]};
wire can_step = !shafts_busy && pending != 0 && !step;
wire signed [31:0] step_ticks = 32'd1 << top;
wire signed [39:0] step_ticks_40 = {8'd0, step_ticks};

reg signed [31:0] delta;
always @* begin
	delta = 0;
	if(running && enable) delta = delta + (forward ? run_ticks : -run_ticks);
	if(nudge && enable) delta = delta + (nudge_forward ? nudge_ticks : -nudge_ticks);
	if(can_step) delta = delta + (pending[31] ? step_ticks : -step_ticks);
end

always @(posedge clk) begin
	step <= 0;
	load <= 0;
	if(reset) begin
		running <= 0;
		forward <= 1;
		speed <= 3;
		acc <= 0;
		pending <= 0;
		ticks <= 0;
		last_forward <= 1;
	end else begin
		if(toggle_run) running <= !running;
		if(reverse) forward <= !forward;
		if(speed_up && speed != 7) speed <= speed + 1'b1;
		if(speed_down && speed != 0) speed <= speed - 1'b1;
		if(home) begin
			pending <= 0;
			acc <= 0;
			ticks <= 0;
			running <= 0;
			load <= 1;
		end else begin
			if(running && enable) acc <= next_acc[15:0];
			pending <= pending + delta;
			if(can_step) begin
				step <= 1;
				step_forward <= !pending[31];
				step_shift <= top;
				last_forward <= !pending[31];
				ticks <= pending[31] ? ticks - step_ticks_40 : ticks + step_ticks_40;
			end
		end
	end
end

endmodule
