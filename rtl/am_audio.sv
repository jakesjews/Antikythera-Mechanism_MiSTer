// SPDX-License-Identifier: GPL-2.0-or-later
// Sound of the instrument: a click for every tooth of the crank wheel a1
// that passes while it runs, a soft tick for each turn by hand, and a two
// note chime when the Saros pointer reaches an eclipse glyph (lower for a
// lunar eclipse, higher for a solar one). Everything is synthesised: noise
// bursts and triangle waves with decaying envelopes at 48 kHz.
module am_audio (
	input  wire        clk,
	input  wire        reset,
	input  wire        enable,
	input  wire        tooth,          // crank wheel tooth passed
	input  wire        tick,           // one step by hand
	input  wire        chime,          // Saros pointer entered a glyph cell
	input  wire [1:0]  chime_kind,     // {lunar, solar}
	output reg  signed [15:0] sample
);

localparam [10:0] SAMPLE_DIVIDER = 11'd1042;    // 50 MHz / 48 kHz

reg [10:0] divider;
wire sample_clock = divider == 0;
always @(posedge clk) divider <= (reset || divider == SAMPLE_DIVIDER - 1) ? 11'd0 : divider + 1'b1;

// Noise source.
reg [30:0] lfsr = 31'h1234567;
always @(posedge clk) if(sample_clock) lfsr <= {lfsr[29:0], lfsr[30] ^~ lfsr[27]};

// Click: noise burst with a 1.2 kHz body, 5 ms long. Tick: a softer, shorter one.
reg [7:0] click_env, tick_env;
reg [5:0] body_phase;
// Chime: two triangle tones in sequence, half a second each.
reg [15:0] chime_env;
reg [15:0] chime_phase;
reg [15:0] chime_step;
reg [14:0] chime_timer;
reg        chime_second;
reg [1:0]  chime_pending_kind;

function automatic [15:0] note_step(input [1:0] kind, input second);
	// phase step per sample for 440/330 Hz (lunar) and 1047/784 Hz (solar)
	note_step = kind[1] ? (second ? 16'd450 : 16'd601) : (second ? 16'd1070 : 16'd1429);
endfunction

wire signed [15:0] triangle = chime_phase[15] ? $signed({1'b0, ~chime_phase[14:0]}) - 16'sd16384
                                         : $signed({1'b0, chime_phase[14:0]}) - 16'sd16384;
wire signed [15:0] noise = lfsr[0] ? 16'sd6000 : -16'sd6000;
wire signed [15:0] body = body_phase[5] ? 16'sd4000 : -16'sd4000;
wire signed [23:0] click_out = (noise + body) * $signed({1'b0, click_env});
wire signed [23:0] tick_out = noise * $signed({1'b0, tick_env});
wire signed [31:0] chime_out = triangle * $signed({1'b0, chime_env});
wire signed [17:0] mix = $signed(click_out[23:8]) + $signed({{2{tick_out[23]}}, tick_out[23:9]}) + $signed(chime_out[31:15]);

always @(posedge clk) begin
	if(reset) begin
		click_env <= 0; tick_env <= 0; chime_env <= 0; chime_timer <= 0; chime_second <= 0;
		sample <= 0;
	end else begin
		if(tooth && enable && click_env < 8'd200) click_env <= 8'd255;
		if(tick && enable) tick_env <= 8'd160;
		if(chime && enable) begin
			chime_env <= 16'hffff;
			chime_step <= note_step(chime_kind, 1'b0);
			chime_pending_kind <= chime_kind;
			chime_timer <= 15'd14400;          // 300 ms until the second note
			chime_second <= 0;
			chime_phase <= 0;
		end
		if(sample_clock) begin
			if(click_env != 0) click_env <= click_env - 1'b1;
			if(tick_env != 0) tick_env <= tick_env - 1'b1;
			if(chime_env != 0) chime_env <= chime_env - (chime_env >> 11) - 1'b1;
			body_phase <= body_phase + 6'd3;
			chime_phase <= chime_phase + chime_step;
			if(chime_timer != 0) begin
				chime_timer <= chime_timer - 1'b1;
				if(chime_timer == 1 && !chime_second) begin
					chime_second <= 1;
					chime_env <= 16'hffff;
					chime_step <= note_step(chime_pending_kind, 1'b1);
				end
			end
			sample <= enable ? (mix > 18'sd32767 ? 16'sd32767 : mix < -18'sd32768 ? -16'sd32768 : mix[15:0]) : 16'sd0;
		end
	end
end

endmodule
