#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=12"]
# ///
"""Drive the core on a real MiSTer through Zaparoo and check what it displays.

Usage: uv run sim/hardware_checks.py [--host mister] [--out build/hardware]
The core must be loaded, direct video off, and the Zaparoo service running.
"""
import argparse
import base64
import io
import json
import sys
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sim"))
sys.path.insert(0, str(ROOT / "tools"))
from mister_capture import read_text, rpc  # noqa: E402
import mechanism as M  # noqa: E402

DAY = 65536
MONTH = 1935274
YEAR = int(M.YEAR_TICKS)


def expected_front(epoch, ticks):
    """Readout lines the front panel should show for this many ticks after the epoch."""
    jdn0, off = M.epoch_day_fields(epoch)
    jdn = jdn0 + ((ticks + off) >> 16)
    y, m, d = M.julian_calendar(jdn)
    era = "AD" if y > 0 else "BC"
    year = y if y > 0 else 1 - y
    pos = M.positions(epoch, ticks)

    def sign_deg(turns):
        deg = int(turns * 360) % 360
        return f"{M.ZODIAC[deg // 30][1]:<11}{deg % 30:>3}°"

    return {
        "date": f"DATE      {d:>2} {M.JULIAN_MONTHS[m - 1]} {year:>4} {era}",
        "date_ptr": "DATE PTR " + sign_deg(pos["date"]),
        "sun": "SUN      " + sign_deg(pos["sun"]),
        "moon": "MOON     " + sign_deg(pos["moon"]),
        "node": "NODE     " + sign_deg(pos["node"]),
    }


def capture(host, out, name, keys=None, settle=0.6):
    if keys:
        rpc(host, "input.keyboard", {"keys": keys})
        time.sleep(settle)
    shot = rpc(host, "screenshot")
    data = base64.b64decode(shot["data"])
    path = out / f"{name}.png"
    path.write_bytes(data)
    image = Image.open(io.BytesIO(data)).convert("RGB")
    if image.size != (640, 480):
        image = image.resize((640, 480), Image.Resampling.NEAREST)
    return image


def front_lines(image):
    return {
        "date": read_text(image, 74 * 6, 44, 24).rstrip(),
        "date_ptr": read_text(image, 74 * 6, 88, 24).rstrip(),
        "sun": read_text(image, 74 * 6, 100, 24).rstrip(),
        "moon": read_text(image, 74 * 6, 112, 24).rstrip(),
        "node": read_text(image, 74 * 6, 148, 24).rstrip(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="mister")
    parser.add_argument("--out", type=Path, default=ROOT / "build/hardware")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    log = (args.out / "checks.jsonl").open("a")
    failures = 0

    def check(name, image, expected):
        nonlocal failures
        got = front_lines(image)
        ok = all(got[k].replace(" ", "") == expected[k].replace(" ", "") for k in expected)
        record = {"check": name, "ok": ok, "got": got, "expected": expected}
        log.write(json.dumps(record, ensure_ascii=False) + "\n")
        print(("PASS " if ok else "FAIL ") + name)
        if not ok:
            failures += 1
            for k in expected:
                if got[k].replace(" ", "") != expected[k].replace(" ", ""):
                    print(f"   {k}: got {got[k]!r}, expected {expected[k]!r}")

    epoch = M.EPOCHS[0]
    # Fresh epoch, front view.
    image = capture(args.host, args.out, "01-epoch", keys="{home}{1}", settle=1.0)
    check("epoch", image, expected_front(epoch, 0))
    # Thirty days forward with the crank key.
    image = capture(args.host, args.out, "02-thirty-days", keys="{right*30}", settle=1.0)
    check("thirty days", image, expected_front(epoch, 30 * DAY))
    # Seven lunar months and two years.
    image = capture(args.host, args.out, "03-months-years", keys="{up*7}{pgup*2}", settle=1.5)
    check("seven months two years", image, expected_front(epoch, 30 * DAY + 7 * MONTH + 2 * YEAR))
    # Back dials and gear train, for the record.
    capture(args.host, args.out, "04-back", keys="{2}")
    capture(args.host, args.out, "05-gears", keys="{3}")
    capture(args.host, args.out, "06-help", keys="{1}{f1}")
    capture(args.host, args.out, "07-help-closed", keys="{f1}")
    # Backwards past the epoch.
    image = capture(args.host, args.out, "08-backwards", keys="{home}{pgdn*3}{left*5}", settle=1.5)
    check("three years five days before", image, expected_front(epoch, -3 * YEAR - 5 * DAY))
    # Run for a while and confirm the date advanced.
    rpc(args.host, "input.keyboard", {"keys": "{home}{space}"})
    time.sleep(10)
    image = capture(args.host, args.out, "09-running", keys="{space}", settle=0.8)
    running = front_lines(image)
    advanced = running["date"] != expected_front(epoch, 0)["date"]
    log.write(json.dumps({"check": "running", "ok": advanced, "got": running}, ensure_ascii=False) + "\n")
    print(("PASS " if advanced else "FAIL ") + f"running: {running['date']!r}")
    failures += 0 if advanced else 1
    capture(args.host, args.out, "10-final", keys="{home}")
    log.close()
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
