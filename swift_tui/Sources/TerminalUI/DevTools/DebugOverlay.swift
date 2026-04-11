import Foundation

/// Debug overlay — renders directly into the cell buffer's bottom row.
/// Bypasses the view tree and graph entirely — zero framework overhead.
/// Erased in release builds.

#if DEBUG

public final class DebugOverlay {
    public var visible: Bool = false

    public init() {}

    public func toggle() { visible = !visible }

    /// Render directly into the buffer — called by the runtime, not the graph.
    public func render(into buffer: inout CellBuffer, stats: FrameStats) {
        guard visible else { return }
        let y = buffer.height - 1
        guard y >= 0, buffer.width > 20 else { return }

        let buildMs = Double(stats.buildTime.components.attoseconds) / 1_000_000_000_000_000.0
        let flushMs = Double(stats.flushTime.components.attoseconds) / 1_000_000_000_000_000.0
        let uptimeSec = Double(stats.uptime.components.seconds)
            + Double(stats.uptime.components.attoseconds) / 1_000_000_000_000_000_000.0

        let bytesText = stats.bytesWritten > 1024
            ? String(format: "%.1fkb", Double(stats.bytesWritten) / 1024.0)
            : "\(stats.bytesWritten)b"

        let diffPct = stats.totalCells > 0
            ? Int(Double(stats.cellsChanged) / Double(stats.totalCells) * 100)
            : 0

        // Build the line as segments with styles — no view tree, no graph nodes
        let segments: [(String, Style)] = [
            ("dbg", Style(foreground: .magenta, background: nil, bold: true, italic: false, underline: false)),
            (String(format: " %.0ffps", stats.fps),
             Style(foreground: stats.fps > 100 ? .green : stats.fps > 30 ? .yellow : .red,
                   background: nil, bold: false, italic: false, underline: false)),
            (String(format: " build:%.2fms", buildMs),
             Style(foreground: .cyan, background: nil, bold: false, italic: false, underline: false)),
            (String(format: " io:%.2fms", flushMs),
             Style(foreground: .yellow, background: nil, bold: false, italic: false, underline: false)),
            (" \(bytesText) \(diffPct)%dirty f:\(stats.frameCount)",
             Style(foreground: .gray, background: nil, bold: false, italic: false, underline: false)),
        ]

        let uptimeText = String(format: "%.0fs", uptimeSec)
        let uptimeStyle = Style(foreground: .gray, background: nil, bold: false, italic: false, underline: false)

        // Write segments left-aligned
        var x = 0
        for (text, style) in segments {
            buffer.write(text, x: x, y: y, style: style)
            x += text.count
        }

        // Write uptime right-aligned
        let uptimeX = buffer.width - uptimeText.count
        if uptimeX > x {
            buffer.write(uptimeText, x: uptimeX, y: y, style: uptimeStyle)
        }
    }
}

#else

public final class DebugOverlay: Sendable {
    public init() {}
    @inline(__always) public func toggle() {}
    @inline(__always) public func render(into buffer: inout CellBuffer, stats: FrameStats) {}
}

#endif
