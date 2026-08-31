#!/usr/bin/env python3
"""Convert the original ZigOS wallpaper source to clean 1280x800 BGRA raw pixels."""
from pathlib import Path
from PIL import Image

source = Path("assets/wallpaper_source.jpg")
destination = Path("assets/wallpaper.raw")
image = Image.open(source).convert("RGBA")
image = image.resize((1280, 800), Image.Resampling.LANCZOS)
destination.write_bytes(image.tobytes())
print(f"normalized {source}: {image.width}x{image.height} -> {destination} ({destination.stat().st_size} bytes)")
