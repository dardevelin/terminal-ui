import TerminalUIIO

/// Heights over one tile's square: a grid of samples, row by row from the
/// north-west, each the ground's height in metres above sea level at the
/// middle of its pixel.
public struct ElevationTile: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// `width × height` heights, in metres.
    public let metres: [Float]

    /// A grid of heights; nil unless there are `width × height` of them
    /// and both are positive.
    public init?(width: Int, height: Int, metres: [Float]) {
        guard width > 0, height > 0, metres.count == width * height else { return nil }
        self.init(checkedWidth: width, height: height, metres: metres)
    }

    /// A grid whose caller has made `metres` hold `width × height`, both
    /// positive.
    init(checkedWidth width: Int, height: Int, metres: [Float]) {
        self.width = width
        self.height = height
        self.metres = metres
    }

    /// The height at a sample, the nearest edge sample for one outside.
    public func elevation(x: Int, y: Int) -> Float {
        metres[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }

    /// The height at a point of the unit square, (0, 0) the north-west
    /// corner, interpolated between the four samples around it.
    public func elevation(atUnitX unitX: Double, y unitY: Double) -> Double {
        let sampleX = unitX * Double(width) - Self.pixelMiddle, sampleY = unitY * Double(height) - Self.pixelMiddle
        let left = Int(sampleX.rounded(.down)), top = Int(sampleY.rounded(.down))
        let across = sampleX - Double(left), down = sampleY - Double(top)
        let upper = Double(elevation(x: left, y: top)) * (1 - across) + Double(elevation(x: left + 1, y: top)) * across
        let lower = Double(elevation(x: left, y: top + 1)) * (1 - across)
            + Double(elevation(x: left + 1, y: top + 1)) * across
        return upper * (1 - down) + lower * down
    }

    /// The samples of the square of the unit tile from `unitX`, `unitY`,
    /// `unitSide` across — a descendant tile's share — at `samples` a side.
    public func cropped(unitX: Double, y unitY: Double, side unitSide: Double, samples: Int) -> ElevationTile {
        let count = max(1, samples)
        var cropped = [Float](repeating: 0, count: count * count)
        for row in 0..<count {
            for column in 0..<count {
                let x = unitX + (Double(column) + Self.pixelMiddle) / Double(count) * unitSide
                let y = unitY + (Double(row) + Self.pixelMiddle) / Double(count) * unitSide
                cropped[row * count + column] = Float(elevation(atUnitX: x, y: y))
            }
        }
        return ElevationTile(checkedWidth: count, height: count, metres: cropped)
    }

    private static let pixelMiddle = 0.5
}

/// Mapzen's Terrarium encoding, the one AWS Terrain Tiles serve
/// (github.com/tilezen/joerd, docs/formats.md): a height in metres is
/// `red × 256 + green + blue / 256 − 32768`, so the red and green bytes hold
/// whole metres offset by 32 768 and blue the fraction in 1/256 m.
public enum Terrarium {
    /// The offset that lets the encoding hold depths below sea level.
    static let offset = 32_768.0
    /// One step of red is 256 m; one of blue 1/256 m.
    static let redScale = 256.0
    static let blueScale = 256.0

    /// The height a pixel encodes.
    public static func metres(red: UInt8, green: UInt8, blue: UInt8) -> Double {
        Double(red) * redScale + Double(green) + Double(blue) / blueScale - offset
    }

    /// The pixel that encodes a height, rounded to the nearest 1/256 m and
    /// held to what the three bytes can hold.
    public static func pixel(metres: Double) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let largest = redScale * redScale - 1 / blueScale
        let shifted = min(max(metres + offset, 0), largest)
        let steps = Int((shifted * blueScale).rounded())
        let whole = steps / Int(blueScale)
        return (UInt8(whole / Int(redScale)), UInt8(whole % Int(redScale)), UInt8(steps % Int(blueScale)))
    }

    /// The heights a Terrarium picture encodes. Alpha is ignored: AWS's
    /// tiles are opaque RGB.
    public static func elevation(of image: ImageBuffer) -> ElevationTile {
        var metres = [Float](repeating: 0, count: image.width * image.height)
        image.rgba.withUnsafeBufferPointer { pixels in
            for index in 0..<metres.count {
                let base = index * rgbaChannels
                metres[index] = Float(self.metres(red: pixels[base], green: pixels[base + 1], blue: pixels[base + 2]))
            }
        }
        // `ImageBuffer` guarantees positive dimensions and a matching count.
        return ElevationTile(checkedWidth: image.width, height: image.height, metres: metres)
    }

    /// `ImageBuffer`'s layout: red, green, blue, alpha.
    private static let rgbaChannels = 4

    /// A Terrarium picture of a grid of heights.
    public static func image(of tile: ElevationTile) -> ImageBuffer? {
        var rgba = [UInt8](repeating: UInt8.max, count: tile.metres.count * rgbaChannels)
        for (index, height) in tile.metres.enumerated() {
            let pixel = pixel(metres: Double(height))
            rgba[index * rgbaChannels] = pixel.red
            rgba[index * rgbaChannels + 1] = pixel.green
            rgba[index * rgbaChannels + 2] = pixel.blue
        }
        return try? ImageBuffer(rgba: rgba, width: tile.width, height: tile.height)
    }
}
