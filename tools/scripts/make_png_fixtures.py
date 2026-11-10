#!/usr/bin/env python3
"""Write the PNG decoder's fixtures: one image per colour type and bit depth
the PNG specification allows, interlaced and not, with and without tRNS,
each row filtered by the next of the five filters, compressed at three zlib
levels — and beside each the RGBA the decoder must produce, computed from
the same pixel model and never from a decode.

    python3 tools/scripts/make_png_fixtures.py Tests/TerminalUIIOTests/Fixtures/png

Re-running it rewrites the same bytes: the pixels, the filters and zlib's
output at a level are all fixed.
"""
import struct
import sys
import zlib
from pathlib import Path

WIDTH, HEIGHT = 13, 11

# PNG §11.2.1 Table 11.1.
GREY, TRUECOLOUR, INDEXED, GREY_ALPHA, TRUECOLOUR_ALPHA = 0, 2, 3, 4, 6
CHANNELS = {GREY: 1, TRUECOLOUR: 3, INDEXED: 1, GREY_ALPHA: 2, TRUECOLOUR_ALPHA: 4}

# PNG §8.2 Table 8.1: (first column, first row, column step, row step).
ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def samples(colour_type: int, depth: int, x: int, y: int) -> list[int]:
    """The stored samples of pixel (x, y): gradients that reach both ends of
    the depth's range, different in every channel."""
    top = (1 << depth) - 1
    if colour_type == INDEXED:
        return [(x + y * WIDTH) % (1 << depth)]
    values = [(x * top) // (WIDTH - 1), (y * top) // (HEIGHT - 1), ((x + y) * top) // (WIDTH + HEIGHT - 2),
              top - (x * y * top) // ((WIDTH - 1) * (HEIGHT - 1))]
    if colour_type == GREY_ALPHA:
        return [values[0], values[3]]
    return values[:CHANNELS[colour_type]]


def palette(depth: int) -> list[tuple[int, int, int]]:
    return [((index * 37) % 256, (index * 91 + 7) % 256, (255 - index * 13) % 256) for index in range(1 << depth)]


def alphas(depth: int) -> list[int]:
    return [(index * 53) % 256 for index in range(min(1 << depth, 5))]


def grey_key(depth: int) -> int:
    return samples(GREY, depth, 0, 0)[0]


def colour_key(depth: int) -> list[int]:
    return samples(TRUECOLOUR, depth, WIDTH - 1, 0)


def scaled(value: int, depth: int) -> int:
    """PNG §13.12: round(value × 255 / (2^depth − 1))."""
    top = (1 << depth) - 1
    return (value * 255 + top // 2) // top


def expected_rgba(colour_type: int, depth: int, transparency: bool) -> bytes:
    out = bytearray()
    entries = palette(depth)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            values = samples(colour_type, depth, x, y)
            if colour_type == INDEXED:
                index = values[0]
                red, green, blue = entries[index]
                keyed = alphas(depth)
                out += bytes([red, green, blue, keyed[index] if transparency and index < len(keyed) else 255])
            elif colour_type == GREY:
                level = scaled(values[0], depth)
                out += bytes([level, level, level, 0 if transparency and values[0] == grey_key(depth) else 255])
            elif colour_type == GREY_ALPHA:
                level = scaled(values[0], depth)
                out += bytes([level, level, level, scaled(values[1], depth)])
            elif colour_type == TRUECOLOUR:
                alpha = 0 if transparency and values == colour_key(depth) else 255
                out += bytes([scaled(value, depth) for value in values] + [alpha])
            else:
                out += bytes(scaled(value, depth) for value in values)
    return bytes(out)


def pack_row(colour_type: int, depth: int, columns: list[int], y: int) -> bytes:
    values = [value for x in columns for value in samples(colour_type, depth, x, y)]
    if depth == 16:
        return b"".join(struct.pack(">H", value) for value in values)
    if depth == 8:
        return bytes(values)
    bits = "".join(format(value, f"0{depth}b") for value in values)
    bits += "0" * (-len(bits) % 8)
    return bytes(int(bits[index:index + 8], 2) for index in range(0, len(bits), 8))


def paeth(left: int, up: int, up_left: int) -> int:
    estimate = left + up - up_left
    to_left, to_up, to_up_left = abs(estimate - left), abs(estimate - up), abs(estimate - up_left)
    if to_left <= to_up and to_left <= to_up_left:
        return left
    return up if to_up <= to_up_left else up_left


def filtered(rows: list[bytes], stride: int, first_filter: int) -> bytes:
    """Each row filtered by the next of the five filters in turn (§9.2)."""
    out = bytearray()
    previous = bytes(len(rows[0]))
    for index, row in enumerate(rows):
        kind = (first_filter + index) % 5
        out.append(kind)
        for column, value in enumerate(row):
            left = row[column - stride] if column >= stride else 0
            up = previous[column]
            up_left = previous[column - stride] if column >= stride else 0
            prediction = [0, left, up, (left + up) // 2, paeth(left, up, up_left)][kind]
            out.append((value - prediction) % 256)
        previous = row
    return bytes(out)


def image_data(colour_type: int, depth: int, interlaced: bool) -> bytes:
    stride = max(1, depth * CHANNELS[colour_type] // 8)
    passes = ADAM7 if interlaced else [(0, 0, 1, 1)]
    out = bytearray()
    for number, (first_column, first_row, column_step, row_step) in enumerate(passes):
        columns = list(range(first_column, WIDTH, column_step))
        rows = list(range(first_row, HEIGHT, row_step))
        if columns and rows:
            out += filtered([pack_row(colour_type, depth, columns, y) for y in rows], stride, number)
    return bytes(out)


def png(colour_type: int, depth: int, interlaced: bool, transparency: bool, level: int) -> bytes:
    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, depth, colour_type, 0, 0, 1 if interlaced else 0)
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
    out += chunk(b"tEXt", b"Comment\x00an ancillary chunk the decoder skips")
    if colour_type == INDEXED:
        out += chunk(b"PLTE", bytes(channel for entry in palette(depth) for channel in entry))
    if transparency:
        if colour_type == INDEXED:
            out += chunk(b"tRNS", bytes(alphas(depth)))
        elif colour_type == GREY:
            out += chunk(b"tRNS", struct.pack(">H", grey_key(depth)))
        else:
            out += chunk(b"tRNS", struct.pack(">HHH", *colour_key(depth)))
    compressed = zlib.compress(image_data(colour_type, depth, interlaced), level)
    # Split across two IDAT chunks, which §5.6 allows and a reader must join.
    middle = len(compressed) // 2
    out += chunk(b"IDAT", compressed[:middle]) + chunk(b"IDAT", compressed[middle:])
    return out + chunk(b"IEND", b"")


def main() -> None:
    directory = Path(sys.argv[1])
    directory.mkdir(parents=True, exist_ok=True)
    cases = []
    for colour_type, depths in [(GREY, [1, 2, 4, 8, 16]), (TRUECOLOUR, [8, 16]), (INDEXED, [1, 2, 4, 8]),
                                (GREY_ALPHA, [8, 16]), (TRUECOLOUR_ALPHA, [8, 16])]:
        for depth in depths:
            cases.append((colour_type, depth, False, False))
            cases.append((colour_type, depth, True, False))
            if colour_type in (GREY, TRUECOLOUR, INDEXED):
                cases.append((colour_type, depth, False, True))
    for number, (colour_type, depth, interlaced, transparency) in enumerate(cases):
        level = [0, 1, 9][number % 3]
        name = f"type{colour_type}-depth{depth}{'-adam7' if interlaced else ''}{'-trns' if transparency else ''}"
        (directory / f"{name}.png").write_bytes(png(colour_type, depth, interlaced, transparency, level))
        (directory / f"{name}.rgba").write_bytes(expected_rgba(colour_type, depth, transparency))
    print(f"{len(cases)} fixtures in {directory}")


if __name__ == "__main__":
    main()
