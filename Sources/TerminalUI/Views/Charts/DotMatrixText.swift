/// Renders a short string as large dot-matrix display characters —
/// airport-departure-board / LED-marquee lettering.
///
/// Each character comes from the shared 5x7 ``DotFont`` and scales up to
/// display size in one of two ways: `.bullet` (the default) spends one
/// terminal cell per dot (`●`), giving big 7-row letters; `.braille`
/// packs the same dots into braille glyphs at 2x4 dots per cell, giving
/// compact 2-row letters. Glyph geometry is fixed — the view opts out of
/// wrapping, so give it room or it clips. This is a display element for
/// banners and splash headers; for ordinary text use ``Text``, and for a
/// scrolling animated strip see ``MorseTicker``.
///
/// ```swift
/// DotMatrixText("HELLO", mode: .braille)
///     .foreground(.cyan)
///
/// DotMatrixText("STATUS: ON", mode: .bullet(dot: "●", empty: " "))
///     .foreground(.rgb(218, 218, 214))
/// ```
public struct DotMatrixText: TerminalView {
    /// The string to render; characters outside ``DotFont``'s ASCII
    /// coverage fall back to the `?` glyph.
    public let text: String
    /// Braille (compact) or bullet (large) rendering.
    public let mode: RenderMode
    /// Dot columns of blank space between letters.
    public let letterGap: Int

    /// How dots become terminal glyphs.
    public enum RenderMode: Sendable {
        /// Compact braille rendering — 2x4 dots per terminal cell
        case braille
        /// Bullet character rendering — one dot per cell, customizable characters
        case bullet(dot: String, empty: String)

        /// `.bullet` with `●` dots and space gaps.
        public static let `default`: RenderMode = .bullet(dot: "\u{25CF}", empty: " ")
    }

    /// Creates a dot-matrix text display.
    ///
    /// - Parameters:
    ///   - text: String to render in dot-matrix glyphs.
    ///   - mode: Rendering mode (default `.bullet` with `●`).
    ///   - letterGap: Blank dot columns between letters (default 1).
    public init(_ text: String, mode: RenderMode = .default, letterGap: Int = 1) {
        self.text = text
        self.mode = mode
        self.letterGap = letterGap
    }

    public var body: some TerminalView {
        // `.wrap(.none)` — dot-matrix glyphs are fixed geometry (7 rows ×
        // N columns). Without this the measurer would inflate height when
        // the container is narrower than the glyph row width, starving
        // Spacer siblings and collapsing the visible output to one row.
        // Group wraps both branches in a single transparent container so the
        // modifier applies once.
        Group {
            switch mode {
            case .braille:
                Text(renderBraille())
            case .bullet(let dot, let empty):
                Text(renderBullet(dot: dot, empty: empty))
            }
        }
        .wrap(.none)
    }

    // MARK: - Braille Rendering

    private func renderBraille() -> String {
        var matrix: [[Bool]] = Array(
            repeating: [],
            count: DotFont.glyphHeight
        )

        for char in text {
            let glyph = DotFont.glyph(for: char)
            for row in 0..<DotFont.glyphHeight {
                for cell in glyph[row] {
                    matrix[row].append(cell == "#")
                }
                // Letter gap
                for _ in 0..<letterGap {
                    matrix[row].append(false)
                }
            }
        }

        let width = matrix.map(\.count).max() ?? 0
        var lines: [String] = []

        // Process 4 rows at a time for braille
        var rowBlock = 0
        while rowBlock < DotFont.glyphHeight {
            var line = ""
            var col = 0
            while col < width {
                line.append(brailleChar(matrix: matrix, rowBlock: rowBlock, col: col))
                col += 2
            }
            lines.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
            rowBlock += 4
        }

        return lines.joined(separator: "\n")
    }

    private func brailleChar(matrix: [[Bool]], rowBlock: Int, col: Int) -> Character {
        let masks: [(dy: Int, dx: Int, bit: UInt8)] = [
            (0, 0, 0x01), (0, 1, 0x08),
            (1, 0, 0x02), (1, 1, 0x10),
            (2, 0, 0x04), (2, 1, 0x20),
            (3, 0, 0x40), (3, 1, 0x80),
        ]
        var code: UInt8 = 0
        for (dy, dx, bit) in masks {
            let r = rowBlock + dy
            let c = col + dx
            if r < matrix.count && c < matrix[r].count && matrix[r][c] {
                code |= bit
            }
        }
        return Character(Unicode.Scalar(0x2800 + UInt32(code))!)
    }

    // MARK: - Bullet Rendering

    private func renderBullet(dot: String, empty: String) -> String {
        var lines: [String] = []

        for row in 0..<DotFont.glyphHeight {
            var line = ""
            for (i, char) in text.enumerated() {
                let glyph = DotFont.glyph(for: char)
                for cell in glyph[row] {
                    line += cell == "#" ? dot : empty
                }
                if i < text.count - 1 {
                    line += String(repeating: empty, count: letterGap)
                }
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}
