# ``TerminalUIIO``

Images for TerminalUI: decode a file to pixels, and draw the pixels in cells.

## Overview

TerminalUIIO is opt-in, so an app without pictures never builds image code.
An image is an ``ImageBuffer`` of straight RGBA; a renderer such as
``HalfBlockRenderer`` draws one into a `CellBuffer`, two pixels to a cell.

## Decoding images

Two decoders ship, written in Swift with no system library beneath them, so
a file decodes to the same pixels on macOS and Linux:

- ``PNGDecoder`` reads every PNG the specification defines (ISO/IEC 15948,
  W3C third edition): each colour type and bit depth, palettes, `tRNS`
  transparency and Adam7 interlacing, with every CRC and the Adler-32
  checked. Sixteen-bit samples are scaled to eight.
- ``JPEGDecoder`` reads sequential JPEG (ITU-T T.81 baseline and extended,
  JFIF's YCbCr, greyscale and RGB): any sampling that divides the largest,
  restart intervals, and one scan for all components or one for each. It
  refuses progressive, lossless, hierarchical and arithmetic-coded JPEG,
  12-bit samples and CMYK, with a reason that says which.

Both conform to ``ImageDecoder``, so code that takes any decoder takes
these, and both throw ``ImageDecodeError`` rather than trap, whatever the
bytes: a file cut short, a flipped bit and a hostile header all end in an
error.

```swift
let data = try Data(contentsOf: url)
let decoder: any ImageDecoder = data.starts(with: [0xFF, 0xD8]) ? JPEGDecoder() : PNGDecoder()
let image = try decoder.decode(data)
```

A header states the image's size before any of its data, so it can claim
far more than the file holds. Each decoder refuses an image of more pixels
than its `maximumPixelCount` — by default 2^26, an 8192 × 8192 image —
before allocating for it; pass a smaller limit for input you do not trust:

```swift
let thumbnail = try PNGDecoder(maximumPixelCount: 1024 * 1024).decode(data)
```

PNG's image data is deflate, which ``Inflate`` decodes; it decodes any raw
deflate stream, and ``Inflate/decode(_:outputLimit:)`` stops one that would
expand past a bound.

## Topics

### Decoding

- ``ImageDecoder``
- ``PNGDecoder``
- ``JPEGDecoder``
- ``ImageDecodeError``

### Images

- ``ImageBuffer``
- ``ImageBufferError``

### Drawing

- ``ImageRenderer``
- ``HalfBlockRenderer``
- ``ImageRenderingPipeline``
- ``ImageRenderStrategy``

### Deflate

- ``Inflate``
- ``InflateError``
- ``BoundedInflateError``
