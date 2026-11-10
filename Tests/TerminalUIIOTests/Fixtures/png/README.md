# PNG decoder fixtures

Written by `tools/scripts/make_png_fixtures.py`:

```bash
python3 tools/scripts/make_png_fixtures.py Tests/TerminalUIIOTests/Fixtures/png
```

One 13 × 11 image per colour type and bit depth the PNG specification allows
(§11.2.1 Table 11.1), each also Adam7-interlaced, and the types without alpha
also with `tRNS`. Rows cycle through the five filters, the zlib level cycles
through 0 (stored), 1 and 9, the image data is split over two `IDAT` chunks,
and a `tEXt` chunk stands for the ancillary chunks a decoder skips.

Each `NAME.rgba` is the 8-bit RGBA the decoder must produce, computed by the
script from the same pixel model, never by decoding. ImageMagick agrees:
`magick NAME.png -depth 8 rgba:-` gives the same bytes for all 41.
