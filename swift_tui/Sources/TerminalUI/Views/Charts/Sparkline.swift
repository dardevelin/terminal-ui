/// A sparkline chart using braille characters for 2x4 sub-cell resolution.
/// Renders a series of data points as a smooth line.
///
/// Usage:
/// ```
/// Sparkline(data: cpuHistory, width: 40, height: 5)
/// Sparkline(data: values, width: 60, height: 8, min: 0, max: 100)
/// ```
public struct Sparkline: TerminalView {
    public let data: [Double]
    public let chartWidth: Int
    public let chartHeight: Int
    public let minValue: Double?
    public let maxValue: Double?
    public let filled: Bool

    public init(
        data: [Double],
        width: Int = 40,
        height: Int = 5,
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

    public var body: some TerminalView {
        Text(renderSparkline())
    }

    func renderSparkline() -> String {
        guard !data.isEmpty else {
            return String(repeating: "⠀", count: chartWidth)
        }

        var canvas = BrailleCanvas(width: chartWidth, height: chartHeight)
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
