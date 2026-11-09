extension GlyphBitmap {
    /// The glyph shrunk to `numerator / denominator` of its size about the
    /// pen, for a glyph wider than the cells it must fit: each new pixel
    /// the area-weighted mean of the old pixels it covers (a box filter),
    /// in integers. In units where an old pixel is `numerator` long and a
    /// new one `denominator`, old pixel *i* spans `[i·n, (i+1)·n)` and new
    /// pixel *j* `[j·d, (j+1)·d)`, so every overlap is a whole number.
    package func scaled(by numerator: Int, over denominator: Int) -> GlyphBitmap {
        precondition(numerator > 0 && numerator <= denominator, "a glyph scaled by \(numerator)/\(denominator)")
        guard numerator < denominator else { return self }
        let horizontal = Self.axis(start: left, length: width, numerator: numerator, denominator: denominator)
        let vertical = Self.axis(start: top, length: height, numerator: numerator, denominator: denominator)
        let channels: Int
        let source: [UInt8]
        switch pixels {
        case .coverage(let coverage): (channels, source) = (1, coverage)
        case .premultipliedRGBA(let colours): (channels, source) = (PixelCanvas.bytesPerPixel, colours)
        }
        let area = denominator * denominator
        var result = [UInt8](repeating: 0, count: horizontal.count * vertical.count * channels)
        for (row, rowWeights) in vertical.weights.enumerated() {
            for (column, columnWeights) in horizontal.weights.enumerated() {
                for channel in 0..<channels {
                    var sum = 0
                    for (sourceRow, rowWeight) in rowWeights {
                        for (sourceColumn, columnWeight) in columnWeights {
                            sum += Int(source[(sourceRow * width + sourceColumn) * channels + channel])
                                * rowWeight * columnWeight
                        }
                    }
                    result[(row * horizontal.count + column) * channels + channel] = UInt8((sum + area / 2) / area)
                }
            }
        }
        let scaledPixels: GlyphPixels = channels == 1 ? .coverage(result) : .premultipliedRGBA(result)
        return GlyphBitmap(width: horizontal.count, height: vertical.count, left: horizontal.start,
                           top: vertical.start, advance: IntegerMath.roundedDivide(advance * numerator, denominator),
                           pixels: scaledPixels)
    }

    /// One axis of the scaling: where the new pixels start, how many there
    /// are, and for each the old pixels it overlaps and by how much.
    private static func axis(start: Int, length: Int, numerator: Int, denominator: Int)
        -> (start: Int, count: Int, weights: [[(Int, Int)]]) {
        guard length > 0 else { return (start, 0, []) }
        let first = IntegerMath.floorDivide(start * numerator, denominator)
        let end = IntegerMath.ceilDivide((start + length) * numerator, denominator)
        let weights = (first..<end).map { target in
            let (low, high) = (target * denominator, (target + 1) * denominator)
            return (0..<length).compactMap { index -> (Int, Int)? in
                let overlap = min(high, (start + index + 1) * numerator) - max(low, (start + index) * numerator)
                return overlap > 0 ? (index, overlap) : nil
            }
        }
        return (first, end - first, weights)
    }
}
