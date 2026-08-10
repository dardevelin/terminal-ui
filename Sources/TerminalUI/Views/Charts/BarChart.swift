/// Horizontal bar chart comparing labeled values, one row per bar.
///
/// Each row renders `label ███▋ value`: labels padded to a common column,
/// bars built from full blocks plus one eighth-block glyph
/// (`▏▎▍▌▋▊▉█`) for sub-cell precision — a 30-cell bar resolves 240
/// distinct lengths. Values are auto-formatted with `K`/`M` suffixes.
/// Bars scale against the largest value unless `maxValue` pins the scale
/// (pin it when charts must be comparable across frames or panes).
///
/// Reach for `BarChart` to compare categories at a point in time; for a
/// value's history over time in a compact strip, use ``Sparkline``; for a
/// 2D grid of intensities, ``HeatMap``.
///
/// ```swift
/// BarChart(
///     items: [
///         .init(label: "Go", value: 18000),
///         .init(label: "Rust", value: 12000),
///         .init(label: "Swift", value: 8000),
///     ],
///     barWidth: 30
/// )
/// .foreground(.green)
/// ```
public struct BarChart: TerminalView {
    /// Bars, rendered top to bottom in array order.
    public let items: [Item]
    /// Explicit bar width in cells. `nil` (default) fits the chart to its
    /// container: bar width = `container.width - labelWidth - valueWidth - 2`.
    /// Pass an explicit integer to pin the width (benchmarks, fixed layouts).
    public let barWidth: Int?
    /// Value the full bar width represents. `nil` (default) scales to the
    /// largest item, so the longest bar always spans the full width.
    public let maxValue: Double?
    /// Whether to append the formatted value after each bar.
    public let showValues: Bool

    /// One bar: a label, a value, and an optional per-bar color.
    public struct Item {
        /// Row label, padded to the widest label in the chart.
        public let label: String
        /// Bar magnitude; expected non-negative.
        public let value: Double
        /// Optional per-bar color, carried with the item. The precomputed
        /// text rendering styles the chart uniformly — set the overall
        /// color with `.foreground(_:)` on the chart.
        public let color: Color?

        /// Creates one bar; `color` defaults to `nil` (chart-wide styling
        /// applies).
        public init(label: String, value: Double, color: Color? = nil) {
            self.label = label
            self.value = value
            self.color = color
        }
    }

    // 1/8th block chars for sub-cell horizontal resolution
    static let blockChars: [Character] = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"]

    /// Creates a bar chart.
    ///
    /// - Parameters:
    ///   - items: Bars, top to bottom.
    ///   - barWidth: Bar column width in cells; `nil` fits to container.
    ///   - maxValue: Full-scale value; `nil` scales to the largest item.
    ///   - showValues: Append formatted values after bars (default `true`).
    public init(
        items: [Item],
        barWidth: Int? = nil,
        maxValue: Double? = nil,
        showValues: Bool = true
    ) {
        self.items = items
        self.barWidth = barWidth
        self.maxValue = maxValue
        self.showValues = showValues
    }

    public var body: some TerminalView {
        GeometryReader { size in
            Text(self.renderChart(containerWidth: size.width))
        }
    }

    /// Resolve bar width against the container. Caller-supplied `barWidth`
    /// always wins; `nil` fits to container by subtracting label + value +
    /// separators. Minimum 1 so the chart still has something to draw in
    /// absurdly narrow containers.
    func effectiveBarWidth(containerWidth: Int, labelWidth: Int, valueWidth: Int) -> Int {
        if let explicit = barWidth { return max(1, explicit) }
        let reserved = labelWidth + valueWidth + (showValues ? 2 : 1)
        return max(1, containerWidth - reserved)
    }

    func renderChart(containerWidth: Int = 80) -> String {
        guard !items.isEmpty else { return "" }

        let hi = maxValue ?? (items.map(\.value).max() ?? 1)
        let labelWidth = items.map(\.label.count).max() ?? 0
        let valueWidth = showValues
            ? items.map { formatValue($0.value).count }.max() ?? 0
            : 0
        let width = effectiveBarWidth(
            containerWidth: containerWidth,
            labelWidth: labelWidth,
            valueWidth: valueWidth
        )

        var lines: [String] = []
        for item in items {
            let label = item.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            let ratio = hi > 0 ? item.value / hi : 0

            // Full cells + fractional part
            let totalEighths = Int(ratio * Double(width * 8))
            let fullCells = totalEighths / 8
            let remainder = totalEighths % 8

            var bar = String(repeating: "█", count: fullCells)
            if remainder > 0 {
                bar.append(Self.blockChars[remainder])
            }
            // Pad to full width
            let barPad = max(0, width - bar.count)
            bar += String(repeating: " ", count: barPad)

            if showValues {
                let valueStr = formatValue(item.value)
                lines.append("\(label) \(bar) \(valueStr)")
            } else {
                lines.append("\(label) \(bar)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func formatValue(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.1f", v)
    }
}
