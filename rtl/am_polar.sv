// SPDX-License-Identifier: GPL-2.0-or-later
// Pipelined vectoring CORDIC for the pixel pipeline: screen offsets to
// (radius, angle). The angle is a fraction of a turn measured clockwise from
// straight up, so it matches the dials. One sample per enabled clock;
// latency is STAGES + 2 enabled clocks.
(* multstyle = "logic" *)
module am_polar #(
	parameter integer STAGES = 13
) (
	input  wire              clk,
	input  wire              ce,
	input  wire signed [10:0] dx,
	input  wire signed [10:0] dy,
	output reg  [9:0]        radius,
	output reg  [15:0]       theta
);

function automatic [15:0] atan_turns(input integer i);
	case(i)
		0: atan_turns = 16'd8192;  1: atan_turns = 16'd4836;  2: atan_turns = 16'd2555;
		3: atan_turns = 16'd1297;  4: atan_turns = 16'd651;   5: atan_turns = 16'd326;
		6: atan_turns = 16'd163;   7: atan_turns = 16'd81;    8: atan_turns = 16'd41;
		9: atan_turns = 16'd20;    10: atan_turns = 16'd10;   11: atan_turns = 16'd5;
		12: atan_turns = 16'd3;    13: atan_turns = 16'd1;    14: atan_turns = 16'd1;
		default: atan_turns = 16'd0;
	endcase
endfunction

// Clockwise-from-top angle: atan2(dx, -dy).
// Five fractional bits keep the angle accurate near the centre of a dial.
reg signed [15:0] x [0:STAGES];
reg signed [15:0] y [0:STAGES];
reg signed [15:0] z [0:STAGES];

wire signed [15:0] dx_f = {dx, 5'd0};
wire signed [15:0] dy_f = {dy, 5'd0};
always @(posedge clk) if(ce) begin
	if(dy > 0) begin
		x[0] <= dy_f;
		y[0] <= -dx_f;
		z[0] <= 16'h8000;           // half a turn (6 o'clock)
	end else begin
		x[0] <= -dy_f;
		y[0] <= dx_f;
		z[0] <= 16'sd0;
	end
end

genvar s;
generate
	for(s = 0; s < STAGES; s = s + 1) begin : stage
		always @(posedge clk) if(ce) begin
			if(y[s] < 0) begin
				x[s+1] <= x[s] - (y[s] >>> s);
				y[s+1] <= y[s] + (x[s] >>> s);
				z[s+1] <= z[s] - $signed(atan_turns(s));
			end else begin
				x[s+1] <= x[s] + (y[s] >>> s);
				y[s+1] <= y[s] - (x[s] >>> s);
				z[s+1] <= z[s] + $signed(atan_turns(s));
			end
		end
	end
endgenerate

// Remove the CORDIC gain (1/1.6468 = 19898/32768) and the fractional bits.
reg [30:0] scaled;
reg [15:0] theta_d;
always @(posedge clk) if(ce) begin
	scaled <= $unsigned(x[STAGES]) * 15'd19898;
	theta_d <= z[STAGES];
	radius <= scaled[29:20];
	theta <= theta_d;
end

endmodule
