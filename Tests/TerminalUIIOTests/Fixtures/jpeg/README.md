# JPEG decoder fixtures

Made by `tools/scripts/make_jpeg_fixtures.py` (macOS: it needs `sips`, and
libjpeg-turbo's `cjpeg` and `djpeg` — made with libjpeg-turbo 3.2.1). Each
picture is synthetic — gradients across and down, a hard-edged red block,
a one-pixel black-and-white checker row — so partial MCUs, sharp chroma
edges and smooth ramps all show.

| File | Size | Made with `cjpeg` … | What it exercises (ITU-T T.81) |
|------|------|---------------------|--------------------------------|
| `odd-444.jpg` | 37×29 | `-baseline -quality 90 -sample 1x1` | SOF0, no subsampling, partial blocks |
| `odd-422.jpg` | 37×29 | `-baseline -quality 90 -sample 2x1` | 4:2:2, partial MCUs |
| `odd-420.jpg` | 37×29 | `-baseline -quality 90 -sample 2x2` | 4:2:0, partial MCUs |
| `odd-440.jpg` | 37×29 | `-baseline -quality 90 -sample 1x2` | 4:4:0 |
| `odd-grey.jpg` | 37×29 | `-baseline -quality 90 -grayscale` | one component |
| `restart-420.jpg` | 64×48 | `-baseline -quality 85 -sample 2x2 -restart 3B` | DRI, RSTn every 3 MCUs, mid-row |
| `restart-rows-444.jpg` | 64×48 | `-baseline -quality 85 -sample 1x1 -restart 1` | RSTn every MCU row |
| `optimised-420.jpg` | 64×48 | `-baseline -quality 75 -optimize -sample 2x2` | image-specific Huffman tables |
| `coarse-16bit-tables.jpg` | 64×48 | `-quality 3 -sample 2x2` | SOF1, 16-bit DQT entries |
| `separate-scans-420.jpg` | 37×29 | `-baseline -quality 90 -sample 2x2 -scans` (one scan a component) | non-interleaved scans (A.2.2) |
| `progressive.jpg` | 64×48 | `-progressive -quality 80` | SOF2, refused |
| `tile-256-420.jpg` | 256×256 | `-baseline -quality 80 -sample 2x2` | a 256-pixel square, timed rather than compared |

Beside each but the last two:

- `<name>.rgba` — macOS ImageIO's decode, through `sips -s format bmp`, as
  raw RGBA, 4 bytes a pixel, rows top down;
- `<name>.djpeg.rgba` — libjpeg-turbo's decode, `djpeg -pnm` with its
  defaults (islow IDCT, "fancy" upsampling), likewise.

Two references because decoders legitimately differ: the IDCT's arithmetic
and chroma upsampling are left to the implementation. ImageIO and libjpeg
disagree by up to 74 levels near the sharp chroma edges of the 4:2:0
fixtures while agreeing to about 2 on average; `JPEGDecoderTests` holds
the decoder to libjpeg's within 3 levels everywhere and to ImageIO's on
average.

Regenerating rewrites every file; cjpeg's output is deterministic, so an
unchanged libjpeg-turbo writes the same bytes.
