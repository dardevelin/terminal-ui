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
    public let barWidth: Int
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
        barWidth: Int = 30,
        maxValue: Double? = nil,
        showValues: Bool = true
    ) {
        self.items = items
        self.barWidth = barWidth
        self.maxValue = maxValue
        self.showValues = showValues
    }

    public var body: some TerminalView {
        Text(renderChart())
    }

    func renderChart() -> String {
        guard !items.isEmpty else { return "" }

        let hi = maxValue ?? (items.map(\.value).max() ?? 1)
        let labelWidth = items.map(\.label.count).max() ?? 0

        var lines: [String] = []
        for item in items {
            let label = item.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            let ratio = hi > 0 ? item.value / hi : 0

            // Full cells + fractional part
            let totalEighths = Int(ratio * Double(barWidth * 8))
            let fullCells = totalEighths / 8
            let remainder = totalEighths % 8

            var bar = String(repeating: "█", count: fullCells)
            if remainder > 0 {
                bar.append(Self.blockChars[remainder])
            }
            // Pad to full width
            let barPad = max(0, barWidth - bar.count)
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
