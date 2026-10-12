#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=12"]
# ///
"""Capture actual MiSTer output using Zaparoo, optionally reading the panel.

Run with: uv run sim/mister_capture.py build/hardware/front.png
Pass --keys '{right*30}' to operate the core before capturing.
Direct video must be disabled to capture the complete native 640x480 raster.
"""
import argparse
import base64
import io
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def rpc(host, method, params=None, transport="ssh"):
    if transport == "ssh":
        argument = method if params is None else method + ":" + json.dumps(params)
        command = shlex.join(["/media/fat/Scripts/zaparoo.sh", "-api", argument])
        # MISTER_SSH overrides the ssh command, e.g. "sshpass -p 1 ssh -o PreferredAuthentications=password".
        ssh = shlex.split(os.environ.get("MISTER_SSH", "ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=10"))
        response = subprocess.run(ssh + [f"root@{host}", command], check=True, capture_output=True, text=True, timeout=60)
        result = json.loads(response.stdout)
        if result is None:
            return None
        if "error" in result:
            raise RuntimeError(result["error"])
        return result.get("result", result)
    request = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        request["params"] = params
    with urlopen(Request(f"http://{host}:7497/api/v0.1", json.dumps(request).encode(),
                         {"Content-Type": "application/json"}), timeout=30) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError(result["error"])
    return result["result"]


def load_font():
    """Glyph bitmaps from the generated font, keyed by the 35-bit pattern."""
    text = (ROOT / "rtl/am_font.sv").read_text()
    glyphs = {}
    for code, bits, name in re.findall(r"8'h([0-9a-f]{2}): glyph = 35'b([01]{35}); // (.)", text):
        glyphs[tuple(int(b) for b in bits)] = name
    return glyphs


def read_text(image, left, top, length, light=True):
    """Decode a run of 6x8 character cells starting at a pixel position."""
    glyphs = load_font()
    out = []
    for c in range(length):
        x0, y0 = left + c * 6, top
        bits = []
        for dy in range(7):
            for dx in range(5):
                r, g, b = image.getpixel((x0 + dx, y0 + dy))[:3]
                bits.append(int((r + g + b) > 420 if light else (r + g + b) < 300))
        out.append(glyphs.get(tuple(bits), " " if not any(bits) else "?"))
    return "".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--host", default="mister")
    parser.add_argument("--transport", choices=("ssh", "http"), default="ssh")
    parser.add_argument("--keys", help="Zaparoo keyboard macro sent before the capture")
    parser.add_argument("--settle", type=float, default=0.5)
    parser.add_argument("--read", action="append", default=[],
                        help="col,row,length[,dark]: decode text at a 6-pixel column and pixel row")
    args = parser.parse_args()
    if args.keys:
        rpc(args.host, "input.keyboard", {"keys": args.keys}, args.transport)
        time.sleep(args.settle)
    shot = rpc(args.host, "screenshot", transport=args.transport)
    if not shot:
        raise SystemExit("no screenshot returned")
    data = base64.b64decode(shot["data"])
    image = Image.open(io.BytesIO(data)).convert("RGB")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    if image.size != (640, 480):
        image = image.resize((640, 480), Image.Resampling.NEAREST)
    result = {"image": str(args.output), "size": image.size, "text": {}}
    for spec in args.read:
        parts = spec.split(",")
        col, row, length = int(parts[0]), int(parts[1]), int(parts[2])
        dark = len(parts) > 3 and parts[3] == "dark"
        result["text"][spec] = read_text(image, col * 6, row, length, light=not dark)
    print(json.dumps(result))


if __name__ == "__main__":
    sys.exit(main())
