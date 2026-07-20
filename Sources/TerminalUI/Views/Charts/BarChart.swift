/// Horizontal bar chart using block characters for half-cell precision.
/// Uses ▏▎▍▌▋▊▉█ for 1/8th cell resolution.
///
/// Usage:
/// ```
/// BarChart(
///     items: [
///         .init(label: "Go", value: 18000),
///         .init(label: "Rust", value: 12000),
///         .init(label: "Swift", value: 8000),
///     ],
///     barWidth: 30
/// )
/// ```
public struct BarChart: TerminalView {
    public let items: [Item]
    /// Explicit bar width in cells. `nil` (default) fits the chart to its
    /// container: bar width = `container.width - labelWidth - valueWidth - 2`.
    /// Pass an explicit integer to pin the width (benchmarks, fixed layouts).
    public let barWidth: Int?
    public let maxValue: Double?
    public let showValues: Bool

    public struct Item {
        public let label: String
        public let value: Double
        public let color: Color?

        public init(label: String, value: Double, color: Color? = nil) {
            self.label = label
            self.value = value
            self.color = color
        }
    }

    // 1/8th block chars for sub-cell horizontal resolution
    static let blockChars: [Character] = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"]

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
