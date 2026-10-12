// SPDX-License-Identifier: GPL-2.0-or-later
// MiSTer's decoded PS/2 events and configurable gamepad buttons.
module am_controls (
	input  wire        clk,
	input  wire        reset,
	input  wire        osd_open,
	input  wire [10:0] ps2_key,
	input  wire [7:0]  joystick,
	output reg         toggle_run,
	output reg         nudge,
	output reg         nudge_forward,
	output reg  [1:0]  nudge_size,
	output reg         speed_up,
	output reg         speed_down,
	output reg         reverse,
	output reg         home,
	output reg         view_set,
	output reg  [1:0]  view_value,
	output reg         view_next,
	output reg         help,
	output reg         ring_nudge,
	output reg         ring_forward
);

reg last_toggle;
reg [511:0] held;
reg [7:0] last_joystick;
wire [7:0] pressed = joystick & ~last_joystick;
wire key_event = ps2_key[10] != last_toggle;
wire fresh_key = !held[ps2_key[8:0]];

// Auto-repeat for the crank keys and buttons.
localparam [24:0] REPEAT_DELAY = 25'd20000000;   // 0.4 s
localparam [24:0] REPEAT_RATE = 25'd3333333;     // 15 per second
reg [24:0] repeat_timer;
wire crank_fwd_held = held[9'h174] || joystick[0];
wire crank_back_held = held[9'h16b] || joystick[1];
wire month_fwd_held = held[9'h175];
wire month_back_held = held[9'h172];
wire any_held = crank_fwd_held || crank_back_held || month_fwd_held || month_back_held;

always @(posedge clk) begin
	toggle_run <= 0;
	nudge <= 0;
	speed_up <= 0;
	speed_down <= 0;
	reverse <= 0;
	home <= 0;
	view_set <= 0;
	view_next <= 0;
	ring_nudge <= 0;
	last_toggle <= ps2_key[10];
	last_joystick <= joystick;
	if(reset) begin
		held <= 0;
		help <= 0;
		repeat_timer <= 0;
	end else begin
		if(key_event) held[ps2_key[8:0]] <= ps2_key[9];
		if(!osd_open) begin
			if(key_event && ps2_key[9] && fresh_key) begin
				case(ps2_key[8:0])
					9'h005: help <= !help;                       // F1
					9'h076: help <= 0;                           // Escape
					9'h029: if(!help) toggle_run <= 1;           // Space
					9'h174: if(!help) begin nudge <= 1; nudge_forward <= 1; nudge_size <= 0; end // Right
					9'h16b: if(!help) begin nudge <= 1; nudge_forward <= 0; nudge_size <= 0; end // Left
					9'h175: if(!help) begin nudge <= 1; nudge_forward <= 1; nudge_size <= 1; end // Up
					9'h172: if(!help) begin nudge <= 1; nudge_forward <= 0; nudge_size <= 1; end // Down
					9'h17d: if(!help) begin nudge <= 1; nudge_forward <= 1; nudge_size <= 2; end // Page Up
					9'h17a: if(!help) begin nudge <= 1; nudge_forward <= 0; nudge_size <= 2; end // Page Down
					9'h055, 9'h079: if(!help) speed_up <= 1;    // = and keypad +
					9'h04e, 9'h07b: if(!help) speed_down <= 1;  // - and keypad -
					9'h02d: if(!help) reverse <= 1;              // R
					9'h16c: if(!help) home <= 1;                 // Home
					9'h00d: if(!help) view_next <= 1;            // Tab
					9'h016: if(!help) begin view_set <= 1; view_value <= 0; end // 1
					9'h01e: if(!help) begin view_set <= 1; view_value <= 1; end // 2
					9'h026: if(!help) begin view_set <= 1; view_value <= 2; end // 3
					9'h054: if(!help) begin ring_nudge <= 1; ring_forward <= 0; end // [
					9'h05b: if(!help) begin ring_nudge <= 1; ring_forward <= 1; end // ]
					default: ;
				endcase
			end
			if(!help) begin
				if(pressed[0]) begin nudge <= 1; nudge_forward <= 1; nudge_size <= 0; end
				if(pressed[1]) begin nudge <= 1; nudge_forward <= 0; nudge_size <= 0; end
				if(pressed[2]) toggle_run <= 1;
				if(pressed[3]) view_next <= 1;
				if(pressed[4]) speed_up <= 1;
				if(pressed[5]) speed_down <= 1;
				if(pressed[7]) reverse <= 1;
			end
			if(pressed[6]) help <= !help;
			// Held crank keys repeat.
			if(any_held && !help) begin
				if(repeat_timer == REPEAT_DELAY) begin
					repeat_timer <= REPEAT_DELAY - REPEAT_RATE;
					nudge <= 1;
					nudge_forward <= crank_fwd_held || month_fwd_held;
					nudge_size <= (month_fwd_held || month_back_held) ? 2'd1 : 2'd0;
				end else repeat_timer <= repeat_timer + 1'b1;
			end else repeat_timer <= 0;
		end
	end
end

endmodule
