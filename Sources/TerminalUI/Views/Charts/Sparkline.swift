/// A compact line chart of a numeric series, drawn in braille dots.
///
/// Plots the series onto a ``BrailleCanvas`` — every terminal cell is a
/// 2×4 grid of braille dots (U+2800 block), so a 40×5-cell sparkline
/// resolves 80×20 points — and connects consecutive samples with line
/// segments. `filled: true` shades the area under the line. One color for
/// the whole chart, set via `.foreground(_:)`.
///
/// This is the shape for *history*: CPU over the last minute, latency per
/// tick. To compare labeled categories, use ``BarChart``; for a 2D grid,
/// ``HeatMap``. By default the value range auto-scales to the data's
/// min/max each frame — pin `min:`/`max:` for a stable axis on live data,
/// otherwise the chart visibly re-normalizes as samples arrive.
///
/// ```swift
/// // A rolling CPU gauge, as the ComponentsDemo wires it:
/// Sparkline(
///     data: state.cpuHistory,
///     width: 60, height: 5,
///     min: 0, max: 100
/// )
/// .foreground(.green)
/// ```
public struct Sparkline: TerminalView {
    /// Samples, plotted left to right and spread across the full width.
    public let data: [Double]
    /// Explicit cell width. `nil` (default) fits to container width.
    public let chartWidth: Int?
    /// Explicit cell height. `nil` (default) fits to container height.
    public let chartHeight: Int?
    /// Bottom of the value range; `nil` auto-scales to the data minimum.
    public let minValue: Double?
    /// Top of the value range; `nil` auto-scales to the data maximum.
    public let maxValue: Double?
    /// Shade the area under the line.
    public let filled: Bool

    /// Creates a sparkline.
    ///
    /// - Parameters:
    ///   - data: Samples, left to right.
    ///   - width: Cell width; `nil` fits to container.
    ///   - height: Cell height; `nil` fits to container.
    ///   - min: Fixed range bottom; `nil` auto-scales per frame.
    ///   - max: Fixed range top; `nil` auto-scales per frame.
    ///   - filled: Shade under the line (default `false`).
    public init(
        data: [Double],
        width: Int? = nil,
        height: Int? = nil,
        min: Double? = nil,
        max: Double? = nil,
        filled: Bool = false
    ) {
        self.data = data
        self.chartWidth = width
        self.chartHeight = height
        self.minValue = min
        self.maxValue = max
        self.filled = filled
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        GeometryReader { size in
            Text(self.renderSparkline(containerWidth: size.width, containerHeight: size.height))
        }
    }

    func renderSparkline(containerWidth: Int = 40, containerHeight: Int = 5) -> String {
        let w = max(1, chartWidth ?? containerWidth)
        let h = max(1, chartHeight ?? containerHeight)
        guard !data.isEmpty else {
            return String(repeating: "⠀", count: w)
        }

        var canvas = BrailleCanvas(width: w, height: h)
        let dotW = canvas.dotWidth
        let dotH = canvas.dotHeight

        let lo = minValue ?? (data.min() ?? 0)
        let hi = maxValue ?? (data.max() ?? 1)
        let range = hi - lo > 0 ? hi - lo : 1.0

        // Map data points to dot coordinates
        let pointCount = data.count
        var points: [(Int, Int)] = []

        for (i, value) in data.enumerated() {
            let x = pointCount > 1
                ? Int(Double(i) / Double(pointCount - 1) * Double(dotW - 1))
                : dotW / 2
            let normalized = (value - lo) / range
            let y = dotH - 1 - Int(normalized * Double(dotH - 1))
            points.append((x, y))
        }

        // Draw lines between consecutive points
        for i in 1..<points.count {
            canvas.line(x0: points[i-1].0, y0: points[i-1].1,
                        x1: points[i].0, y1: points[i].1)
        }

        // Fill below the line if requested
        if filled {
            for (px, py) in points {
                for y in py..<dotH {
                    canvas.set(x: px, y: y)
                }
            }
        }

        return canvas.render()
    }
}
