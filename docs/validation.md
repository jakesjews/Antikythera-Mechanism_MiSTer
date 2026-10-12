# Validation — 12 October 2026

Tested release: [`Antikythera_20261012.rbf`](../releases/Antikythera_20261012.rbf).

## Model

`tools/mechanism.py` checks itself on every run:

- the intercalation scheme (years 1, 3, 6, 9, 11, 14, 17; Machaneus repeated)
  reproduces all 24 attested cell readings of the Metonic dial listed by Jones
  (2017);
- the Eclipse Year Model yields 38 lunar and 28 solar predictions in 51 cells
  and includes all 18 surviving glyph months and the 22 preserved glyph times'
  months.

## Simulation

`make test` passed on the final RTL (Verilator 5.052):

- lint clean with `-Wall`;
- ten vectors over both epochs, reached with year, lunar-month and day steps
  forward and backward (up to 40 years), comparing all 23 shaft angles to the
  exact rational model within 3 × 10⁻⁶ turn, the true Sun, Moon, node and
  five planets within 10⁻⁵ turn (0.0036°), and the exact Metonic and Saros
  cell numbers;
- turning the calendar ring by hand moves the reading one day per turn;
- the two fields of the 15 kHz interlaced raster assemble into exactly the
  progressive 640×480 frame (every pixel compared);
- a turn by hand produces a click, and six of the Mechanism's months after
  the 178 BC epoch the Saros pointer enters glyph cell 8 and the chime plays;
- 640×480 captures of every view in `build/screenshots/` were inspected;
- the MiSTer wrapper with the unmodified `hps_io`, `video_freezer`,
  `gamma_corr`, `scandoubler` and `video_freak` (and a scoping-only copy of
  `video_mixer`, see development.md) delivers the 15 kHz interlaced raster,
  240 lines per field with the field flag alternating, at 4:3, and its
  assembled frame is pixel-identical to the standalone core's.

## Quartus

Quartus Prime Lite 17.0.2 (Docker image `theypsilon/quartus-lite-c5:17.0.2.docker0`
on the build server) completed synthesis, fitting, assembly and timing for the
Cyclone V 5CSEBA6U23I7.

The complete MiSTer design uses 22,273 ALMs (53%), 8% of the block memory,
38 DSP blocks (33 in the framework, 5 in the sound synthesiser; the renderer's
multipliers are in logic) and three PLLs.

All four operating corners pass. Worst slack in nanoseconds:

| Corner | Setup | Hold | Recovery | Removal |
| --- | ---: | ---: | ---: | ---: |
| Slow 1100mV 100C Model | 0.229 | 0.252 | 4.163 | 1.067 |
| Slow 1100mV -40C Model | 0.122 | 0.099 | 4.274 | 0.983 |
| Fast 1100mV 100C Model | 2.983 | 0.098 | 5.265 | 0.527 |
| Fast 1100mV -40C Model | 3.616 | 0.078 | 5.494 | 0.448 |

The renderer's pixel-enable domain is constrained as a two-cycle multicycle
path in `Antikythera.sdc`; no framework constraint or source was changed.

Local evidence: `build/quartus-compile.log`, `build/timing-report.log`,
`build/timing-corners.tsv`, `build/critical-paths.rpt`.

## MiSTer

The bitstream was loaded on a DE10-Nano running MiSTer and exercised through
Zaparoo keyboard input, with a temporary `direct_video=0` override for the
core so that the native 640×480 raster could be captured. Readouts were
decoded from the screenshots with the core's own font and compared with the
Python model (`sim/hardware_checks.py`, log in `build/hardware/checks.jsonl`):

- epoch: 28 April 205 BC, date pointer, Sun, Moon and node as modelled;
- thirty crank days: 28 May 205 BC and the matching longitudes;
- seven lunar months and two years: 22 December 203 BC;
- three years and five days before the epoch: 24 April 208 BC;
- free running at one year per second advanced the date, and pausing stopped it;
- the back dials, gear train and help card rendered as in simulation;
- with the video routed through `video_mixer` and `video_freak`, the same
  checks passed again. Zaparoo captures the core's raster before the scaler,
  so the Scale option's integer scaling could not be observed that way; its
  4:3 default was checked in the wrapper simulation;
- the status panel read `15 KHZ` on a plain `MiSTer.ini`; adding
  `forced_scandoubler=1` to a temporary `[Antikythera]` section and reloading
  the core changed it to `31 KHZ` with the same readouts; and the menu's
  Scan rate option switched the running core to `31 KHZ` and back
  (`build/hardware/12-scan-31khz.png`, `13-scan-restored.png`). MiSTer's
  core option page changes a value with Enter, not with the left and right
  arrows, which is why the check script presses Enter;
- the epoch option toggled from the menu moved the date to 23 December
  178 BC and back to 28 April 205 BC.

Zaparoo screenshots are taken before the OSD is overlaid, so the menu itself
is not in the captures; its effect was read from the status panel. The sound
output goes to the HDMI and analogue audio paths, which cannot be captured
remotely, so the clicks, ticks and chimes were verified in simulation only.

The temporary INI override was removed afterwards and the original INI
checked byte for byte. Gamepad control uses the same `hps_io` joystick bits
as the keyboard paths above but was not exercised on hardware.
