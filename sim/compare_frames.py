#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=12"]
# ///
"""Compare the frame captured from the MiSTer wrapper with the standalone core's."""
import sys
from PIL import Image

wrapper = Image.open(sys.argv[1]).convert("RGB")
core = Image.open(sys.argv[2]).convert("RGB")
assert wrapper.size == core.size == (640, 480), (wrapper.size, core.size)
a, b = wrapper.tobytes(), core.tobytes()
differing = sum(1 for i in range(0, len(a), 3) if a[i:i+3] != b[i:i+3])
print(f"{differing} of {640*480} pixels differ between the wrapper and the core")
sys.exit(0 if differing == 0 else 1)
