/// GitHub-style contribution heatmap using block/shade characters.
/// Maps values to intensity levels: ░▒▓█ or custom palette.
///
/// Usage:
/// ```
/// HeatMap(
///     data: contributions,  // [[Double]] — rows x cols
///     palette: .green       // color ramp
/// )
/// ```
public struct HeatMap: TerminalView {
    public let data: [[Double]]
    public let palette: Palette
    public let cellChar: CellStyle
    public let minValue: Double?
    public let maxValue: Double?

    public enum Palette {
        case green     // GitHub style: dark→bright green
        case red       // Red intensity
        case blue      // Blue intensity
        case gray      // Grayscale
        case thermal   // Blue→cyan→green→yellow→red
    }

    public enum CellStyle {
        case block     // █ (full block, color varies)
        case shade     // ░▒▓█ (character varies)
        case square    // ■ (smaller square)
    }

    public init(
        data: [[Double]],
        palette: Palette = .green,
        cellStyle: CellStyle = .block,
        min: Double? = nil,
        max: Double? = nil
    ) {
        self.data = data
        self.palette = palette
        self.cellChar = cellStyle
        self.minValue = min
        self.maxValue = max
    }

    public var body: some TerminalView {
        // HeatMap needs per-cell coloring — can't use single Text node.
        // Use precomputed multi-line text with consistent widths.
        Text(renderPlain())
    }

    /// Render as plain text (shade chars only, no color).
    /// For colored rendering, use the graph renderer directly.
    func renderPlain() -> String {
        guard !data.isEmpty else { return "" }

        let allValues = data.flatMap { $0 }
        let lo = minValue ?? (allValues.min() ?? 0)
        let hi = maxValue ?? (allValues.max() ?? 1)
        let range = hi - lo > 0 ? hi - lo : 1.0

        var lines: [String] = []
        for row in data {
            var line = ""
            for value in row {
                let normalized = (value - lo) / range
                line.append(shadeChar(normalized))
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    func shadeChar(_ normalized: Double) -> Character {
        switch cellChar {
        case .shade:
            let levels: [Character] = [" ", "░", "▒", "▓", "█"]
            let idx = min(levels.count - 1, Int(normalized * Double(levels.count)))
            return levels[idx]
        case .block:
            return normalized > 0.01 ? "█" : " "
        case .square:
            return normalized > 0.01 ? "■" : " "
        }
    }

    /// Map a normalized value (0-1) to an ANSI 256 color for the palette.
    /// Useful for colored rendering in the graph renderer.
    public func colorForValue(_ normalized: Double) -> Color {
        let n = max(0, min(1, normalized))
        switch palette {
        case .green:
            // GitHub green ramp: 232 (dark) → 22 → 28 → 34 → 40 → 46 (bright)
            let greens: [UInt8] = [232, 22, 28, 34, 40, 46]
            let idx = min(greens.count - 1, Int(n * Double(greens.count)))
            return .ansi256(greens[idx])
        case .red:
            let reds: [UInt8] = [232, 52, 88, 124, 160, 196]
            let idx = min(reds.count - 1, Int(n * Double(reds.count)))
            return .ansi256(reds[idx])
        case .blue:
            let blues: [UInt8] = [232, 17, 18, 19, 20, 21]
            let idx = min(blues.count - 1, Int(n * Double(blues.count)))
            return .ansi256(blues[idx])
        case .gray:
            // Grayscale ramp 232-255
            let level = UInt8(232 + Int(n * 23))
            return .ansi256(level)
        case .thermal:
            // Blue→Cyan→Green→Yellow→Red
            let thermal: [UInt8] = [17, 19, 21, 30, 36, 42, 46, 190, 220, 208, 196]
            let idx = min(thermal.count - 1, Int(n * Double(thermal.count)))
            return .ansi256(thermal[idx])
        }
    }
}
