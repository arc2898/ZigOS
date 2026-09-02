#!/usr/bin/env python3
"""Create deterministic RGBA assets when the optional artwork is unavailable."""

from pathlib import Path

WIDTH, HEIGHT = 1280, 800
ASSETS = Path("assets")


def pixel(r: int, g: int, b: int, a: int = 255) -> bytes:
    return bytes((r, g, b, a))


def write_if_missing(name: str, data: bytes) -> None:
    path = ASSETS / name
    if not path.exists():
        path.write_bytes(data)
        print(f"Generated fallback {path} ({len(data)} bytes)")


def wallpaper() -> bytes:
    data = bytearray()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            data.extend(pixel(
                18 + (x * 24 // WIDTH),
                28 + (y * 24 // HEIGHT),
                58 + ((x + y) * 34 // (WIDTH + HEIGHT)),
            ))
    return bytes(data)


def icon(kind: str) -> bytes:
    data = bytearray(pixel(0, 0, 0, 0) * (64 * 64))

    def put(x: int, y: int, color: bytes) -> None:
        if 0 <= x < 64 and 0 <= y < 64:
            offset = (y * 64 + x) * 4
            data[offset:offset + 4] = color

    if kind == "folder":
        for y in range(18, 50):
            for x in range(8, 56):
                if y < 24 and x > 34:
                    continue
                put(x, y, pixel(242, 184, 65))
    elif kind == "file":
        for y in range(8, 55):
            for x in range(14, 50):
                if y < 18 and x < 38:
                    continue
                put(x, y, pixel(225, 232, 245))
        for y in range(27, 30):
            for x in range(21, 44):
                put(x, y, pixel(87, 109, 145))
    elif kind == "computer":
        for y in range(12, 43):
            for x in range(8, 56):
                if y in (12, 42) or x in (8, 55):
                    put(x, y, pixel(190, 215, 242))
        for y in range(17, 38):
            for x in range(13, 51):
                put(x, y, pixel(45, 78, 117))
        for x in range(20, 45):
            put(x, 48, pixel(190, 215, 242))
    elif kind == "network":
        for y in range(20, 50):
            span = max(1, (y - 12) // 3)
            for x in range(32 - span, 33 + span):
                put(x, y, pixel(94, 197, 255))
        for x, y in ((20, 19), (32, 12), (44, 19)):
            for dy in range(-4, 5):
                for dx in range(-4, 5):
                    if dx * dx + dy * dy <= 16:
                        put(x + dx, y + dy, pixel(94, 197, 255))
    elif kind == "trash":
        for y in range(18, 54):
            for x in range(16, 48):
                if x in (16, 47) or y == 53:
                    put(x, y, pixel(190, 215, 242))
        for x in range(13, 51):
            for y in range(14, 18):
                put(x, y, pixel(190, 215, 242))
        for x in range(25, 39):
            for y in range(10, 14):
                put(x, y, pixel(190, 215, 242))
    else:
        for y in range(10, 54):
            for x in range(10, 54):
                if (x - 32) ** 2 + (y - 32) ** 2 <= 22 ** 2:
                    put(x, y, pixel(111, 174, 255))
        for y in range(25, 40):
            for x in range(25, 40):
                if (x - 32) ** 2 + (y - 32) ** 2 <= 8 ** 2:
                    put(x, y, pixel(24, 39, 73))
    return bytes(data)


def cursor() -> bytes:
    data = bytearray(pixel(0, 0, 0, 0) * (32 * 32))
    for y in range(27):
        for x in range(17):
            if x <= y // 2 + 2:
                offset = (y * 32 + x) * 4
                data[offset:offset + 4] = pixel(255, 255, 255)
    return bytes(data)


ASSETS.mkdir(parents=True, exist_ok=True)
write_if_missing("wallpaper.raw", wallpaper())
write_if_missing("icon_folder.raw", icon("folder"))
write_if_missing("icon_file.raw", icon("file"))
write_if_missing("icon_settings.raw", icon("settings"))
write_if_missing("icon_computer.raw", icon("computer"))
write_if_missing("icon_network.raw", icon("network"))
write_if_missing("icon_trash.raw", icon("trash"))
write_if_missing("icon_zide.raw", icon("zide"))
write_if_missing("cursor_arrow.raw", cursor())