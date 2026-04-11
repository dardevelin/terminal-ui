public struct Style: Equatable, Sendable {
    public var foreground: Color?
    public var background: Color?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool

    public static let plain = Style(foreground: nil, background: nil, bold: false, italic: false, underline: false)
}

public struct Cell: Equatable, Sendable {
    public var character: Character
    public var style: Style

    public static let empty = Cell(character: " ", style: .plain)
}

// Make Color equatable for Cell diffing
extension Color: Equatable {
    public static func == (lhs: Color, rhs: Color) -> Bool {
        switch (lhs, rhs) {
        case (.default, .default),
             (.black, .black),
             (.red, .red),
             (.green, .green),
             (.yellow, .yellow),
             (.blue, .blue),
             (.magenta, .magenta),
             (.cyan, .cyan),
             (.white, .white),
             (.gray, .gray),
             (.brightRed, .brightRed),
             (.brightGreen, .brightGreen),
             (.brightYellow, .brightYellow),
             (.brightBlue, .brightBlue),
             (.brightMagenta, .brightMagenta),
             (.brightCyan, .brightCyan),
             (.brightWhite, .brightWhite):
            true
        case (.ansi256(let a), .ansi256(let b)):
            a == b
        case (.rgb(let r1, let g1, let b1), .rgb(let r2, let g2, let b2)):
            r1 == r2 && g1 == g2 && b1 == b2
        default:
            false
        }
    }
}

public struct CellBuffer: Sendable {
    public var width: Int
    public var height: Int
    public var cells: [Cell]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.cells = Array(repeating: .empty, count: width * height)
    }

    public subscript(x: Int, y: Int) -> Cell {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return .empty }
            return cells[y * width + x]
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            cells[y * width + x] = newValue
        }
    }

    public mutating func write(_ text: String, x: Int, y: Int, style: Style) {
        var col = x
        for char in text {
            guard col < width else { break }
            self[col, y] = Cell(character: char, style: style)
            col += 1
        }
    }

    public mutating func fill(_ rect: Rect, character: Character = " ", style: Style = .plain) {
        for row in rect.y..<min(rect.y + rect.height, height) {
            for col in rect.x..<min(rect.x + rect.width, width) {
                self[col, row] = Cell(character: character, style: style)
            }
        }
    }

    // Returns ANSI diff against previous buffer
    /// Count how many cells differ from previous buffer.
    public func countDiff(from previous: CellBuffer?) -> Int {
        guard let previous, previous.width == width, previous.height == height else {
            return width * height
        }
        var count = 0
        for i in 0..<cells.count {
            if cells[i] != previous.cells[i] { count += 1 }
        }
        return count
    }

    public func diff(from previous: CellBuffer?) -> String {
        guard let previous, previous.width == width, previous.height == height else {
            return fullRender()
        }

        var output = ""
        var lastStyle = Style.plain

        for y in 0..<height {
            for x in 0..<width {
                let cell = self[x, y]
                let prev = previous[x, y]
                if cell != prev {
                    output += "\u{1B}[\(y + 1);\(x + 1)H"
                    if cell.style != lastStyle {
                        output += styleToAnsi(cell.style)
                        lastStyle = cell.style
                    }
                    output += String(cell.character)
                }
            }
        }

        output += "\u{1B}[0m"
        return output
    }

    // MARK: - Direct byte buffer rendering

    /// Render full frame into an OutputBuffer — zero String allocation
    public func renderFull(into out: inout OutputBuffer) {
        out.reset()
        out.writeCSI()
        out.write(0x48) // 'H' — cursor home

        var lastStyle = Style.plain
        for y in 0..<height {
            for x in 0..<width {
                let cell = self[x, y]
                if cell.style != lastStyle {
                    out.writeStyle(cell.style)
                    lastStyle = cell.style
                }
                out.writeCharacter(cell.character)
            }
            if y < height - 1 {
                out.write(0x0D) // \r
                out.write(0x0A) // \n
            }
        }
        out.writeReset()
    }

    /// Render diff into an OutputBuffer — only changed cells.
    /// Coalesces adjacent changes on the same row into a single cursor move + run.
    public func renderDiff(from previous: CellBuffer?, into out: inout OutputBuffer) {
        out.reset()
        guard let previous, previous.width == width, previous.height == height else {
            renderFull(into: &out)
            return
        }

        var lastStyle = Style.plain
        var cursorRow = -1
        var cursorCol = -1

        for y in 0..<height {
            var x = 0
            while x < width {
                let cell = self[x, y]
                let prev = previous[x, y]

                if cell == prev {
                    x += 1
                    continue
                }

                // Found a changed cell. Position cursor if not already there.
                if cursorRow != y || cursorCol != x {
                    out.writeCursorPosition(row: y + 1, col: x + 1)
                }

                // Write this cell and any consecutive changed cells
                while x < width {
                    let c = self[x, y]
                    let p = previous[x, y]

                    // Stop the run if we hit an unchanged cell
                    // BUT: if the gap to the next changed cell is small (< 4),
                    // it's cheaper to overwrite than to emit a new cursor position
                    if c == p {
                        // Look ahead for nearby changes
                        var nextDirty = x + 1
                        while nextDirty < min(x + 4, width) {
                            if self[nextDirty, y] != previous[nextDirty, y] { break }
                            nextDirty += 1
                        }
                        if nextDirty < x + 4 && nextDirty < width && self[nextDirty, y] != previous[nextDirty, y] {
                            // Small gap — cheaper to overwrite than reposition
                        } else {
                            break
                        }
                    }

                    let current = self[x, y]
                    if current.style != lastStyle {
                        out.writeStyle(current.style)
                        lastStyle = current.style
                    }
                    out.writeCharacter(current.character)
                    x += 1
                }

                cursorRow = y
                cursorCol = x
            }
        }
        out.writeReset()
    }

    // MARK: - Legacy String-based rendering (kept for TerminalApp.print)

    func fullRender() -> String {
        var output = "\u{1B}[H" // cursor home
        var lastStyle = Style.plain

        for y in 0..<height {
            for x in 0..<width {
                let cell = self[x, y]
                if cell.style != lastStyle {
                    output += styleToAnsi(cell.style)
                    lastStyle = cell.style
                }
                output += String(cell.character)
            }
            if y < height - 1 {
                output += "\r\n"
            }
        }

        output += "\u{1B}[0m"
        return output
    }

    func styleToAnsi(_ style: Style) -> String {
        var codes = "\u{1B}[0m"
        if let fg = style.foreground {
            codes += fg.foregroundCode
        }
        if let bg = style.background {
            codes += bg.backgroundCode
        }
        if style.bold { codes += "\u{1B}[1m" }
        if style.italic { codes += "\u{1B}[3m" }
        if style.underline { codes += "\u{1B}[4m" }
        return codes
    }
}
