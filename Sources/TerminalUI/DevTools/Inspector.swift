#if DEBUG

/// In-app inspector — crosshair cursor that shows node info for any cell.
/// Toggled by the `toggle_inspector` binding, F3 by default. Arrow keys move
/// the crosshair.
/// Shows: node type, declared values, resolved rect, modifier chain.
public final class Inspector {
    /// Whether the overlay renders; toggled by the inspector keybinding.
    public var active: Bool = false
    /// Crosshair column, 0-based.
    public var cursorX: Int = 0
    /// Crosshair row, 0-based.
    public var cursorY: Int = 0

    /// Creates an inactive inspector with the crosshair at the origin.
    public init() {}

    /// Flips ``active`` — show or hide the overlay.
    public func toggle() {
        active = !active
    }

    /// Moves the crosshair by (`dx`, `dy`) cells, clamped inside
    /// `0..<maxX` x `0..<maxY`.
    public func moveCursor(dx: Int, dy: Int, maxX: Int, maxY: Int) {
        cursorX = max(0, min(maxX - 1, cursorX + dx))
        cursorY = max(0, min(maxY - 1, cursorY + dy))
    }

    /// Render the inspector overlay into the buffer.
    /// Highlights the cell under the crosshair and draws info panel at the bottom.
    public func render(into buffer: inout CellBuffer, graph: AttributeGraph?) {
        guard active else { return }

        // Crosshair — highlight the cell under cursor
        if cursorX < buffer.width, cursorY < buffer.height {
            var cell = buffer[cursorX, cursorY]
            cell.style.background = .cyan
            cell.style.foreground = .black
            buffer[cursorX, cursorY] = cell

            // Crosshair lines — always on top, no exceptions
            let crossBg = Color.ansi256(236)
            for x in 0..<buffer.width where x != cursorX {
                var c = buffer[x, cursorY]
                c.style.background = crossBg
                buffer[x, cursorY] = c
            }
            for y in 0..<buffer.height where y != cursorY {
                var c = buffer[cursorX, y]
                c.style.background = crossBg
                buffer[cursorX, y] = c
            }
        }

        // Hit test to find the node
        let result = HitTest.nodeAt(x: cursorX, y: cursorY, root: graph?.root)

        // Info panel — 3 lines at the bottom
        let panelY = buffer.height - 3
        guard panelY > 0 else { return }

        let bgStyle = Style(foreground: .white, background: .ansi256(234), bold: false, italic: false, underline: false)
        let labelStyle = Style(foreground: .cyan, background: .ansi256(234), bold: true, italic: false, underline: false)
        let valueStyle = Style(foreground: .white, background: .ansi256(234), bold: false, italic: false, underline: false)
        let dimStyle = Style(foreground: .gray, background: .ansi256(234), bold: false, italic: false, underline: false)

        // Clear panel area
        for y in panelY..<buffer.height {
            for x in 0..<buffer.width {
                buffer[x, y] = Cell(character: " ", style: bgStyle)
            }
        }

        if let result {
            let r = result.resolvedRect
            let declared = result.declaredValues
            let chain = result.modifierChain

            // Line 1: node type + position
            let typeName = declared.first(where: { $0.0 == "type" || $0.0 == "modifier" })?.1 ?? "?"
            let line1 = " \(typeName)  rect:(\(r.x),\(r.y) \(r.width)x\(r.height))  cursor:(\(cursorX),\(cursorY))"
            writeInspectorLine(line1, into: &buffer, y: panelY, labelEnd: typeName.count + 1, labelStyle: labelStyle, valueStyle: valueStyle)

            // Line 2: declared values
            let vals = declared.filter { $0.0 != "type" && $0.0 != "modifier" }
                .map { "\($0.0):\($0.1)" }
                .joined(separator: "  ")
            let line2 = vals.isEmpty ? " (no properties)" : " \(vals)"
            writeInspectorLine(line2, into: &buffer, y: panelY + 1, labelEnd: 0, labelStyle: dimStyle, valueStyle: dimStyle)

            // Line 3: modifier chain
            let chainStr = chain.isEmpty ? "(none)" : chain.joined(separator: " → ")
            let line3 = " chain: \(chainStr)"
            writeInspectorLine(line3, into: &buffer, y: panelY + 2, labelEnd: 7, labelStyle: labelStyle, valueStyle: dimStyle)

            // Highlight the inspected node's bounds
            highlightRect(x: r.x, y: r.y, width: r.width, height: r.height, in: &buffer)
        } else {
            writeInspectorLine(" (no node at cursor)", into: &buffer, y: panelY, labelEnd: 0, labelStyle: dimStyle, valueStyle: dimStyle)
            writeInspectorLine(" cursor:(\(cursorX),\(cursorY))", into: &buffer, y: panelY + 1, labelEnd: 0, labelStyle: dimStyle, valueStyle: dimStyle)
            writeInspectorLine("", into: &buffer, y: panelY + 2, labelEnd: 0, labelStyle: dimStyle, valueStyle: dimStyle)
        }
    }

    func writeInspectorLine(_ text: String, into buffer: inout CellBuffer, y: Int, labelEnd: Int, labelStyle: Style, valueStyle: Style) {
        guard y >= 0, y < buffer.height else { return }
        var col = 0
        for (i, char) in text.enumerated() {
            guard col < buffer.width else { break }
            let style = i < labelEnd ? labelStyle : valueStyle
            buffer[col, y] = Cell(character: char, style: style)
            col += 1
        }
    }

    func highlightRect(x: Int, y: Int, width: Int, height: Int, in buffer: inout CellBuffer) {
        let highlightColor = Color.ansi256(24) // dark blue tint

        // Top and bottom edges
        for col in x..<min(x + width, buffer.width) {
            if y >= 0, y < buffer.height {
                buffer[col, y].style.background = highlightColor
            }
            let bottomY = y + height - 1
            if bottomY >= 0, bottomY < buffer.height, bottomY != y {
                buffer[col, bottomY].style.background = highlightColor
            }
        }
        // Left and right edges
        for row in y..<min(y + height, buffer.height) {
            if x >= 0, x < buffer.width {
                buffer[x, row].style.background = highlightColor
            }
            let rightX = x + width - 1
            if rightX >= 0, rightX < buffer.width, rightX != x {
                buffer[rightX, row].style.background = highlightColor
            }
        }
    }
}

#else

/// Release stub — every member is an erased no-op.
public final class Inspector: Sendable {
    /// Creates the inert stub.
    public init() {}
    /// No-op in release builds.
    @inline(__always) public func toggle() {}
    /// No-op in release builds.
    @inline(__always) public func moveCursor(dx: Int, dy: Int, maxX: Int, maxY: Int) {}
    /// No-op in release builds.
    @inline(__always) public func render(into buffer: inout CellBuffer, graph: AttributeGraph?) {}
    /// Always `false` in release builds.
    public var active: Bool { false }
}

#endif
