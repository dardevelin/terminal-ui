import Foundation

/// In-app debug panel — renders directly into the cell buffer.
/// Toggled with ctrl+d. Shows graph tree, frame stats, input log.
/// Erased in release builds.

#if DEBUG

public enum DebugPanelMode {
    case hidden
    case graphTree      // show live node tree
    case frameTimeline  // show frame time histogram
    case inputLog       // show recent input events
}

public final class DebugPanel {
    public var mode: DebugPanelMode = .hidden {
        didSet { isDirty = true }
    }
    public var width: Int = 45

    // Ring buffers for history
    var frameTimes: [Double] = []
    var inputEvents: [(Double, String)] = []
    let maxHistory = 120

    // Dirty tracking — only re-render panel when content changed
    var isDirty: Bool = true
    var cachedPanelCells: [(Int, Int, Cell)] = []  // (x, y, cell) from last render
    var lastMode: DebugPanelMode = .hidden
    var lastBufferWidth: Int = 0
    var lastBufferHeight: Int = 0

    public init() {}

    public func toggle() {
        switch mode {
        case .hidden:     mode = .graphTree
        case .graphTree:  mode = .frameTimeline
        case .frameTimeline: mode = .inputLog
        case .inputLog:   mode = .hidden
        }
    }

    public func recordFrameTime(_ ms: Double) {
        frameTimes.append(ms)
        if frameTimes.count > maxHistory {
            frameTimes.removeFirst(frameTimes.count - maxHistory)
        }
        // Frame timeline mode is always dirty (new data each frame)
        if mode == .frameTimeline { isDirty = true }
    }

    public func recordInput(_ description: String, timestamp: Double) {
        inputEvents.append((timestamp, description))
        if inputEvents.count > maxHistory {
            inputEvents.removeFirst(inputEvents.count - maxHistory)
        }
        if mode == .inputLog { isDirty = true }
    }

    /// Mark dirty when graph changes (for graph tree mode)
    public func markGraphDirty() {
        if mode == .graphTree { isDirty = true }
    }

    /// Render the debug panel into the right side of the buffer.
    /// Uses cached cells when panel content hasn't changed.
    public func render(into buffer: inout CellBuffer, graph: AttributeGraph?, stats: FrameStats) {
        guard mode != .hidden else { return }

        // Check if we can reuse cached cells
        let sizeChanged = buffer.width != lastBufferWidth || buffer.height != lastBufferHeight

        if !isDirty && !sizeChanged && mode == lastMode && !cachedPanelCells.isEmpty {
            // Replay cached cells — skip all rendering work
            for (x, y, cell) in cachedPanelCells {
                buffer[x, y] = cell
            }
            return
        }

        let panelWidth = min(width, buffer.width / 2)
        let panelX = buffer.width - panelWidth
        let panelHeight = buffer.height

        // Draw panel background
        let bgStyle = Style(foreground: .white, background: .ansi256(236), bold: false, italic: false, underline: false)
        let headerStyle = Style(foreground: .cyan, background: .ansi256(236), bold: true, italic: false, underline: false)
        let dimStyle = Style(foreground: .gray, background: .ansi256(236), bold: false, italic: false, underline: false)
        let dirtyStyle = Style(foreground: .yellow, background: .ansi256(236), bold: false, italic: false, underline: false)

        // Clear panel area
        for y in 0..<panelHeight {
            for x in panelX..<buffer.width {
                buffer[x, y] = Cell(character: " ", style: bgStyle)
            }
        }

        // Border
        for y in 0..<panelHeight {
            buffer[panelX, y] = Cell(character: "│", style: dimStyle)
        }

        var row = 0

        // Header
        let title: String
        switch mode {
        case .hidden: return
        case .graphTree: title = " GRAPH TREE"
        case .frameTimeline: title = " FRAME TIMELINE"
        case .inputLog: title = " INPUT LOG"
        }
        writeLine(title, into: &buffer, x: panelX + 1, y: row, width: panelWidth - 1, style: headerStyle)
        row += 1
        writeLine(String(repeating: "─", count: panelWidth - 1), into: &buffer, x: panelX + 1, y: row, width: panelWidth - 1, style: dimStyle)
        row += 1

        switch mode {
        case .hidden: break
        case .graphTree:
            renderGraphTree(into: &buffer, graph: graph, panelX: panelX + 2, startRow: row, panelWidth: panelWidth - 2, panelHeight: panelHeight, bgStyle: bgStyle, dimStyle: dimStyle, dirtyStyle: dirtyStyle)
        case .frameTimeline:
            renderFrameTimeline(into: &buffer, stats: stats, panelX: panelX + 2, startRow: row, panelWidth: panelWidth - 2, panelHeight: panelHeight, bgStyle: bgStyle, dimStyle: dimStyle)
        case .inputLog:
            renderInputLog(into: &buffer, panelX: panelX + 2, startRow: row, panelWidth: panelWidth - 2, panelHeight: panelHeight, bgStyle: bgStyle, dimStyle: dimStyle)
        }

        // Footer
        let footerRow = panelHeight - 1
        writeLine(" ctrl+d: cycle  q: close", into: &buffer, x: panelX + 1, y: footerRow, width: panelWidth - 1, style: dimStyle)

        // Cache the rendered panel cells for reuse on clean frames
        cachedPanelCells.removeAll(keepingCapacity: true)
        for y in 0..<panelHeight {
            for x in panelX..<buffer.width {
                cachedPanelCells.append((x, y, buffer[x, y]))
            }
        }
        lastMode = mode
        lastBufferWidth = buffer.width
        lastBufferHeight = buffer.height
        isDirty = false
    }

    // MARK: - Graph Tree

    func renderGraphTree(into buffer: inout CellBuffer, graph: AttributeGraph?, panelX: Int, startRow: Int, panelWidth: Int, panelHeight: Int, bgStyle: Style, dimStyle: Style, dirtyStyle: Style) {
        guard let root = graph?.root else { return }
        var row = startRow
        renderNode(root, into: &buffer, panelX: panelX, row: &row, panelWidth: panelWidth, maxRow: panelHeight - 2, depth: 0, bgStyle: bgStyle, dimStyle: dimStyle, dirtyStyle: dirtyStyle)
    }

    func renderNode(_ node: AttributeNode, into buffer: inout CellBuffer, panelX: Int, row: inout Int, panelWidth: Int, maxRow: Int, depth: Int, bgStyle: Style, dimStyle: Style, dirtyStyle: Style) {
        guard row < maxRow else { return }

        let indent = String(repeating: "  ", count: min(depth, 8))
        let prefix = depth > 0 ? "├─" : ""

        let kind: String
        let detail: String
        let style: Style

        switch node.kind {
        case .primitive(let content):
            switch content {
            case .text(let s):
                kind = "txt"
                let preview = s.replacingOccurrences(of: "\n", with: "\\n")
                detail = preview.count > 15 ? String(preview.prefix(15)) + ".." : preview
            case .spacer:
                kind = "spc"
                detail = ""
            case .progressBar(let v, _, _, _):
                kind = "prg"
                detail = "\(Int(v * 100))%"
            case .spinner(let f, _):
                kind = "spn"
                detail = "f:\(f)"
            case .empty:
                kind = "emp"
                detail = ""
            }
            style = node.isDirty ? dirtyStyle : bgStyle

        case .layout(let info):
            kind = info.kind == .vstack ? "V" : "H"
            detail = "[\(node.children.count)]"
            style = node.isDirty ? dirtyStyle : Style(foreground: .cyan, background: .ansi256(236), bold: false, italic: false, underline: false)

        case .modifier(let effect):
            switch effect {
            case .foreground(let c): kind = "fg"; detail = "\(c)"
            case .background(let c): kind = "bg"; detail = "\(c)"
            case .bold: kind = "B"; detail = ""
            case .italic: kind = "I"; detail = ""
            case .underline: kind = "U"; detail = ""
            case .padding(let n): kind = "pad"; detail = "\(n)"
            case .border(_): kind = "bdr"; detail = ""
            }
            style = node.isDirty ? dirtyStyle : dimStyle

        case .viewBody(let info):
            kind = info.viewTypeName
            detail = ""
            style = node.isDirty ? dirtyStyle : Style(foreground: .green, background: .ansi256(236), bold: false, italic: false, underline: false)
        }

        let line: String
        if detail.isEmpty {
            line = "\(indent)\(prefix)\(kind)"
        } else {
            line = "\(indent)\(prefix)\(kind) \(detail)"
        }

        writeLine(line, into: &buffer, x: panelX, y: row, width: panelWidth, style: style)
        row += 1

        for child in node.children {
            renderNode(child, into: &buffer, panelX: panelX, row: &row, panelWidth: panelWidth, maxRow: maxRow, depth: depth + 1, bgStyle: bgStyle, dimStyle: dimStyle, dirtyStyle: dirtyStyle)
        }
    }

    // MARK: - Frame Timeline

    func renderFrameTimeline(into buffer: inout CellBuffer, stats: FrameStats, panelX: Int, startRow: Int, panelWidth: Int, panelHeight: Int, bgStyle: Style, dimStyle: Style) {
        var row = startRow

        let fpsText = String(format: "FPS: %.0f", stats.fps)
        writeLine(fpsText, into: &buffer, x: panelX, y: row, width: panelWidth, style: bgStyle)
        row += 1

        let buildMs = Double(stats.buildTime.components.attoseconds) / 1_000_000_000_000_000.0
        let flushMs = Double(stats.flushTime.components.attoseconds) / 1_000_000_000_000_000.0
        writeLine(String(format: "Build: %.2fms", buildMs), into: &buffer, x: panelX, y: row, width: panelWidth, style: bgStyle)
        row += 1
        writeLine(String(format: "IO:    %.2fms", flushMs), into: &buffer, x: panelX, y: row, width: panelWidth, style: bgStyle)
        row += 1
        writeLine("Bytes: \(stats.bytesWritten)", into: &buffer, x: panelX, y: row, width: panelWidth, style: bgStyle)
        row += 1
        writeLine("", into: &buffer, x: panelX, y: row, width: panelWidth, style: bgStyle)
        row += 1

        // Histogram of frame times
        let histHeight = min(panelHeight - row - 2, 20)
        guard !frameTimes.isEmpty, histHeight > 0 else { return }

        let visible = Array(frameTimes.suffix(panelWidth))
        let maxTime = max(visible.max() ?? 1.0, 1.0)

        writeLine(String(format: "%.1fms ┐", maxTime), into: &buffer, x: panelX, y: row, width: panelWidth, style: dimStyle)
        row += 1

        for histRow in 0..<histHeight {
            let threshold = maxTime * Double(histHeight - histRow) / Double(histHeight)
            var line = ""
            for i in 0..<min(visible.count, panelWidth - 1) {
                if visible[i] >= threshold {
                    line += "█"
                } else if visible[i] >= threshold - (maxTime / Double(histHeight)) * 0.5 {
                    line += "▄"
                } else {
                    line += " "
                }
            }
            let barStyle: Style
            let ratio = Double(histHeight - histRow) / Double(histHeight)
            if ratio > 0.7 {
                barStyle = Style(foreground: .red, background: .ansi256(236), bold: false, italic: false, underline: false)
            } else if ratio > 0.4 {
                barStyle = Style(foreground: .yellow, background: .ansi256(236), bold: false, italic: false, underline: false)
            } else {
                barStyle = Style(foreground: .green, background: .ansi256(236), bold: false, italic: false, underline: false)
            }
            writeLine(line, into: &buffer, x: panelX, y: row, width: panelWidth, style: barStyle)
            row += 1
        }
        writeLine(String(format: " 0ms ┘ last %d frames", visible.count), into: &buffer, x: panelX, y: row, width: panelWidth, style: dimStyle)
    }

    // MARK: - Input Log

    func renderInputLog(into buffer: inout CellBuffer, panelX: Int, startRow: Int, panelWidth: Int, panelHeight: Int, bgStyle: Style, dimStyle: Style) {
        let visible = inputEvents.suffix(panelHeight - startRow - 2)
        var row = startRow

        for (ts, desc) in visible {
            guard row < panelHeight - 1 else { break }
            let line = String(format: "%.2f %@", ts, desc)
            writeLine(line, into: &buffer, x: panelX, y: row, width: panelWidth, style: bgStyle)
            row += 1
        }
    }

    // MARK: - Helpers

    func writeLine(_ text: String, into buffer: inout CellBuffer, x: Int, y: Int, width: Int, style: Style) {
        guard y >= 0, y < buffer.height else { return }
        var col = x
        for char in text {
            guard col < x + width, col < buffer.width else { break }
            buffer[col, y] = Cell(character: char, style: style)
            col += 1
        }
    }
}

#else

public enum DebugPanelMode { case hidden }
public final class DebugPanel: Sendable {
    public var mode: DebugPanelMode { .hidden }
    public init() {}
    @inline(__always) public func toggle() {}
    @inline(__always) public func recordFrameTime(_ ms: Double) {}
    @inline(__always) public func recordInput(_ description: String, timestamp: Double) {}
    @inline(__always) public func render(into buffer: inout CellBuffer, graph: AttributeGraph?, stats: FrameStats) {}
}

#endif
