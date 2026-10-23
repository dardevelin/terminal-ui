import Foundation

// In-app debug panel — renders directly into the cell buffer.
// Shows graph tree, frame stats, input log. Erased in release builds.

#if DEBUG

/// Which view the ``DebugPanel`` is showing; ``DebugPanel/toggle()``
/// cycles through these in declaration order.
public enum DebugPanelMode {
    /// Panel not rendered.
    case hidden
    /// The live node tree.
    case graphTree
    /// The frame-time histogram.
    case frameTimeline
    /// The recent-input event log.
    case inputLog
}

/// The F2 side panel — a right-docked column showing the live node tree,
/// a frame-time histogram, or the recent-input log, drawn directly into
/// the cell buffer outside the view tree. Owned by the runtime, which
/// cycles its modes via the `toggle_debug_panel` keybinding and feeds it
/// history through ``recordFrameTime(_:)`` / ``recordInput(_:timestamp:)``.
/// Erased in release builds.
public final class DebugPanel {
    /// Current panel view. Setting it marks the panel for re-render.
    public var mode: DebugPanelMode = .hidden {
        didSet { isDirty = true }
    }
    /// Panel width in cells; the renderer clamps it to half the buffer width.
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

    // Graph tree scroll state
    var graphScrollOffset: Int = 0
    var graphTotalLines: Int = 0  // total lines in the tree (calculated each render)

    // Collapsed nodes — tracked by NodeID
    var collapsedNodes: Set<NodeID> = []

    /// Creates a hidden panel. The runtime owns the sole instance.
    public init() {}

    /// Advance to the next mode: hidden → graph tree → frame timeline →
    /// input log → hidden. Bound to F2 by default (`toggle_debug_panel`).
    public func toggle() {
        switch mode {
        case .hidden:     mode = .graphTree
        case .graphTree:  mode = .frameTimeline
        case .frameTimeline: mode = .inputLog
        case .inputLog:   mode = .hidden
        }
    }

    /// Runtime hook: append one frame's build time (milliseconds) to the
    /// timeline's ring buffer (last 120 frames).
    public func recordFrameTime(_ ms: Double) {
        frameTimes.append(ms)
        if frameTimes.count > maxHistory {
            frameTimes.removeFirst(frameTimes.count - maxHistory)
        }
        if mode == .frameTimeline { isDirty = true }
    }

    /// Runtime hook: append one input event to the input-log ring buffer
    /// (last 120 events). `timestamp` is process uptime in seconds.
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

    // MARK: - Graph Tree Scroll

    /// Scroll the graph-tree view up by `amount` lines, clamped at the top.
    public func scrollGraphUp(amount: Int = 1) {
        graphScrollOffset = max(0, graphScrollOffset - amount)
        isDirty = true
    }

    /// Scroll the graph-tree view down by `amount` lines, keeping at
    /// least five lines visible at the bottom.
    public func scrollGraphDown(amount: Int = 1) {
        let maxOffset = max(0, graphTotalLines - 5)  // Keep at least 5 visible lines
        graphScrollOffset = min(maxOffset, graphScrollOffset + amount)
        isDirty = true
    }

    /// Page the graph-tree view up by one panel height (minus a two-line overlap).
    public func scrollGraphPageUp(visibleLines: Int) {
        scrollGraphUp(amount: max(1, visibleLines - 2))
    }

    /// Page the graph-tree view down by one panel height (minus a two-line overlap).
    public func scrollGraphPageDown(visibleLines: Int) {
        scrollGraphDown(amount: max(1, visibleLines - 2))
    }

    // MARK: - Collapse/Expand

    /// Toggle collapsed state for a node. Called on click or enter.
    public func toggleCollapse(nodeID: NodeID) {
        if collapsedNodes.contains(nodeID) {
            collapsedNodes.remove(nodeID)
        } else {
            collapsedNodes.insert(nodeID)
        }
        isDirty = true
    }

    /// Handle a mouse click in the graph tree panel area.
    /// Returns true if the click was inside the panel and handled.
    public func handleClick(x: Int, y: Int, graph: AttributeGraph?, bufferWidth: Int, bufferHeight: Int) -> Bool {
        guard mode == .graphTree else { return false }
        let panelWidth = min(width, bufferWidth / 2)
        let panelX = bufferWidth - panelWidth
        guard x >= panelX && x < bufferWidth else { return false }
        guard y >= 2 else { return false }  // Skip header rows

        // Find which node this row maps to
        guard let root = graph?.root else { return false }
        let targetLine = y - 2 + graphScrollOffset  // 2 = header + separator
        var currentLine = 0
        if let nodeID = findNodeAtLine(root, targetLine: targetLine, currentLine: &currentLine) {
            toggleCollapse(nodeID: nodeID)
            return true
        }
        return false
    }

    /// Find the NodeID at a specific line in the flattened tree.
    private func findNodeAtLine(_ node: AttributeNode, targetLine: Int, currentLine: inout Int) -> NodeID? {
        if currentLine == targetLine {
            return node.id
        }
        currentLine += 1

        if collapsedNodes.contains(node.id) {
            return nil  // Children hidden
        }

        for child in node.children {
            if let found = findNodeAtLine(child, targetLine: targetLine, currentLine: &currentLine) {
                return found
            }
        }
        return nil
    }

    // MARK: - Render

    /// Render the debug panel into the right side of the buffer.
    /// Uses cached cells when panel content hasn't changed.
    public func render(into buffer: inout CellBuffer, graph: AttributeGraph?, stats: FrameStats) {
        guard mode != .hidden else { return }

        // Check if we can reuse cached cells
        let sizeChanged = buffer.width != lastBufferWidth || buffer.height != lastBufferHeight

        if !isDirty && !sizeChanged && mode == lastMode && !cachedPanelCells.isEmpty {
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
        let footerText: String
        if mode == .graphTree {
            footerText = " ↑↓:scroll  click:fold  ctrl+f:cycle"
        } else {
            footerText = " ctrl+f: cycle  q: close"
        }
        writeLine(footerText, into: &buffer, x: panelX + 1, y: footerRow, width: panelWidth - 1, style: dimStyle)

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

        // First pass: count total lines (needed for scroll bounds)
        graphTotalLines = countLines(root)

        // Clamp scroll offset
        let visibleLines = panelHeight - startRow - 3  // reserve 2 for end marker + footer
        if graphTotalLines <= visibleLines {
            graphScrollOffset = 0
        } else {
            graphScrollOffset = min(graphScrollOffset, max(0, graphTotalLines - visibleLines))
        }

        // Second pass: flatten tree into lines, respecting collapsed state
        var allLines: [(depth: Int, node: AttributeNode, isCollapsed: Bool)] = []
        flattenTree(root, depth: 0, into: &allLines)

        // Render visible slice
        let visibleSlice = allLines.dropFirst(graphScrollOffset).prefix(visibleLines)
        var row = startRow

        // Scroll indicator at top
        if graphScrollOffset > 0 {
            let indicator = " ▲ \(graphScrollOffset) more above"
            writeLine(indicator, into: &buffer, x: panelX, y: row, width: panelWidth, style: dimStyle)
            row += 1
        }

        for (depth, node, isCollapsed) in visibleSlice {
            guard row < panelHeight - 2 else { break }
            renderNodeLine(node, depth: depth, isCollapsed: isCollapsed, into: &buffer, panelX: panelX, y: row, panelWidth: panelWidth, bgStyle: bgStyle, dimStyle: dimStyle, dirtyStyle: dirtyStyle)
            row += 1
        }

        // End-of-tree separator
        let linesBelow = graphTotalLines - graphScrollOffset - visibleLines
        if linesBelow > 0 {
            let indicator = " ▼ \(linesBelow) more below"
            writeLine(indicator, into: &buffer, x: panelX, y: row, width: panelWidth, style: dimStyle)
            row += 1
        } else {
            // End marker
            writeLine(String(repeating: "─", count: panelWidth), into: &buffer, x: panelX, y: row, width: panelWidth, style: dimStyle)
            row += 1
            writeLine(" end of tree", into: &buffer, x: panelX, y: row, width: panelWidth, style: dimStyle)
        }
    }

    /// Count total visible lines in the tree (respecting collapsed state).
    func countLines(_ node: AttributeNode) -> Int {
        var count = 1  // This node
        if !collapsedNodes.contains(node.id) {
            for child in node.children {
                count += countLines(child)
            }
        }
        return count
    }

    /// Flatten the tree into an array of (depth, node, isCollapsed) for rendering.
    func flattenTree(_ node: AttributeNode, depth: Int, into result: inout [(depth: Int, node: AttributeNode, isCollapsed: Bool)]) {
        let isCollapsed = collapsedNodes.contains(node.id) && !node.children.isEmpty
        result.append((depth: depth, node: node, isCollapsed: isCollapsed))

        if !collapsedNodes.contains(node.id) {
            for child in node.children {
                flattenTree(child, depth: depth + 1, into: &result)
            }
        }
    }

    /// Render a single node line.
    func renderNodeLine(_ node: AttributeNode, depth: Int, isCollapsed: Bool, into buffer: inout CellBuffer, panelX: Int, y: Int, panelWidth: Int, bgStyle: Style, dimStyle: Style, dirtyStyle: Style) {
        let indent = String(repeating: "  ", count: min(depth, 8))

        // Collapse indicator for nodes with children
        let collapsePrefix: String
        if node.children.isEmpty {
            collapsePrefix = depth > 0 ? "──" : ""
        } else if isCollapsed {
            collapsePrefix = "▸ "
        } else {
            collapsePrefix = "▾ "
        }

        let kind: String
        let detail: String
        let style: Style

        switch node.kind {
        case .primitive(let content):
            switch content {
            case .text(let spans):
                kind = "txt"
                let s = spans.map(\.text).joined()
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
            case .divider:
                kind = "div"
                detail = ""
            case .empty:
                kind = "emp"
                detail = ""
            case .cellBuffer(let buf):
                kind = "buf"
                detail = "\(buf.width)x\(buf.height)"
            }
            style = node.isDirty ? dirtyStyle : bgStyle

        case .layout(let info):
            switch info.kind {
            case .vstack: kind = "V"
            case .hstack: kind = "H"
            case .zstack: kind = "Z"
            case .scroll(let axis): kind = axis == .horizontal ? "Sc(H)" : "Sc(V)"
            case .split(let axis): kind = axis == .horizontal ? "Sp(H)" : "Sp(V)"
            }
            let childCount = isCollapsed ? "[\(node.children.count)…]" : "[\(node.children.count)]"
            detail = childCount
            style = node.isDirty ? dirtyStyle : Style(foreground: .cyan, background: .ansi256(236), bold: false, italic: false, underline: false)

        case .modifier(let effect):
            switch effect {
            case .foreground(let c): kind = "fg"; detail = "\(c)"
            case .background(let c): kind = "bg"; detail = c.groundDescription
            case .bold: kind = "B"; detail = ""
            case .italic: kind = "I"; detail = ""
            case .underline: kind = "U"; detail = ""
            case .padding(let n): kind = "pad"; detail = "\(n)"
            case .border: kind = "bdr"; detail = ""
            case .frame(let w, let h, _, _, _, _, _): kind = "frm"; detail = "\(w ?? 0)x\(h ?? 0)"
            case .flexible(let axes, let grow):
                kind = "flex"
                let axisLabel = axes == .all ? "↔↕" : (axes.contains(.horizontal) ? "↔" : "↕")
                detail = grow == 1 ? axisLabel : "\(axisLabel) ×\(grow)"
            case .explicitID(_): kind = "id"; detail = ""
            case .overlay: kind = "ovl"; detail = ""
            case .backgroundView: kind = "bg"; detail = ""
            case .modal(let p): kind = "mdl"; detail = p ? "on" : "off"
            case .focusable: kind = "fcs"; detail = ""
            case .focusScope(let id): kind = "scope"; detail = id
            case .prefersDefaultFocus(let prefers): kind = "dflt"; detail = "\(prefers)"
            case .onKeyPress: kind = "key"; detail = ""
            case .onAppear: kind = "app"; detail = ""
            case .onChange: kind = "chg"; detail = ""
            case .onDisappear: kind = "dis"; detail = ""
            case .task: kind = "task"; detail = ""
            case .onClick: kind = "clk"; detail = ""
            case .onHover: kind = "hov"; detail = ""
            case .onPaste: kind = "pst"; detail = ""
            case .environment: kind = "env"; detail = ""
            case .actions(let scope): kind = "act"; detail = "(\(scope.boundActions.count))"
            }
            style = node.isDirty ? dirtyStyle : dimStyle

        case .viewBody(let info):
            kind = info.viewTypeName
            detail = isCollapsed ? " …" : ""
            style = node.isDirty ? dirtyStyle : Style(foreground: .green, background: .ansi256(236), bold: false, italic: false, underline: false)
        }

        let line: String
        if detail.isEmpty {
            line = "\(indent)\(collapsePrefix)\(kind)"
        } else {
            line = "\(indent)\(collapsePrefix)\(kind) \(detail)"
        }

        writeLine(line, into: &buffer, x: panelX, y: y, width: panelWidth, style: style)
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

/// Release stub — the panel has no modes outside DEBUG builds.
public enum DebugPanelMode { case hidden }
public final class DebugPanel: Sendable {
    public var mode: DebugPanelMode { .hidden }
    public init() {}
    @inline(__always) public func toggle() {}
    @inline(__always) public func recordFrameTime(_ ms: Double) {}
    @inline(__always) public func recordInput(_ description: String, timestamp: Double) {}
    @inline(__always) public func render(into buffer: inout CellBuffer, graph: AttributeGraph?, stats: FrameStats) {}
    @inline(__always) public func markGraphDirty() {}
}

#endif
