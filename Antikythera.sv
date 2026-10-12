// SPDX-License-Identifier: GPL-2.0-or-later
// MiSTer wrapper. sys/ is the original, unmodified framework.
module emu (
	`include "sys/emu_ports.vh"
);

assign ADC_BUS = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH,
	SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;
assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

`ifdef MISTER_DUAL_SDRAM
assign {SDRAM2_DQ, SDRAM2_A, SDRAM2_BA, SDRAM2_CLK, SDRAM2_nCS, SDRAM2_nCAS, SDRAM2_nRAS, SDRAM2_nWE} = 'Z;
`endif

`include "build_id.v"
localparam CONF_STR = {
	"Antikythera;;",
	"-;",
	"O[2],Epoch,205 BC Freeth/Jones,178 BC Voulgaris;",
	"O[3],Calendar ring,Egyptian 365 days,Lunar 354 holes;",
	"O[4],Ring registration,Automatic,By hand;",
	"O[5],Cosmos display,2021 planets,Sun and Moon only;",
	"O[6],Gear b1 teeth,223,224;",
	"-;",
	"O[8:7],View,Front dial,Back dials,Gear train;",
	"T[9],Show selected view;",
	"T[10],Run / Pause;",
	"T[11],Return to the epoch;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[13:12],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"O[15:14],Scan rate,MiSTer.ini,15 kHz interlaced,31 kHz progressive;",
	"O[16],Deinterlace,Weave,Bob;",
	"O[17],Sound,On,Off;",
	"-;",
	"-,F1 Help / Space Run;",
	"-,Arrows Crank / Tab View;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J,Crank +,Crank -,Run / Pause,View,Faster,Slower,Help,Reverse;",
	"jn,A,B,X,Y,R,L,Start,Select;",
	"v,1;",
	"V,v",`BUILD_DATE
};

wire [127:0] status;
wire [1:0] buttons;
wire forced_scandoubler;
wire [10:0] ps2_key;
wire [31:0] joystick;
wire clk_sys, pll_locked;
am_pll pll (.refclk(CLK_50M), .clk(clk_sys), .locked(pll_locked));
wire [35:0] ext_bus;
wire [21:0] gamma_bus;
assign ext_bus[32] = 1'b0;
assign ext_bus[15:0] = 16'd0;
wire [31:0] sd_lba [0:0];
wire [5:0] sd_blk_cnt [0:0];
wire [7:0] sd_buff_din [0:0];
assign sd_lba[0] = 0;
assign sd_blk_cnt[0] = 0;
assign sd_buff_din[0] = 0;

hps_io #(.CONF_STR(CONF_STR)) hps_io (
	.clk_sys(clk_sys), .HPS_BUS(HPS_BUS), .EXT_BUS(ext_bus), .gamma_bus(gamma_bus),
	.buttons(buttons), .status(status), .status_menumask(16'd0), .forced_scandoubler(forced_scandoubler),
	.status_in(128'd0), .status_set(1'b0), .info_req(1'b0), .info(8'd0),
	.new_vmode(1'b0), .video_rotated(1'b0),
	.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_buff_din(sd_buff_din), .sd_rd(1'b0), .sd_wr(1'b0),
	.ps2_kbd_clk_in(1'b1), .ps2_kbd_data_in(1'b1), .ps2_mouse_clk_in(1'b1), .ps2_mouse_data_in(1'b1),
	.ps2_kbd_led_status(3'd0), .ps2_kbd_led_use(3'd0),
	.joystick_0_rumble(16'd0), .joystick_1_rumble(16'd0), .joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0), .joystick_4_rumble(16'd0), .joystick_5_rumble(16'd0),
	.ps2_key(ps2_key), .joystick_0(joystick),
	.ioctl_wait(1'b0), .ioctl_upload_req(1'b0), .ioctl_upload_index(8'd0), .ioctl_din(8'd0)
);

wire reset_request = RESET | status[0] | buttons[1] | !pll_locked;
// Asynchronous assertion, synchronous release into the 50 MHz core domain.
reg [1:0] reset_sync = 2'b11;
always @(posedge clk_sys or posedge reset_request) begin
	if(reset_request) reset_sync <= 2'b11;
	else reset_sync <= {reset_sync[0],1'b0};
end

assign CLK_VIDEO = clk_sys;

// The core draws its 640x480 picture as 15 kHz interlaced fields by default
// and switches to a 31 kHz progressive raster itself when MiSTer.ini asks
// for a scandoubler (forced_scandoubler=1) or the menu does, so the mixer's
// scandoubler stays off. The mixer adds gamma and HDMI freeze; video_freak
// adds the aspect ratio and integer scaling options.
wire progressive = status[15:14] == 2'd0 ? forced_scandoubler : status[15:14] == 2'd2;
assign HDMI_BOB_DEINT = status[16];
wire core_ce, core_hs_n, core_vs_n, core_hb, core_vb, core_de, core_field;
wire signed [15:0] core_audio;
assign VGA_F1 = core_field;
assign AUDIO_L = core_audio;
assign AUDIO_R = core_audio;
wire [7:0] core_r, core_g, core_b;
wire mixer_de;
wire [1:0] ar = status[122:121];

video_mixer #(.LINE_LENGTH(640), .HALF_DEPTH(0), .GAMMA(1)) video_mixer (
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .ce_pix(core_ce),
	.scandoubler(1'b0), .hq2x(1'b0), .gamma_bus(gamma_bus),
	.R(core_r), .G(core_g), .B(core_b),
	.HSync(!core_hs_n), .VSync(!core_vs_n), .HBlank(core_hb), .VBlank(core_vb),
	.HDMI_FREEZE(HDMI_FREEZE), .freeze_sync(),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(mixer_de)
);

video_freak video_freak (
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE), .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(mixer_de),
	.ARX((ar == 0) ? 12'd4 : {10'd0, ar - 2'd1}),
	.ARY((ar == 0) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0), .CROP_OFF(5'd0), .SCALE({1'b0, status[13:12]})
);

antikythera core (
	.clk(clk_sys), .reset(reset_sync[1]), .osd_open(OSD_STATUS),
	.ps2_key(ps2_key), .joystick(joystick[7:0]),
	.menu_epoch(status[2]), .menu_b1_224(status[6]), .menu_ring_lunar(status[3]),
	.menu_ring_manual(status[4]), .menu_cosmos_off(status[5]),
	.menu_view(status[8:7]), .menu_view_set(status[9]), .menu_run(status[10]), .menu_home(status[11]),
	.progressive(progressive), .sound_on(!status[17]),
	.ce_pixel(core_ce), .red(core_r), .green(core_g), .blue(core_b),
	.hsync(core_hs_n), .vsync(core_vs_n), .de(core_de), .hblank(core_hb), .vblank(core_vb), .field(core_field), .audio(core_audio),
	.running(LED_USER), .ticks(), .fracs(), .lon_sun(), .lon_moon(), .lon_node(), .lon_mercury(), .lon_venus(),
	.lon_mars(), .lon_jupiter(), .lon_saturn(), .met_cell(), .sar_cell(),
	.debug_ring_offset(), .debug_ring_auto(), .debug_ring_index(), .frame_done()
);

endmodule
