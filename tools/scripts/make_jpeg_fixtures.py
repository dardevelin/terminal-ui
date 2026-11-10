#!/usr/bin/env python3
"""Make the JPEG decoder's fixtures in Tests/TerminalUIIOTests/Fixtures/jpeg.

Each fixture is a small synthetic picture encoded by libjpeg-turbo's `cjpeg`
with one feature of ITU-T T.81 the decoder must handle (a chroma sampling,
restart markers, greyscale, 16-bit quantisation tables, optimised Huffman
tables), and beside it the same JPEG as macOS ImageIO decodes it, through
`sips`, as raw RGBA (`<name>.rgba`, 4 bytes a pixel, rows top down) — so the
Swift test compares against an independent decoder on any system, Linux
included, without sips.

macOS only (sips). Run from the repository root:

    python3 tools/scripts/make_jpeg_fixtures.py
"""

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

OUTPUT = Path("Tests") / "TerminalUIIOTests" / "Fixtures" / "jpeg"

# Stands in a fixture's arguments for the scan script's path.
SCAN_SCRIPT = "<scan script>"


def picture(width: int, height: int) -> bytes:
    """RGB rows: gradients across and down, a hard-edged block and a
    one-pixel checker strip, so partial MCUs and edges both show."""
    rows = bytearray()
    for y in range(height):
        for x in range(width):
            red = x * 255 // max(1, width - 1)
            green = y * 255 // max(1, height - 1)
            blue = (x * 7 + y * 13) % 256
            if width // 4 <= x < width // 2 and height // 4 <= y < height // 2:
                red, green, blue = 230, 40, 30
            if y == height - 3:
                red = green = blue = 255 if x % 2 == 0 else 0
            rows += bytes((red, green, blue))
    return bytes(rows)


def write_ppm(path: Path, width: int, height: int) -> None:
    path.write_bytes(f"P6\n{width} {height}\n255\n".encode() + picture(width, height))


def bmp_to_rgba(path: Path) -> tuple[int, int, bytes]:
    """A BITMAPINFOHEADER-family BMP of 24 or 32 bits a pixel, uncompressed
    or BI_BITFIELDS with the usual BGRA masks, as RGBA top down."""
    data = path.read_bytes()
    if data[:2] != b"BM":
        raise ValueError(f"{path} is not a BMP")
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bits = struct.unpack_from("<H", data, 28)[0]
    compression = struct.unpack_from("<I", data, 30)[0]
    if bits not in (24, 32) or compression not in (0, 3):
        raise ValueError(f"{path}: {bits} bits, compression {compression}")
    bottom_up = height > 0
    height = abs(height)
    stride = (width * bits // 8 + 3) & ~3
    out = bytearray()
    for row in range(height):
        source_row = height - 1 - row if bottom_up else row
        base = pixel_offset + source_row * stride
        for x in range(width):
            offset = base + x * (bits // 8)
            blue, green, red = data[offset], data[offset + 1], data[offset + 2]
            out += bytes((red, green, blue, 255))
    return width, height, bytes(out)


# Name, source size, cjpeg arguments.
FIXTURES = [
    ("odd-444", (37, 29), ["-baseline", "-quality", "90", "-sample", "1x1"]),
    ("odd-422", (37, 29), ["-baseline", "-quality", "90", "-sample", "2x1"]),
    ("odd-420", (37, 29), ["-baseline", "-quality", "90", "-sample", "2x2"]),
    ("odd-440", (37, 29), ["-baseline", "-quality", "90", "-sample", "1x2"]),
    ("odd-grey", (37, 29), ["-baseline", "-quality", "90", "-grayscale"]),
    ("restart-420", (64, 48), ["-baseline", "-quality", "85", "-sample", "2x2", "-restart", "3B"]),
    ("restart-rows-444", (64, 48), ["-baseline", "-quality", "85", "-sample", "1x1", "-restart", "1"]),
    ("optimised-420", (64, 48), ["-baseline", "-quality", "75", "-optimize", "-sample", "2x2"]),
    ("coarse-16bit-tables", (64, 48), ["-quality", "3", "-sample", "2x2"]),
    ("progressive", (64, 48), ["-progressive", "-quality", "80"]),
    ("separate-scans-420", (37, 29), ["-baseline", "-quality", "90", "-sample", "2x2", "-scans", SCAN_SCRIPT]),
    ("tile-256-420", (256, 256), ["-baseline", "-quality", "80", "-sample", "2x2"]),
]

# A cjpeg scan script of one sequential scan per component (T.81 A.2.2's
# non-interleaved order) rather than one scan of all three.
SEPARATE_SCANS = "0;\n1;\n2;\n"


def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        scratch_dir = Path(scratch)
        scan_script = scratch_dir / "separate.scans"
        scan_script.write_text(SEPARATE_SCANS)
        for name, (width, height), arguments in FIXTURES:
            source = scratch_dir / f"{width}x{height}.ppm"
            if not source.exists():
                write_ppm(source, width, height)
            jpeg = OUTPUT / f"{name}.jpg"
            arguments = [str(scan_script) if argument == SCAN_SCRIPT else argument for argument in arguments]
            subprocess.run(["cjpeg", *arguments, "-outfile", str(jpeg), str(source)], check=True)
            # The progressive file is only ever refused, and a whole tile's
            # reference would be a quarter of a megabyte: it is timed, not
            # compared.
            if name == "progressive" or name.startswith("tile-"):
                continue
            bmp = scratch_dir / f"{name}.bmp"
            subprocess.run(["sips", "-s", "format", "bmp", str(jpeg), "--out", str(bmp)],
                           check=True, capture_output=True)
            decoded_width, decoded_height, rgba = bmp_to_rgba(bmp)
            if (decoded_width, decoded_height) != (width, height):
                raise ValueError(f"{name}: ImageIO decoded {decoded_width}x{decoded_height}")
            (OUTPUT / f"{name}.rgba").write_bytes(rgba)
            # libjpeg-turbo's own decode (djpeg's defaults: the islow IDCT,
            # "fancy" upsampling) as a second reference. ImageIO upsamples
            # chroma its own way, so near a sharp colour edge it and libjpeg
            # disagree by tens of levels; libjpeg upsamples as this decoder
            # does, so those two agree within a few levels everywhere.
            ppm = subprocess.run(["djpeg", "-pnm", str(jpeg)], check=True, capture_output=True).stdout
            (OUTPUT / f"{name}.djpeg.rgba").write_bytes(pnm_to_rgba(ppm, width, height))
    return 0


def pnm_to_rgba(pnm: bytes, width: int, height: int) -> bytes:
    """A binary PPM (P6) or PGM (P5) of maxval 255, as djpeg writes them,
    as RGBA."""
    for magic, channels in ((b"P6", 3), (b"P5", 1)):
        header = magic + f"\n{width} {height}\n255\n".encode()
        if pnm.startswith(header):
            break
    else:
        raise ValueError("unexpected PNM header from djpeg")
    pixels = pnm[len(header):]
    out = bytearray()
    for index in range(width * height):
        sample = pixels[index * channels:(index + 1) * channels]
        out += (sample * 3 if channels == 1 else sample) + b"\xff"
    return bytes(out)


if __name__ == "__main__":
    sys.exit(main())
