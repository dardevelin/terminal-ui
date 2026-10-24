/// A GitHub-style intensity grid: one character cell per data point,
/// colored (and optionally shaded) by magnitude.
///
/// Each row of `data` becomes one terminal row; each value maps to a color
/// step on the chosen ``HeatMap/Palette`` ramp. With the default `.block`
/// style every cell is a full block (`█`) and only the color varies;
/// `.shade` varies the glyph too (` ░▒▓█`), which keeps the ramp legible
/// on monochrome terminals. Values normalize against the grid's min/max
/// unless `min:`/`max:` pin the scale.
///
/// The dense-grid chart: contribution calendars, per-hour activity
/// matrices, correlation grids. For a single series over time, use
/// ``Sparkline``; for labeled category comparison, ``BarChart``.
///
/// ```swift
/// // A weekday x week activity calendar, as the ComponentsDemo wires it:
/// HeatMap(
///     data: state.heatmapData,   // [[Double]] — rows x cols
///     palette: .green,
///     cellStyle: .shade
/// )
/// ```
public struct HeatMap: TerminalView {
    /// Grid values, `data[row][col]`, rendered top row first.
    public let data: [[Double]]
    /// Color ramp values map onto.
    public let palette: Palette
    /// Which glyph each cell renders with.
    public let cellChar: CellStyle
    /// Value mapped to the ramp's low end; `nil` uses the grid minimum.
    public let minValue: Double?
    /// Value mapped to the ramp's high end; `nil` uses the grid maximum.
    public let maxValue: Double?

    /// Color ramp for mapping normalized values to ANSI-256 colors.
    public enum Palette {
        /// GitHub contribution style: dark green to bright green.
        case green
        /// Red intensity ramp.
        case red
        /// Blue intensity ramp.
        case blue
        /// Grayscale ramp.
        case gray
        /// Multi-hue ramp: blue → cyan → green → yellow → red.
        case thermal
    }

    /// Glyph choice per cell.
    public enum CellStyle {
        /// Full block `█` for every cell; only the color varies. The
        /// default.
        case block
        /// Shade glyphs ` ░▒▓█` vary with magnitude — legible even on
        /// monochrome terminals.
        case shade
        /// Smaller square `■`, leaving visible cell gaps.
        case square
    }

    /// Creates a heat map.
    ///
    /// - Parameters:
    ///   - data: Grid values, `data[row][col]`.
    ///   - palette: Color ramp (default `.green`).
    ///   - cellStyle: Cell glyph (default `.block`).
    ///   - min: Ramp low end; `nil` uses the grid minimum.
    ///   - max: Ramp high end; `nil` uses the grid maximum.
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

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        // Colored by default (I24) — build per-cell TextSpans so each
        // cell gets its palette-mapped foreground. Previous default went
        // through the grayscale `renderPlain()` path which threw away color
        // even though `colorForValue` was already available.
        Text(spans: renderSpans())
    }

    /// Emit colored spans, one per cell, with row breaks. Used by the default
    /// `body`; `renderPlain()` remains for callers that want the flat text.
    func renderSpans() -> [TextSpan] {
        guard !data.isEmpty else { return [] }
        let allValues = data.flatMap { $0 }
        let lo = minValue ?? (allValues.min() ?? 0)
        let hi = maxValue ?? (allValues.max() ?? 1)
        let range = hi - lo > 0 ? hi - lo : 1.0

        var spans: [TextSpan] = []
        spans.reserveCapacity(data.reduce(0) { $0 + $1.count } + data.count)
        for (rowIndex, row) in data.enumerated() {
            if rowIndex > 0 { spans.append(TextSpan("\n")) }
            for value in row {
                let normalized = (value - lo) / range
                let char = shadeChar(normalized)
                let color = colorForValue(normalized)
                spans.append(TextSpan(String(char), foreground: color))
            }
        }
        return spans
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
