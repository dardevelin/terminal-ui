import Foundation

// Debug overlay — renders directly into the cell buffer's bottom row.
// Bypasses the view tree and graph entirely — zero framework overhead.
// Erased in release builds.

#if DEBUG

/// The F1 stats line — one row of live frame metrics (fps, build/flush
/// time, delta bytes, dirty percentage) drawn into the buffer's bottom row.
/// Owned and rendered by the runtime, which toggles it via the
/// `toggle_debug_overlay` keybinding; it bypasses the view tree entirely
/// and costs nothing while hidden. Erased in release builds.
public final class DebugOverlay {
    /// Whether the stats row is currently drawn. The runtime flips this
    /// via ``toggle()``; nothing renders while false.
    public var visible: Bool = false

    /// Creates a hidden overlay. The runtime owns the sole instance.
    public init() {}

    /// Flip ``visible``. Bound to F1 by default (`toggle_debug_overlay`).
    public func toggle() { visible = !visible }

    /// Render directly into the buffer — called by the runtime, not the graph.
    public func render(into buffer: inout CellBuffer, stats: FrameStats) {
        guard visible else { return }
        let y = buffer.height - 1
        guard y >= 0, buffer.width > 20 else { return }

        // Active frame stats (from last frame that actually rendered)
        let aBuildMs = Double(stats.lastActiveBuildTime.components.attoseconds) / 1_000_000_000_000_000.0
        let aFlushMs = Double(stats.lastActiveFlushTime.components.attoseconds) / 1_000_000_000_000_000.0
        let aBytes = stats.lastActiveBytesWritten
        let aCells = stats.lastActiveCellsChanged

        let uptimeSec = Double(stats.uptime.components.seconds)
            + Double(stats.uptime.components.attoseconds) / 1_000_000_000_000_000_000.0

        let bytesText = aBytes > 1024
            ? String(format: "%.1fkb", Double(aBytes) / 1024.0)
            : "\(aBytes)b"

        let diffPct = stats.totalCells > 0
            ? Int(Double(aCells) / Double(stats.totalCells) * 100)
            : 0

        let dim = Style(foreground: .gray, background: nil, bold: false, italic: false, underline: false)

        let segments: [(String, Style)] = [
            ("dbg", Style(foreground: .magenta, background: nil, bold: true, italic: false, underline: false)),
            (String(format: " %.0f/%.0ffps", stats.activeRenderFps, stats.fps),
             Style(foreground: stats.activeRenderFps > 30 ? .green : stats.activeRenderFps > 15 ? .yellow : .red,
                   background: nil, bold: false, italic: false, underline: false)),
            (String(format: " build:%.2fms", aBuildMs),
             Style(foreground: .cyan, background: nil, bold: false, italic: false, underline: false)),
            (String(format: " io:%.2fms", aFlushMs),
             Style(foreground: .yellow, background: nil, bold: false, italic: false, underline: false)),
            (" \(bytesText) \(diffPct)%dirty f:\(stats.frameCount)", dim),
        ]

        var x = 0
        for (text, style) in segments {
            buffer.write(text, x: x, y: y, style: style)
            x += text.count
        }

        let uptimeText = String(format: "%.0fs", uptimeSec)
        let uptimeX = buffer.width - uptimeText.count
        if uptimeX > x {
            buffer.write(uptimeText, x: uptimeX, y: y, style: dim)
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
