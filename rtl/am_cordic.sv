// SPDX-License-Identifier: GPL-2.0-or-later
// Iterative CORDIC shared by the once-per-frame computations.
// Angles are fractions of a turn: 20-bit two's complement, 1 turn = 2^20.
// Vectors are Q8.24 signed. Rotation mode turns (x,y) by z; vectoring mode
// returns atan2(y,x) in z and |(x,y)| in x. Both carry the CORDIC gain 1.6468.
module am_cordic (
	input  wire               clk,
	input  wire               start,
	input  wire               vectoring,
	input  wire signed [31:0] x_in,
	input  wire signed [31:0] y_in,
	input  wire signed [19:0] z_in,
	output reg  signed [31:0] x_out,
	output reg  signed [31:0] y_out,
	output reg  signed [19:0] z_out,
	output reg                done
);

function automatic [19:0] atan_turns(input [4:0] i);
	case(i)
		0: atan_turns = 20'd131072;  1: atan_turns = 20'd77376;   2: atan_turns = 20'd40884;
		3: atan_turns = 20'd20753;   4: atan_turns = 20'd10417;   5: atan_turns = 20'd5213;
		6: atan_turns = 20'd2607;    7: atan_turns = 20'd1304;    8: atan_turns = 20'd652;
		9: atan_turns = 20'd326;     10: atan_turns = 20'd163;    11: atan_turns = 20'd81;
		12: atan_turns = 20'd41;     13: atan_turns = 20'd20;     14: atan_turns = 20'd10;
		15: atan_turns = 20'd5;      16: atan_turns = 20'd3;      17: atan_turns = 20'd1;
		default: atan_turns = 20'd0;
	endcase
endfunction

localparam integer ITERATIONS = 18;

reg busy = 0;
reg mode;
reg [4:0] i;
reg signed [31:0] x, y;
reg signed [19:0] z;
wire rotate_positive = mode ? (y < 0) : (z >= 0);
wire signed [31:0] xs = x >>> i;
wire signed [31:0] ys = y >>> i;

always @(posedge clk) begin
	done <= 0;
	if(start) begin
		busy <= 1;
		i <= 0;
		mode <= vectoring;
		// Bring the problem into the right half plane (|angle| <= 0.25 turn).
		if(vectoring ? (x_in < 0) : (z_in > 20'sd262144 || z_in < -20'sd262144)) begin
			x <= -x_in;
			y <= -y_in;
			z <= vectoring ? 20'h80000 : z_in + 20'h80000;
		end else begin
			x <= x_in;
			y <= y_in;
			z <= vectoring ? 20'sd0 : z_in;
		end
	end else if(busy) begin
		if(rotate_positive) begin
			x <= x - ys;
			y <= y + xs;
			z <= z - $signed(atan_turns(i));
		end else begin
			x <= x + ys;
			y <= y - xs;
			z <= z + $signed(atan_turns(i));
		end
		if(i == ITERATIONS - 1) begin
			busy <= 0;
			done <= 1;
		end
		i <= i + 1'b1;
	end
end

always @(posedge clk) begin
	if(done) begin
		x_out <= x;
		y_out <= y;
		z_out <= z;
	end
end

endmodule
