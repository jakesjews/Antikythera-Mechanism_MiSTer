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
- 640×480 captures of every view in `build/screenshots/` were inspected;
- the MiSTer wrapper with the unmodified `hps_io`, `video_freezer`,
  `gamma_corr`, `scandoubler` and `video_freak` (and a scoping-only copy of
  `video_mixer`, see development.md) delivers a 640×480 raster at 4:3 whose
  frame is pixel-identical to the standalone core's.

## Quartus

Quartus Prime Lite 17.0.2 (Docker image `theypsilon/quartus-lite-c5:17.0.2.docker0`
on the build server) completed synthesis, fitting, assembly and timing for the
Cyclone V 5CSEBA6U23I7.

The complete MiSTer design uses 21,165 ALMs (51%), 18,028 registers, 7% of the
block memory, 33 DSP blocks (all in the framework; the core's multipliers are
in logic) and three PLLs.

All four operating corners pass. Worst slack in nanoseconds:

| Corner | Setup | Hold | Recovery | Removal |
| --- | ---: | ---: | ---: | ---: |
| Slow 1100mV 100C Model | 0.751 | 0.245 | 3.634 | 0.936 |
| Slow 1100mV -40C Model | 0.624 | 0.152 | 3.777 | 0.836 |
| Fast 1100mV 100C Model | 3.467 | 0.130 | 4.974 | 0.448 |
| Fast 1100mV -40C Model | 3.857 | 0.102 | 5.216 | 0.336 |

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
  4:3 default was checked in the wrapper simulation.

The temporary INI override was removed afterwards and the original INI
checked byte for byte. Gamepad control uses the same `hps_io` joystick bits
as the keyboard paths above but was not exercised on hardware.
