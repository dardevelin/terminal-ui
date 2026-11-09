"""PNG and GIF read from their specifications, in Python alone: the
oracle the raster encoders' goldens are decoded by
(``tools/tests/test_raster_encoders.py``), and how the smoke suite looks at
the pictures ``swtui record render`` draws. It shares no code with the
Swift encoders, so a picture both agree on is one the formats describe.
"""

from __future__ import annotations

import zlib

Pixel = tuple[int, int, int, int]


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


def decode_png(png: bytes, name: str = "the PNG") -> tuple[list[bytes], list[list[Pixel]], list[int]]:
    """The chunk names, the pixels, and each row's filter type."""
    chunks = png_chunks(png)
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


# MARK: - GIF89a

class GIFDecoding:
    def __init__(self) -> None:
        self.screens: list[list[list[tuple[int, int, int]]]] = []
        self.delays: list[int] = []
        self.disposals: list[int] = []
        self.loop_count: int | None = None
        self.local_tables: list[bool] = []
        self.rectangles: list[tuple[int, int, int, int]] = []
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


def decode_gif(gif: bytes) -> GIFDecoding:
    """Every frame drawn onto the logical screen in turn, with what each
    frame's blocks said."""
    decoding = GIFDecoding()
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
        decoding.rectangles.append((left, top, frame_width, frame_height))
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
