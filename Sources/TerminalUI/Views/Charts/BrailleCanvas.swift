#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A 2D braille dot-matrix canvas for sub-cell resolution drawing.
///
/// Each terminal cell maps to a 2x4 grid from the Unicode braille block
/// (U+2800), so a canvas of `width` x `height` cells addresses
/// `width*2` x `height*4` individually settable dots — the highest
/// plotting resolution a text terminal offers. Primitives cover dots,
/// Bresenham lines, quadratic/cubic beziers, circles, and filled rects,
/// all in *dot* coordinates with origin at the top-left; out-of-bounds
/// writes are silently clipped.
///
/// `BrailleCanvas` is not a view: it renders to a multi-line `String`
/// that you wrap in ``Text`` to place in the tree. ``Sparkline`` is this
/// canvas packaged as a view for the common data-series case — drop down
/// to the canvas for free-form drawing.
///
/// Dot layout per cell:
/// ```
/// ⠁ ⠈   (0,0) (1,0)
/// ⠂ ⠐   (0,1) (1,1)
/// ⠄ ⠠   (0,2) (1,2)
/// ⡀ ⢀   (0,3) (1,3)
/// ```
///
/// ```swift
/// // A sine wave, as the Storybook page draws it:
/// var canvas = BrailleCanvas(width: 40, height: 6)
/// for x in 0..<canvas.dotWidth {
///     let t = Double(x) / Double(canvas.dotWidth) * .pi * 4
///     let y = Int((sin(t) + 1) / 2 * Double(canvas.dotHeight - 1))
///     canvas.set(x: x, y: y)
/// }
/// Text(canvas.render()).foreground(.cyan)
/// ```
public struct BrailleCanvas {
    /// Width in terminal cells (dots = width * 2)
    public let width: Int
    /// Height in terminal cells (dots = height * 4)
    public let height: Int
    /// Dot grid — true = dot on
    var dots: [Bool]

    /// Width in dot units
    public var dotWidth: Int { width * 2 }
    /// Height in dot units
    public var dotHeight: Int { height * 4 }

    /// Creates a blank canvas of `width` x `height` terminal cells — a
    /// dot grid of `width * 2` x `height * 4`, all dots off.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.dots = Array(repeating: false, count: width * 2 * height * 4)
    }

    // MARK: - Dot Operations

    /// Set a single dot at (x, y) in dot coordinates.
    public mutating func set(x: Int, y: Int) {
        guard x >= 0, x < dotWidth, y >= 0, y < dotHeight else { return }
        dots[y * dotWidth + x] = true
    }

    /// Clear a single dot.
    public mutating func clear(x: Int, y: Int) {
        guard x >= 0, x < dotWidth, y >= 0, y < dotHeight else { return }
        dots[y * dotWidth + x] = false
    }

    /// Clear entire canvas.
    public mutating func clearAll() {
        for i in dots.indices { dots[i] = false }
    }

    // MARK: - Drawing Primitives

    /// Draw a straight segment between two dot coordinates
    /// (Bresenham's algorithm).
    public mutating func line(x0: Int, y0: Int, x1: Int, y1: Int) {
        var x = x0, y = y0
        let dx = abs(x1 - x0)
        let dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1
        let sy = y0 < y1 ? 1 : -1
        var err = dx + dy

        while true {
            set(x: x, y: y)
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy {
                err += dy
                x += sx
            }
            if e2 <= dx {
                err += dx
                y += sy
            }
        }
    }

    /// Draw a quadratic bezier curve (3 control points).
    public mutating func quadraticBezier(
        x0: Double, y0: Double,
        cx: Double, cy: Double,
        x1: Double, y1: Double,
        steps: Int = 50
    ) {
        var prevX = Int(x0), prevY = Int(y0)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let u = 1.0 - t
            let px = u * u * x0 + 2 * u * t * cx + t * t * x1
            let py = u * u * y0 + 2 * u * t * cy + t * t * y1
            let ix = Int(px.rounded())
            let iy = Int(py.rounded())
            line(x0: prevX, y0: prevY, x1: ix, y1: iy)
            prevX = ix
            prevY = iy
        }
    }

    /// Draw a cubic bezier curve (4 control points).
    public mutating func cubicBezier(
        x0: Double, y0: Double,
        cx0: Double, cy0: Double,
        cx1: Double, cy1: Double,
        x1: Double, y1: Double,
        steps: Int = 80
    ) {
        var prevX = Int(x0), prevY = Int(y0)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let u = 1.0 - t
            let px = u*u*u*x0 + 3*u*u*t*cx0 + 3*u*t*t*cx1 + t*t*t*x1
            let py = u*u*u*y0 + 3*u*u*t*cy0 + 3*u*t*t*cy1 + t*t*t*y1
            let ix = Int(px.rounded())
            let iy = Int(py.rounded())
            line(x0: prevX, y0: prevY, x1: ix, y1: iy)
            prevX = ix
            prevY = iy
        }
    }

    /// Draw a circle.
    public mutating func circle(cx: Int, cy: Int, radius: Int) {
        let steps = max(radius * 6, 36)
        for i in 0..<steps {
            let angle = 2.0 * Double.pi * Double(i) / Double(steps)
            let nextAngle = 2.0 * Double.pi * Double(i + 1) / Double(steps)
            let x0 = cx + Int((Double(radius) * cos(angle)).rounded())
            let y0 = cy + Int((Double(radius) * sin(angle)).rounded())
            let x1 = cx + Int((Double(radius) * cos(nextAngle)).rounded())
            let y1 = cy + Int((Double(radius) * sin(nextAngle)).rounded())
            line(x0: x0, y0: y0, x1: x1, y1: y1)
        }
    }

    /// Fill a rectangle.
    public mutating func fillRect(x: Int, y: Int, width: Int, height: Int) {
        for dy in 0..<height {
            for dx in 0..<width {
                set(x: x + dx, y: y + dy)
            }
        }
    }

    // MARK: - Rendering

    /// Render the canvas to a multi-line string of braille characters,
    /// one line per cell row. Wrap the result in ``Text`` to display it.
    public func render() -> String {
        var lines: [String] = []
        for cellY in 0..<height {
            var line = ""
            for cellX in 0..<width {
                line.append(brailleChar(cellX: cellX, cellY: cellY))
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Get the braille character for a specific cell.
    func brailleChar(cellX: Int, cellY: Int) -> Character {
        // Braille dots are numbered:
        // 1 4     (col 0, col 1)
        // 2 5     row offsets within cell
        // 3 6
        // 7 8
        let baseX = cellX * 2
        let baseY = cellY * 4

        var code: UInt32 = 0x2800  // braille blank

        if dot(baseX, baseY)     { code |= 0x01 }  // dot 1
        if dot(baseX, baseY + 1) { code |= 0x02 }  // dot 2
        if dot(baseX, baseY + 2) { code |= 0x04 }  // dot 3
        if dot(baseX + 1, baseY)     { code |= 0x08 }  // dot 4
        if dot(baseX + 1, baseY + 1) { code |= 0x10 }  // dot 5
        if dot(baseX + 1, baseY + 2) { code |= 0x20 }  // dot 6
        if dot(baseX, baseY + 3) { code |= 0x40 }  // dot 7
        if dot(baseX + 1, baseY + 3) { code |= 0x80 }  // dot 8

        return Character(Unicode.Scalar(code)!)
    }

    private func dot(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < dotWidth, y >= 0, y < dotHeight else { return false }
        return dots[y * dotWidth + x]
    }
}
