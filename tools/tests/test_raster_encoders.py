#!/usr/bin/env python3
"""The raster encoders' goldens decode, by means that share none of their code.

``Tests/TerminalUIRasterTests`` holds every zlib stream, PNG and GIF the
Swift encoders are checked against byte for byte. Byte equality only says
the encoder still writes what it wrote once; this says what it wrote is
right. Each case rebuilds the picture or bytes a fixture was made from —
the same formulas as ``Samples.swift``, restated here — and decodes the
fixture with Python's zlib (RFC 1950/1951), a PNG reader and a GIF89a
decoder written below from the specifications, then compares.

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

from terminalui.cases import run_cases  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[2] / "Tests" / "TerminalUIRasterTests" / "Fixtures"

Pixel = tuple[int, int, int, int]


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

def png_chunks(png: bytes) -> list[tuple[bytes, bytes]]:
    assert png[:8] == b"\x89PNG\r\n\x1a\n", "signature"
    chunks, offset = [], 8
    while offset < len(png):
        length = int.from_bytes(png[offset:offset + 4], "big")
        kind, data = png[offset + 4:offset + 8], png[offset + 8:offset + 8 + length]
        crc = int.from_bytes(png[offset + 8 + length:offset + 12 + length], "big")
        assert crc == zlib.crc32(kind + data), f"{kind!r}: CRC"
        chunks.append((kind, data))
        offset += 12 + length
    assert offset == len(png), "trailing bytes"
    return chunks


def paeth(left: int, above: int, above_left: int) -> int:
    estimate = left + above - above_left
    to_left, to_above, to_above_left = abs(estimate - left), abs(estimate - above), abs(estimate - above_left)
    if to_left <= to_above and to_left <= to_above_left:
        return left
    return above if to_above <= to_above_left else above_left


def unfilter(raw: bytes, row_length: int, bytes_per_pixel: int, height: int) -> list[bytes]:
    """§9.2's five filters, undone."""
    rows, previous = [], bytes(row_length)
    assert len(raw) == height * (1 + row_length), f"{len(raw)} bytes of scanlines"
    for y in range(height):
        start = y * (1 + row_length)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + row_length])
        for i in range(row_length):
            left = line[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
            above = previous[i]
            above_left = previous[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
            prediction = [0, left, above, (left + above) // 2, paeth(left, above, above_left)][kind]
            line[i] = (line[i] + prediction) % 256
        rows.append(bytes(line))
        previous = bytes(line)
    return rows


def decode_png(name: str) -> tuple[list[bytes], list[list[Pixel]], list[int]]:
    """The chunk names, the pixels, and each row's filter type."""
    chunks = png_chunks((FIXTURES / name).read_bytes())
    kinds = [kind for kind, _ in chunks]
    header = chunks[0][1]
    width, height = int.from_bytes(header[0:4], "big"), int.from_bytes(header[4:8], "big")
    depth, colour_type = header[8], header[9]
    assert header[10:] == b"\0\0\0", f"{name}: compression, filter, interlace {header[10:].hex()}"
    assert dict(chunks)[b"sRGB"] == b"\0", f"{name}: rendering intent"
    raw = zlib.decompress(b"".join(data for kind, data in chunks if kind == b"IDAT"))
    channels = {2: 3, 6: 4, 3: 1}[colour_type]
    row_length = (width * channels * depth + 7) // 8
    rows = unfilter(raw, row_length, max(1, channels * depth // 8), height)
    filters = [raw[y * (1 + row_length)] for y in range(height)]
    if colour_type == 3:
        plte = dict(chunks)[b"PLTE"]
        trns = dict(chunks).get(b"tRNS", b"")
        palette = [(plte[i], plte[i + 1], plte[i + 2], trns[i // 3] if i // 3 < len(trns) else 255)
                   for i in range(0, len(plte), 3)]
        per_byte = 8 // depth
        pixels = [[palette[(row[x // per_byte] >> (8 - depth * (x % per_byte + 1))) & ((1 << depth) - 1)]
                   for x in range(width)] for row in rows]
    else:
        pixels = [[tuple(row[x * channels:(x + 1) * channels]) + ((255,) if channels == 3 else ())
                   for x in range(width)] for row in rows]
    return kinds, pixels, filters


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

class GIFDecoding:
    def __init__(self) -> None:
        self.screens: list[list[list[tuple[int, int, int]]]] = []
        self.delays: list[int] = []
        self.disposals: list[int] = []
        self.loop_count: int | None = None
        self.local_tables: list[bool] = []
        self.table_sizes_at_clear: list[int] = []


def lzw_decode(data: bytes, minimum: int, decoding: GIFDecoding) -> list[int]:
    """Appendix F, from the decoder's side."""
    clear, end = 1 << minimum, (1 << minimum) + 1
    initial = [[i] for i in range(clear)] + [[], []]
    table, width, previous, position, out, cleared = list(initial), minimum + 1, None, 0, [], False
    while True:
        assert position + width <= len(data) * 8, "codes run out before end-of-information"
        code = sum(((data[(position + bit) // 8] >> ((position + bit) % 8)) & 1) << bit for bit in range(width))
        position += width
        if code == clear:
            if cleared:
                decoding.table_sizes_at_clear.append(len(table))
            table, width, previous, cleared = list(initial), minimum + 1, None, True
            continue
        if code == end:
            return out
        if code < len(table):
            entry = table[code]
        else:
            assert code == len(table) and previous is not None, f"code {code} with {len(table)} entries"
            entry = previous + previous[:1]
        out += entry
        if previous is not None and len(table) < 4096:
            table.append(previous + entry[:1])
        previous = entry
        if len(table) == 1 << width and width < 12:
            width += 1


def decode_gif(name: str) -> GIFDecoding:
    gif, decoding = (FIXTURES / name).read_bytes(), GIFDecoding()
    assert gif[:6] == b"GIF89a", gif[:6]
    width, height, packed = int.from_bytes(gif[6:8], "little"), int.from_bytes(gif[8:10], "little"), gif[10]
    offset, global_table = 13, []
    if packed & 0x80:
        size = 2 << (packed & 7)
        global_table = [tuple(gif[offset + 3 * i:offset + 3 * i + 3]) for i in range(size)]
        offset += 3 * size
    screen = [[(0, 0, 0)] * width for _ in range(height)]
    transparent = None
    while True:
        introducer = gif[offset]
        if introducer == 0x3B:
            assert offset == len(gif) - 1, "bytes after the trailer"
            return decoding
        if introducer == 0x21:
            label, offset = gif[offset + 1], offset + 2
            blocks = []
            while gif[offset]:
                blocks.append(gif[offset + 1:offset + 1 + gif[offset]])
                offset += 1 + gif[offset]
            offset += 1
            if label == 0xF9:
                control = blocks[0]
                decoding.disposals.append((control[0] >> 2) & 7)
                decoding.delays.append(int.from_bytes(control[1:3], "little"))
                transparent = control[3] if control[0] & 1 else None
            elif label == 0xFF and blocks[0] == b"NETSCAPE2.0":
                assert blocks[1][0] == 1, "loop sub-block"
                decoding.loop_count = int.from_bytes(blocks[1][1:3], "little")
            continue
        assert introducer == 0x2C, f"block {introducer:#x} at {offset}"
        left, top, frame_width, frame_height = (int.from_bytes(gif[offset + 1 + 2 * i:offset + 3 + 2 * i], "little")
                                                for i in range(4))
        packed, offset = gif[offset + 9], offset + 10
        table = global_table
        decoding.local_tables.append(bool(packed & 0x80))
        if packed & 0x80:
            size = 2 << (packed & 7)
            table = [tuple(gif[offset + 3 * i:offset + 3 * i + 3]) for i in range(size)]
            offset += 3 * size
        minimum, offset = gif[offset], offset + 1
        data = bytearray()
        while gif[offset]:
            assert gif[offset] <= 255
            data += gif[offset + 1:offset + 1 + gif[offset]]
            offset += 1 + gif[offset]
        offset += 1
        indices = lzw_decode(bytes(data), minimum, decoding)
        assert len(indices) == frame_width * frame_height, f"{len(indices)} pixels"
        for i, index in enumerate(indices):
            if index != transparent:
                screen[top + i // frame_width][left + i % frame_width] = table[index]
        decoding.screens.append([row[:] for row in screen])
        transparent = None


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


CASES: list[tuple[str, Callable[[], None]]] = [
    ("zlib fixtures decode with zlib, in the block type chosen", zlib_fixtures_decode),
    ("text compresses about as well as zlib's default level", text_compresses_about_as_well_as_zlib),
    ("an RGB PNG decodes to its pixels", png_rgb_decodes),
    ("an RGBA PNG decodes to its pixels", png_rgba_decodes),
    ("an indexed PNG decodes to its pixels through PLTE and tRNS", png_indexed_decodes),
    ("a one-bit PNG decodes to its pixels", png_one_bit_decodes),
    ("a two-frame GIF decodes to both screens, delays and loop", gif_two_frames_decode),
    ("a noise GIF decodes across LZW table resets", gif_noise_decodes_across_table_resets),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
