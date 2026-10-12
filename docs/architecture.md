# Implementation notes

## Time and the gear train

The crank is the only input. Time is a signed count of ticks of 1/65536 day
since the epoch; one turn of b1 is 365¼ days, so a year is exactly 23,937,024
ticks. Every shaft the display needs (`am_shafts`) keeps an accumulator
`F` in `[0, D)` with `D = denominator × ticks per year` and adds the numerator
of its tooth-count ratio on every tick. The angle of the shaft is `F/D` turns.
Nothing is rounded, so the pointers keep their exact relationships forever and
the Metonic and Saros cell numbers are computed from the integer accumulators.

The timebase turns speed settings and key presses into power-of-two tick
steps (up to one day at a time) and applies them to the 23 accumulators one
shaft per clock. Once per frame the accumulators are converted to 20-bit
fractions of a turn by sequential division, the anomalies are evaluated, and
the calendar readouts are recomputed; the renderer snapshots the result at the
start of the next frame.

Pin-and-slot devices and epicycles are evaluated with one shared iterative
CORDIC (`am_cosmos`): rotate the epicycle vector by the anomaly, add the
deferent radius, and take the angle. Angles are 20-bit turns with Q8.24
vectors, which keeps every longitude within 0.004° of the floating-point
model.

## Renderer

`am_video` generates 640×480 at 25 MHz from the 50 MHz core clock. Each pixel
is first assigned to a dial (or a wheel in the gear view) and converted to
polar coordinates about that centre by a 13-stage pipelined CORDIC. Rings,
ticks, spirals, pointers and the curved inscriptions then reduce to
comparisons on radius and angle:

* a pointer is `|angle − pointer| ≤ pixels / (2π r)`, using a lookup table
  of one pixel of angle at each radius;
* a spiral cell is `floor((r − r0)/pitch − angle)` turns plus the angle,
  times cells per turn;
* ring text indexes a string stored once per ring at one character per
  1/N turn, with the glyph column from the fraction and the row from the
  radius, so inscriptions follow the dial like engraving.

All renderer registers are enabled by the pixel clock enable, giving the
logic two 50 MHz cycles; `Antikythera.sdc` declares that multicycle path.
Text comes from a generated ROM (`am_strings`) and a 5×7 font with the Greek
letters the dials need (`am_font`).

The wrapper feeds the core's RGB, blanking and sync pulses through the
framework's `video_mixer` (gamma correction and HDMI freeze) and
`video_freak` (aspect ratio and integer scaling). The picture is already
640×480 at 31 kHz, so the scandoubler stays off and the same raster goes to
the HDMI scaler, direct video and the analog output; the 2:1 clock to pixel
ratio is enough for that path. The framework's `forced_scandoubler` request
is therefore ignored, as it is by the companion Difference Engine core.

## Modules

| Module | Responsibility |
| --- | --- |
| `am_timebase` | run/pause, speed, direction, stepping, tick count |
| `am_shafts` | exact accumulators for 23 shafts, fraction conversion, exact cells |
| `am_cordic`, `am_cosmos` | anomalies, planets, phase and pointer vectors |
| `am_calendar` | Julian and Egyptian dates, zodiac positions, dial readings, glyphs, parapegma |
| `am_controls` | PS/2 keys, gamepad, auto-repeat |
| `am_polar`, `am_video`, `am_font`, `am_strings` | raster and drawing |
| `antikythera` | portable top level; `Antikythera.sv` is the MiSTer wrapper |

`tools/mechanism.py` is the reference model; `tools/generate_tables.py`
writes `rtl/am_tables.svh`, `rtl/am_strings.sv` and `rtl/am_font.sv` from it.
The `sys/` framework is unmodified.
