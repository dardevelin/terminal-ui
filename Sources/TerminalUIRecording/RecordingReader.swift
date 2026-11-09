import TerminalUI
import TerminalUIConfig

/// A `.tuirec` log read for rendering: its frames with their times, its
/// marks with their holds and the frame each one shows, and the screen after
/// every frame as the framework's own types — a ``CellBuffer`` in the
/// recorded styles, and the window's background as a ``Color``.
///
/// Every colour spelling in the log is checked here, once, so a renderer
/// working from a reader never meets one it cannot draw.
package struct RecordingReader: Sendable {
    /// A frame the log holds, in log order.
    package struct Frame: Equatable, Sendable {
        /// Microseconds since the recording started.
        package var time: Int
        /// The runtime's frame counter.
        package var number: Int
    }

    /// A named moment.
    package struct Mark: Equatable, Sendable {
        /// Microseconds since the recording started.
        package var time: Int
        package var label: String
        /// How long a picture shows the screen as it is at the mark; nil
        /// for a live mark, whose segment plays as it was recorded.
        package var holdMs: Int?
        /// How many frames the log holds before the mark: the frames from
        /// this index on were drawn after it.
        package var framesBefore: Int

        /// The index of the frame showing when the mark was made: the last
        /// drawn before it, or the first frame for a mark made before any.
        package var currentFrame: Int { max(framesBefore - 1, 0) }
    }

    /// A change of the screen's size.
    package struct Resize: Equatable, Sendable {
        package var time: Int
        package var cols: Int
        package var rows: Int
    }

    package let header: RecordingHeader
    package let lines: [RecordingLine]
    package let frames: [Frame]
    package let marks: [Mark]
    package let resizes: [Resize]
    /// When the recording ended: its `end` line, or, for a log cut short —
    /// an app that crashed — its last frame or mark.
    package let endTime: Int

    package init(bytes: some Collection<UInt8>) throws(RecordingLogError) {
        try self.init(lines: try RecordingLogReader.lines(in: bytes))
    }

    package init(lines: [RecordingLine]) throws(RecordingLogError) {
        guard case .header(let header) = lines.first else { throw RecordingLogError("the log has no header") }
        var frames: [Frame] = []
        var marks: [Mark] = []
        var resizes: [Resize] = []
        var endTime: Int?
        var lastTime = 0
        for (offset, line) in lines.enumerated().dropFirst() {
            let lineNumber = offset + 1
            switch line {
            case .header:
                throw RecordingLogError(line: lineNumber, "a second header")
            case .style(let id, let style):
                guard Style(recorded: style) != nil else {
                    throw RecordingLogError(line: lineNumber, "style \(id) names a colour no palette knows")
                }
            case .frame(let frame):
                if case .some(.some(let spelling)) = frame.windowBackground, Color(recordedSpelling: spelling) == nil {
                    throw RecordingLogError(line: lineNumber, "windowBg is a colour no palette knows: \(spelling)")
                }
                frames.append(Frame(time: frame.time, number: frame.number))
                lastTime = frame.time
            case .mark(let time, let label, let holdMs):
                if let holdMs, holdMs < 0 { throw RecordingLogError(line: lineNumber, "a hold is not negative") }
                marks.append(Mark(time: time, label: label, holdMs: holdMs, framesBefore: frames.count))
                lastTime = time
            case .resize(let time, let cols, let rows):
                resizes.append(Resize(time: time, cols: cols, rows: rows))
                lastTime = time
            case .end(let time, _, _):
                endTime = time
            }
        }
        guard !frames.isEmpty else { throw RecordingLogError("the log holds no frame") }
        self.header = header
        self.lines = lines
        self.frames = frames
        self.marks = marks
        self.resizes = resizes
        self.endTime = endTime ?? lastTime
    }

    /// The index in ``marks`` of the first mark with this label.
    package func markIndex(labelled label: String) throws(RecordingLogError) -> Int {
        guard let index = marks.firstIndex(where: { $0.label == label }) else {
            throw RecordingLogError("the log has no mark \(label)")
        }
        return index
    }

    /// The screen after each frame, in order.
    package var screens: Screens { Screens(lines: lines, header: header) }
}

extension RecordingReader {
    /// The screen as one frame left it.
    package struct Screen: Sendable {
        /// The frame's index in ``RecordingReader/frames``.
        package var index: Int
        package var screen: RecordingScreen

        /// The screen as a buffer the framework could have drawn, every
        /// cell in its recorded style; a double-width glyph and its
        /// continuation as the buffer makes them.
        package var buffer: CellBuffer {
            var buffer = CellBuffer(width: screen.cells.first?.count ?? 0, height: screen.cells.count)
            let styles = screen.styles.mapValues { Style(recorded: $0) ?? .plain }
            for (y, row) in screen.cells.enumerated() {
                var x = 0
                while x < row.count {
                    let cell = row[x]
                    let style = cell.style.flatMap { styles[$0] } ?? .plain
                    buffer[x, y] = Cell(character: cell.character, style: style)
                    // The log keeps a wide glyph's continuation as the space
                    // the buffer holds there; writing that space would
                    // split the glyph the buffer just made whole.
                    x += buffer[x + 1, y].isContinuation ? 2 : 1
                }
            }
            return buffer
        }

        /// The colour behind the whole terminal; nil is the terminal's own.
        package var windowBackground: Color? {
            screen.windowBackground.flatMap(Color.init(recordedSpelling:))
        }
    }

    /// Replays the log line by line, yielding the screen after each frame.
    package struct Screens: Sequence, Sendable {
        let lines: [RecordingLine]
        let header: RecordingHeader

        package struct Iterator: IteratorProtocol {
            var lines: ArraySlice<RecordingLine>
            var screen: RecordingScreen
            var index = 0

            package mutating func next() -> Screen? {
                while let line = lines.popFirst() {
                    screen.apply(line)
                    if case .frame = line {
                        defer { index += 1 }
                        return Screen(index: index, screen: screen)
                    }
                }
                return nil
            }
        }

        package func makeIterator() -> Iterator {
            Iterator(lines: lines.dropFirst(), screen: RecordingScreen(header: header))
        }
    }
}

extension Style {
    /// The style a log recorded, or nil where it names a colour no palette
    /// knows. `null` is the terminal's own colour, which a ``Style`` spells
    /// as nil.
    init?(recorded: RecordedStyle) {
        // `.some(nil)` is a spelling that names nothing.
        let foreground = recorded.foreground.map(Color.init(recordedSpelling:))
        let background = recorded.background.map(Color.init(recordedSpelling:))
        if foreground == .some(nil) || background == .some(nil) { return nil }
        self.init(foreground: foreground ?? nil, background: background ?? nil,
                  bold: recorded.bold, italic: recorded.italic, underline: recorded.underline)
    }
}
