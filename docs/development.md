# Development

The Quartus project is `Antikythera.qpf`. The MiSTer framework under `sys/`
must remain unchanged. The mechanism, calendar, controls and renderer live in
`rtl/am_*.sv`; `rtl/antikythera.sv` is the portable top level and
`Antikythera.sv` the MiSTer interface. See [architecture.md](architecture.md)
and [research.md](research.md).

## Generated files

`rtl/am_tables.svh`, `rtl/am_strings.sv` and `rtl/am_font.sv` are written by
`tools/generate_tables.py` from the reference model `tools/mechanism.py`.
Edit the Python, then run `make tables` (or any target; they are rebuilt
automatically).

## Simulation

Requires Verilator, Python 3, a C++ compiler and Make; SDL2 for the window.

```sh
make test          # lint, model self-checks, RTL against the model
make screenshots   # PNG captures of every view in build/screenshots/
make sim           # interactive window with the core's keys
```

`make test` runs the model's own checks (the intercalation scheme against the
attested Metonic cells, the eclipse model against the surviving glyphs), then
drives the RTL through both epochs with year, month and day steps forward and
backward and compares all 23 shaft angles, the Sun, Moon, node and five
planets, and the exact Metonic and Saros cell numbers.

## Quartus

```sh
./build.sh remote compile   # Docker on the Ubuntu server (default)
./build.sh local compile    # CrossOver on this Mac
```

`tools/report_timing.tcl` checks all four corners and fails on negative
slack. Output is `output_files/Antikythera.rbf`; reports land in `build/`.

## MiSTer checks

`sim/mister_capture.py` sends keys through a running Zaparoo service and
saves the FPGA's own screenshot, optionally decoding readout text with the
core's font:

```sh
uv run sim/mister_capture.py build/hardware/front.png --read 74,44,30
uv run sim/mister_capture.py build/hardware/back.png --keys '{2}' --read 42,76,30
```

Direct video must be off for a complete 640×480 capture; use a temporary
`[Antikythera]` section in `MiSTer.ini` and restore the file afterwards.
