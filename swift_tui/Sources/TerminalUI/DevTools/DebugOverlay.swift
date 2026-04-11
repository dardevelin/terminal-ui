import Foundation

#if DEBUG

public struct DebugOverlay: TerminalView {
    public init() {}

    public var body: some TerminalView {
        let s = DebugOverlay.format(frameStats)

        HStack {
            Text("dbg")
                .foreground(.magenta)
                .bold()
            Text(" \(s.fps)")
                .foreground(s.fpsColor)
            Text(" \(s.build)")
                .foreground(.cyan)
            Text(" \(s.flush)")
                .foreground(.yellow)
            Text(" \(s.bytes) \(s.dirty)")
                .foreground(.gray)
            Text(" f:\(s.frame)")
                .foreground(.gray)
            Spacer()
            Text(s.uptime)
                .foreground(.gray)
        }
    }

    struct Formatted {
        var fps: String
        var fpsColor: Color
        var build: String
        var flush: String
        var bytes: String
        var dirty: String
        var frame: Int
        var uptime: String
    }

    static func format(_ stats: FrameStats) -> Formatted {
        let buildUs = Double(stats.buildTime.components.attoseconds) / 1_000_000_000_000.0
        let flushUs = Double(stats.flushTime.components.attoseconds) / 1_000_000_000_000.0
        let uptimeSec = Double(stats.uptime.components.seconds)
            + Double(stats.uptime.components.attoseconds) / 1_000_000_000_000_000_000.0

        let bytesText = stats.bytesWritten > 1024
            ? String(format: "%.1fkb", Double(stats.bytesWritten) / 1024.0)
            : "\(stats.bytesWritten)b"

        let diffPct = stats.totalCells > 0
            ? String(format: "%.0f%%", Double(stats.cellsChanged) / Double(stats.totalCells) * 100)
            : "0%"

        let fpsColor: Color = stats.fps > 100 ? .green : stats.fps > 30 ? .yellow : .red

        return Formatted(
            fps: String(format: "%.0ffps", stats.fps),
            fpsColor: fpsColor,
            build: String(format: "build:%.2fms", buildUs),
            flush: String(format: "io:%.2fms", flushUs),
            bytes: bytesText,
            dirty: "\(diffPct)dirty",
            frame: stats.frameCount,
            uptime: String(format: "%.0fs", uptimeSec)
        )
    }
}

#else

public struct DebugOverlay: TerminalView {
    public init() {}
    public var body: some TerminalView {
        EmptyView()
    }
}

#endif
