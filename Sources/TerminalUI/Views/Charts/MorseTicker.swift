/// A scrolling dot-matrix ticker that renders text as Morse code patterns.
///
/// Dots flow continuously from right to left like a telegraph tape,
/// wrapping around so the message loops. Each character is drawn in the
/// 5x7 ``DotFont`` and packed into braille glyphs (2x4 dots per cell),
/// so the whole strip is exactly 2 terminal rows tall. Dots are colored
/// by their Morse encoding: one color for dots (·), another for dashes
/// (—), and dimmed for structural dots that aren't part of the Morse
/// signal. Purely decorative — a marquee for splash screens and demos;
/// for static display lettering use ``DotMatrixText``.
///
/// The ticker doesn't animate itself: the scroll offset is app state,
/// advanced externally (same externally-driven pattern as ``Spinner``),
/// which keeps the animation in step with the render loop.
///
/// ```swift
/// @TerminalState var offset = 0
///
/// MorseTicker(
///     "HELLO WORLD",
///     scrollOffset: $offset,
///     width: 60,
///     dotColor: .rgb(218, 218, 214),
///     dashColor: .red
/// )
/// ```
///
/// Drive the scroll with a timer:
/// ```
/// static var timers: [TerminalTimer] {[
///     TerminalTimer("ticker", every: .milliseconds(80))
/// ]}
/// // In onEvent: case .timer("ticker"): offset += 1
/// ```
public struct MorseTicker: TerminalView {
    /// Message to scroll. Letters and digits carry Morse coloring;
    /// other glyphs render in `dimColor`.
    public let text: String
    /// Scroll position in dot columns; advance to animate. Wraps
    /// automatically, so a monotonically increasing counter is fine.
    public let scrollBinding: Binding<Int>
    /// Viewport width in terminal cells (braille = width*2 dot columns).
    public let width: Int
    /// Always 2 terminal rows (7 dot rows packed into braille).
    public let height: Int
    /// Color for dots (·) in the Morse encoding.
    public let dotColor: Color
    /// Color for dashes (—) in the Morse encoding.
    public let dashColor: Color
    /// Color for structural dots outside the Morse signal.
    public let dimColor: Color
    /// Background fill behind the strip.
    public let bgColor: Color

    /// Width of the ticker in terminal cells (braille = width*2 dot columns).
    /// Height is always 2 terminal rows (7 dot rows → 2 braille rows of 4 dots each).
    public init(
        _ text: String,
        scrollOffset: Binding<Int>,
        width: Int = 60,
        dotColor: Color = .rgb(218, 218, 214),
        dashColor: Color = .red,
        dimColor: Color = .ansi256(240),
        bgColor: Color = .rgb(23, 24, 26)
    ) {
        self.text = text
        self.scrollBinding = scrollOffset
        self.width = width
        self.height = 2 // 7 dot rows → 2 braille rows (8 dots, top 7 used)
        self.dotColor = dotColor
        self.dashColor = dashColor
        self.dimColor = dimColor
        self.bgColor = bgColor
    }

    public var body: some TerminalView {
        let offset = scrollBinding.get()
        let spans = renderTicker(offset: offset)
        // `.wrap(.none)` — MorseTicker is fixed-height (2 braille rows) with
        // explicit `width`. Without it the measurer would inflate the row
        // count at narrow container widths and the parent VStack would over-
        // allocate vertical space, starving downstream siblings.
        Text(spans: spans)
            .background(bgColor)
            .wrap(.none)
    }

    // MARK: - Morse Table

    private static let morseTable: [Character: String] = [
        "A": ".-",    "B": "-...",  "C": "-.-.",  "D": "-..",
        "E": ".",     "F": "..-.",  "G": "--.",   "H": "....",
        "I": "..",    "J": ".---",  "K": "-.-",   "L": ".-..",
        "M": "--",    "N": "-.",    "O": "---",   "P": ".--.",
        "Q": "--.-",  "R": ".-.",   "S": "...",   "T": "-",
        "U": "..-",   "V": "...-",  "W": ".--",   "X": "-..-",
        "Y": "-.--",  "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--",
        "4": "....-", "5": ".....", "6": "-....", "7": "--...",
        "8": "---..", "9": "----.",
    ]

    // MARK: - Pixel Buffer

    /// Each pixel has a type determining its color.
    private enum DotType {
        case off         // empty
        case dot         // Morse dot (·) — dotColor
        case dash        // Morse dash (—) — dashColor
        case structure   // glyph dot not in current Morse symbol — dimColor
    }

    /// Build the full pixel strip for the text, then window into it.
    private func renderTicker(offset: Int) -> [TextSpan] {
        // Build the full dot-matrix strip with Morse coloring
        let strip = buildStrip()
        let stripWidth = strip.isEmpty ? 0 : strip[0].count
        let dotWidth = width * 2 // braille cells = 2 dot columns each

        // Window: scroll offset determines which slice is visible
        // Wrap around for continuous scrolling
        var spans: [TextSpan] = []

        for rowBlock in stride(from: 0, to: DotFont.glyphHeight, by: 4) {
            if rowBlock > 0 {
                spans.append(TextSpan("\n"))
            }

            for col in 0..<(dotWidth / 2) {
                let dotCol = col * 2
                // Sample 2 columns x 4 rows for one braille character
                var code: UInt8 = 0
                var colors: [DotType] = []

                let brailleMasks: [(dy: Int, dx: Int, bit: UInt8)] = [
                    (0, 0, 0x01), (0, 1, 0x08),
                    (1, 0, 0x02), (1, 1, 0x10),
                    (2, 0, 0x04), (2, 1, 0x20),
                    (3, 0, 0x40), (3, 1, 0x80),
                ]

                for (dy, dx, bit) in brailleMasks {
                    let r = rowBlock + dy
                    let c = (offset + dotCol + dx) % max(stripWidth, 1)
                    if r < strip.count && c < strip[r].count {
                        let dt = strip[r][c]
                        if dt != .off {
                            code |= bit
                            colors.append(dt)
                        }
                    }
                }

                let ch = Character(Unicode.Scalar(0x2800 + UInt32(code))!)

                // Determine dominant color for this cell
                let color: Color
                if colors.isEmpty {
                    color = dimColor
                } else if colors.contains(where: { $0 == .dash }) {
                    color = dashColor
                } else if colors.contains(where: { $0 == .dot }) {
                    color = dotColor
                } else {
                    color = dimColor
                }

                spans.append(TextSpan(String(ch), foreground: color))
            }
        }

        return spans
    }

    /// Build the full pixel strip — all characters rendered as dot-matrix
    /// with Morse color coding applied.
    private func buildStrip() -> [[DotType]] {
        let letterGap = 2 // dot columns between letters
        let wordGap = 6   // dot columns for space

        var strip: [[DotType]] = Array(
            repeating: [],
            count: DotFont.glyphHeight
        )

        for char in text.uppercased() {
            if char == " " {
                for row in 0..<DotFont.glyphHeight {
                    for _ in 0..<wordGap {
                        strip[row].append(.off)
                    }
                }
                continue
            }

            let glyph = DotFont.glyph(for: char)
            let morse = Self.morseTable[char]

            // Determine if this character's dots should be colored as dot or dash
            // Use alternating Morse symbols across the glyph columns
            let morseSymbols: [DotType] = {
                guard let m = morse else { return [] }
                return m.map { $0 == "." ? DotType.dot : DotType.dash }
            }()

            let glyphW = glyph[0].count

            for row in 0..<DotFont.glyphHeight {
                for (col, cell) in glyph[row].enumerated() {
                    if cell == "#" {
                        // Map column position to a Morse symbol
                        if morseSymbols.isEmpty {
                            strip[row].append(.structure)
                        } else {
                            // Distribute Morse symbols across glyph width
                            let symbolIdx = col * morseSymbols.count / max(glyphW, 1)
                            let clampedIdx = min(symbolIdx, morseSymbols.count - 1)
                            strip[row].append(morseSymbols[clampedIdx])
                        }
                    } else {
                        strip[row].append(.off)
                    }
                }
            }

            // Letter gap
            for row in 0..<DotFont.glyphHeight {
                for _ in 0..<letterGap {
                    strip[row].append(.off)
                }
            }
        }

        // Add padding at the end so the text scrolls fully off screen
        let padding = width * 2
        for row in 0..<DotFont.glyphHeight {
            for _ in 0..<padding {
                strip[row].append(.off)
            }
        }

        return strip
    }
}
