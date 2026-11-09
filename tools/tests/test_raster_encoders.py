#!/usr/bin/env python3
"""The raster encoders' goldens decode, by means that share none of their code.

``Tests/TerminalUIRasterTests`` holds every zlib stream, PNG and GIF the
Swift encoders are checked against byte for byte, and
``Tests/TerminalUIRecordingTests`` the PNG stills and GIF animation the
raster renderer draws recorded screens as. Byte equality only says
the encoder still writes what it wrote once; this says what it wrote is
right. Each case rebuilds the picture or bytes a fixture was made from —
the same formulas as ``Samples.swift``, restated here — and decodes the
fixture with Python's zlib (RFC 1950/1951), a PNG reader and a GIF89a
decoder written from the specifications (``terminalui/images.py``), then
compares.

Run::

    python3 tools/tests/test_raster_encoders.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
import zlib
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import images  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402
from terminalui.images import GIFDecoding, Pixel  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[2] / "Tests" / "TerminalUIRasterTests" / "Fixtures"
RECORDING_FIXTURES = Path(__file__).resolve().parents[2] / "Tests" / "TerminalUIRecordingTests" / "Fixtures"

# MARK: - The samples, as Samples.swift makes them

class SampleRandom:
    """Knuth's MMIX linear congruential generator, its top byte taken."""

    def __init__(self, seed: int) -> None:
        self.state = seed

    def next_byte(self) -> int:
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        return self.state >> 56

    def take(self, count: int) -> bytes:
        return bytes(self.next_byte() for _ in range(count))


RANDOM_SEED, TEXT_SEED, NOISE_SEED = 2026, 1950, 89
WORDS = ["the", "framework", "records", "its", "own", "pictures", "terminal",
         "cell", "frame", "glyph", "border", "focus", "render", "a", "of", "to"]


def sample_text(word_count: int) -> bytes:
    generator = SampleRandom(TEXT_SEED)
    out = bytearray()
    for index in range(word_count):
        out += WORDS[generator.next_byte() % len(WORDS)].encode()
        out.append(0x0A if index % 12 == 11 else 0x20)
    return bytes(out)


REPETITIVE = b"abcabcabcabcabcabcabcabcabcabc"


def rgb_pixels() -> list[list[Pixel]]:
    return [[(40 * x + 15, 60 * y + 7, (x * y * 37) % 256, 255) for x in range(5)] for y in range(4)]


def rgba_pixels() -> list[list[Pixel]]:
    return [[(60 * x, 100 * y, 200, 255 - 60 * x - 20 * y) for x in range(4)] for y in range(3)]


INDEXED_PALETTE: list[Pixel] = [(0x1E, 0x1E, 0x2E, 255), (0xCB, 0xA6, 0xF7, 255), (0xA6, 0xE3, 0xA1, 0x80),
                                (0xF3, 0x8B, 0xA8, 255), (0x89, 0xB4, 0xFA, 255)]


def indexed_pixels() -> list[list[Pixel]]:
    return [[INDEXED_PALETTE[(x + 2 * y) % 5] for x in range(6)] for y in range(5)]


def two_colour_pixels() -> list[list[Pixel]]:
    colours = [(0, 0, 0, 255), (255, 255, 255, 255)]
    return [[colours[(x + y) % 2] for x in range(9)] for y in range(3)]


GIF_GLOBAL = [(0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 0, 255)]
GIF_LOCAL = [(0, 255, 0), (255, 255, 0), (0, 255, 255)]


def two_frame_screens() -> list[list[list[tuple[int, int, int]]]]:
    first = [[GIF_GLOBAL[(x + y) % 4] for x in range(8)] for y in range(6)]
    second = [row[:] for row in first]
    for offset, index in enumerate([0, 1, 2, 2, 1, 0]):
        if index != 1:
            second[1 + offset // 3][2 + offset % 3] = GIF_LOCAL[index]
    return [first, second]


def noise_palette() -> list[tuple[int, int, int]]:
    return [(value, 255 - value, (value * 7) % 256) for value in range(256)]


# MARK: - zlib

def deflate_block_type(stream: bytes) -> int:
    """The first block's BTYPE (RFC 1951 §3.2.3), after the zlib header."""
    return (stream[2] >> 1) & 0b11


STORED, FIXED, DYNAMIC = 0, 1, 2


def zlib_fixture(name: str, expected: bytes, block_type: int) -> None:
    stream = (FIXTURES / name).read_bytes()
    assert stream[0] == 0x78 and (stream[0] * 256 + stream[1]) % 31 == 0, f"{name}: header {stream[:2].hex()}"
    assert zlib.decompress(stream) == expected, f"{name}: decodes to other bytes"
    assert deflate_block_type(stream) == block_type, f"{name}: block type {deflate_block_type(stream)}"


def zlib_fixtures_decode() -> None:
    zlib_fixture("empty.zlib", b"", FIXED)
    zlib_fixture("repetitive.zlib", REPETITIVE, FIXED)
    zlib_fixture("text.zlib", sample_text(800), DYNAMIC)
    zlib_fixture("random.zlib", SampleRandom(RANDOM_SEED).take(2048), STORED)


def text_compresses_about_as_well_as_zlib() -> None:
    ours = len((FIXTURES / "text.zlib").read_bytes())
    reference = len(zlib.compress(sample_text(800), 6))
    assert ours <= reference * 1.05, f"{ours} bytes where zlib's default level writes {reference}"


# MARK: - PNG (W3C PNG Third Edition)

def decode_png(name: str | Path) -> tuple[list[bytes], list[list[Pixel]], list[int]]:
    """A PNG named in the encoders' fixtures, or at a path, decoded."""
    path = name if isinstance(name, Path) else FIXTURES / name
    return images.decode_png(path.read_bytes(), str(name))


def png_rgb_decodes() -> None:
    kinds, pixels, _ = decode_png("rgb-5x4.png")
    assert kinds == [b"IHDR", b"sRGB", b"IDAT", b"IEND"], kinds
    assert pixels == rgb_pixels(), pixels


def png_rgba_decodes() -> None:
    kinds, pixels, _ = decode_png("rgba-4x3.png")
    assert kinds == [b"IHDR", b"sRGB", b"IDAT", b"IEND"], kinds
    assert pixels == rgba_pixels(), pixels


def png_indexed_decodes() -> None:
    kinds, pixels, filters = decode_png("indexed-6x5.png")
    assert kinds == [b"IHDR", b"sRGB", b"PLTE", b"tRNS", b"IDAT", b"IEND"], kinds
    assert pixels == indexed_pixels(), pixels
    assert set(filters) == {0}, filters


def png_one_bit_decodes() -> None:
    kinds, pixels, _ = decode_png("indexed-9x3.png")
    assert kinds == [b"IHDR", b"sRGB", b"PLTE", b"IDAT", b"IEND"], kinds
    assert pixels == two_colour_pixels(), pixels


# MARK: - GIF89a

def decode_gif(name: str | Path) -> GIFDecoding:
    """A GIF named in the encoders' fixtures, or at a path, decoded."""
    return images.decode_gif((name if isinstance(name, Path) else FIXTURES / name).read_bytes())


def gif_two_frames_decode() -> None:
    decoding = decode_gif("two-frames.gif")
    assert decoding.screens == two_frame_screens(), decoding.screens
    assert decoding.delays == [50, 125], decoding.delays
    assert decoding.disposals == [1, 1], decoding.disposals
    assert decoding.loop_count == 0, decoding.loop_count
    assert decoding.local_tables == [False, True], decoding.local_tables


def gif_noise_decodes_across_table_resets() -> None:
    decoding = decode_gif("noise.gif")
    palette = noise_palette()
    noise = SampleRandom(NOISE_SEED).take(96 * 64)
    expected = [[palette[noise[y * 96 + x]] for x in range(96)] for y in range(64)]
    assert decoding.screens == [expected], "pixels differ"
    assert decoding.loop_count is None, decoding.loop_count
    # The encoder clears at 4096 entries; this decoder is one behind it.
    assert decoding.table_sizes_at_clear and set(decoding.table_sizes_at_clear) == {4095}, \
        decoding.table_sizes_at_clear


# MARK: - Recorded screens (Tests/TerminalUIRecordingTests/Fixtures)

# Catppuccin Mocha's colours, as RecordingPalette.catppuccinMocha holds them.
MOCHA_RED, MOCHA_BASE = (0xF3, 0x8B, 0xA8), (0x1E, 0x1E, 0x2E)
CELL_WIDTH, CELL_HEIGHT, PADDING, BASELINE, UNDERLINE_GAP = 9, 18, 12, 14, 2
# A GIF shades an anti-aliased edge in 16 steps, so a pixel is at most half
# a step — 255 / 30 of the way between its two colours — from the exact
# one, plus the rounding of each.
SHADING_STEP = 255 // 30 + 1


def recorded_screen_png_decodes() -> None:
    """styles.png, the `styles` log's screen: 16 × 2 cells and the padding,
    the window background the app set, and the red underline two pixels
    under the baseline of `under` (columns 8 to 12)."""
    _, pixels, _ = decode_png(RECORDING_FIXTURES / "styles.png")
    assert (len(pixels[0]), len(pixels)) == (16 * CELL_WIDTH + 2 * PADDING, 2 * CELL_HEIGHT + 2 * PADDING), \
        (len(pixels[0]), len(pixels))
    assert pixels[0][0][:3] == (0x10, 0x10, 0x20), pixels[0][0]
    underline = pixels[PADDING + BASELINE + UNDERLINE_GAP]
    columns = range(PADDING + 8 * CELL_WIDTH, PADDING + 13 * CELL_WIDTH)
    assert all(underline[x][:3] == MOCHA_RED for x in columns), [underline[x] for x in columns]
    _, doubled, _ = decode_png(RECORDING_FIXTURES / "styles@2x.png")
    assert (len(doubled[0]), len(doubled)) == (2 * len(pixels[0]), 2 * len(pixels))


def recorded_animation_decodes_to_its_stills() -> None:
    """typing.gif, the `typing` log's three frames: their held times in
    centiseconds, the last held 1.5 s longer for the loop, each after the
    first only the rectangle that changed, and the last screen the PNG
    still of the same frame, but for edge pixels shaded to the nearest of
    16 steps."""
    decoding = decode_gif(RECORDING_FIXTURES / "typing.gif")
    assert decoding.delays == [50, 40, 80 + 150], decoding.delays
    assert decoding.disposals == [1, 1, 1], decoding.disposals
    assert decoding.loop_count == 0, decoding.loop_count
    assert decoding.local_tables == [False, False, False], decoding.local_tables
    width, height = 20 * CELL_WIDTH + 2 * PADDING, 3 * CELL_HEIGHT + 2 * PADDING
    assert decoding.rectangles[0] == (0, 0, width, height), decoding.rectangles
    for left, top, frame_width, frame_height in decoding.rectangles[1:]:
        assert frame_width * frame_height < width * height // 2, decoding.rectangles
    _, still, _ = decode_png(RECORDING_FIXTURES / "typing-ready.png")
    last = decoding.screens[-1]
    worst = max(abs(a - b) for y in range(height) for x in range(width)
                for a, b in zip(last[y][x], still[y][x][:3]))
    exact = sum(last[y][x] == still[y][x][:3] for y in range(height) for x in range(width))
    assert worst <= SHADING_STEP, f"a pixel is {worst} from the still's"
    assert exact >= width * height * 9 // 10, f"only {exact} of {width * height} pixels are the still's"
    assert last[0][0] == MOCHA_BASE, last[0][0]


CASES: list[tuple[str, Callable[[], None]]] = [
    ("zlib fixtures decode with zlib, in the block type chosen", zlib_fixtures_decode),
    ("text compresses about as well as zlib's default level", text_compresses_about_as_well_as_zlib),
    ("an RGB PNG decodes to its pixels", png_rgb_decodes),
    ("an RGBA PNG decodes to its pixels", png_rgba_decodes),
    ("an indexed PNG decodes to its pixels through PLTE and tRNS", png_indexed_decodes),
    ("a one-bit PNG decodes to its pixels", png_one_bit_decodes),
    ("a two-frame GIF decodes to both screens, delays and loop", gif_two_frames_decode),
    ("a noise GIF decodes across LZW table resets", gif_noise_decodes_across_table_resets),
    ("a recorded screen's PNG still decodes to its size, ground and underline", recorded_screen_png_decodes),
    ("a recording's GIF decodes to its delays, rectangles and last still", recorded_animation_decodes_to_its_stills),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
