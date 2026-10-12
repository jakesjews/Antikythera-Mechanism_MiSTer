`timescale 1ns/1ps
// Exercise the MiSTer wrapper with the unmodified framework modules in the
// video chain: hps_io (idle bus, default status), video_mixer and
// video_freak. Checks the raster the framework receives and dumps one frame
// for a pixel-for-pixel comparison with the standalone core.
module tb_emu;
reg clk = 0;
reg clk100 = 0;
always #10 clk = !clk;
always #5 clk100 = !clk100;
reg reset = 1;
reg osd = 0;
tri [45:0] bus;
wire hs, vs, de, ce, f1;
wire [7:0] r, g, b;
wire [12:0] arx, ary;
assign bus[31:16] = 16'd0;
assign bus[35:33] = 3'd0;
assign bus[45:38] = {1'b0, vs, clk100, clk, ce, de, hs, vs};

emu dut (
	.CLK_50M(clk), .RESET(reset), .OSD_STATUS(osd), .HPS_BUS(bus),
	.VGA_HS(hs), .VGA_VS(vs), .VGA_DE(de), .CE_PIXEL(ce), .VGA_F1(f1),
	.VGA_R(r), .VGA_G(g), .VGA_B(b), .VIDEO_ARX(arx), .VIDEO_ARY(ary),
	.HDMI_WIDTH(12'd1920), .HDMI_HEIGHT(12'd1080)
);

reg [23:0] frame [0:640*480-1];
integer x = 0, y = 0, lines = 0, pixels_in_line = 0, max_pixels = 0, min_pixels = 1000, frames = 0;
reg old_vs = 0, old_hs = 0, old_de = 0;
reg cur_field = 0;
wire integer row = 2 * y + cur_field;
wire integer px = old_de ? x : 0;
integer f, i;

always @(posedge clk) if(ce) begin
	old_vs <= vs; old_hs <= hs; old_de <= de;
	if(vs && !old_vs) begin
		if(frames != 0) $display("field %0d (F1=%0d): %0d active lines, %0d..%0d pixels per line", frames, cur_field, lines, min_pixels, max_pixels);
		// video_freak measures the picture during the first frames.
		if(frames >= 3) begin
			if(lines != 240) begin $display("FAIL field %0d: %0d active lines, expected 240", frames, lines); $fatal(1); end
			if(min_pixels != 640 || max_pixels != 640) begin $display("FAIL frame %0d: %0d..%0d pixels per line, expected 640", frames, min_pixels, max_pixels); $fatal(1); end
		end
		frames <= frames + 1;
		lines <= 0; y <= 0; max_pixels <= 0; min_pixels <= 1000;
	end
	if(de && !old_de && y == 0) cur_field <= f1;
	if(de) begin
		if(row < 480 && px < 640) frame[row*640 + px] <= {r, g, b};
		x <= px + 1;
		pixels_in_line <= (old_de ? pixels_in_line : 0) + 1;
	end
	if(!de && old_de) begin
		lines <= lines + 1; y <= y + 1;
		if(pixels_in_line > max_pixels) max_pixels <= pixels_in_line;
		if(pixels_in_line < min_pixels) min_pixels <= pixels_in_line;
	end
end

initial begin
	repeat(100) @(posedge clk);
	reset = 0;
	// Settle, then let the core recompute and the renderer snapshot its state.
	wait(frames == 7);
	if(arx != 13'd4 || ary != 13'd3) begin $display("FAIL aspect ratio %0d:%0d, expected 4:3", arx, ary); $fatal(1); end
	wait(frames == 9);
	f = $fopen("build/mister/frame.ppm", "wb");
	$fwrite(f, "P6\n640 480\n255\n");
	for(i = 0; i < 640*480; i = i + 1) $fwrite(f, "%c%c%c", frame[i][23:16], frame[i][15:8], frame[i][7:0]);
	$fclose(f);
	$display("PASS MiSTer wrapper: 15 kHz interlaced 640x480 through hps_io, video_mixer and video_freak, aspect 4:3; frame written");
	$finish;
end
initial begin #200000000; $display("FAIL timeout"); $fatal(1); end
endmodule
