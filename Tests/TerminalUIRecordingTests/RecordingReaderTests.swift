import Testing
import TerminalUI
import TerminalUIConfig
@testable import TerminalUIRecording

/// A log from JSON lines, the shape a recorder writes.
func reader(_ lines: [String]) throws -> RecordingReader {
    try RecordingReader(bytes: Array((lines.joined(separator: "\n") + "\n").utf8))
}

let header4x2 = #"{"tuirec":1,"cols":4,"rows":2,"cursor":"hidden","app":"demo","env":{"TERM":"xterm-256color","COLORTERM":"truecolor"}}"#

// What a renderer needs from a log: its frames and when they were drawn,
// its marks and the frame each one shows, its resizes, its end, and the
// screen after every frame as the framework's own cells.

@Suite("Reading a recording for rendering")
struct RecordingReaderTests {

    private static let session = [
        header4x2,
        #"{"style":0,"fg":null,"bg":null}"#,
        #"{"style":1,"fg":"rgb:cba6f7","bg":"idx:236","bold":true}"#,
        #"{"t":0,"frame":3,"windowBg":"rgb:1e1e2e","rows":[[0,[[1,"ab"],[0,"  "]]],[1,[[0,"    "]]]]}"#,
        #"{"t":1200,"mark":"start","hold":400}"#,
        #"{"t":5000,"frame":4,"rows":[[0,[[1,"ac"],[0,"  "]]]]}"#,
        #"{"t":9000,"mark":"live"}"#,
        #"{"t":9100,"resize":[5,2]}"#,
        #"{"t":9100,"frame":5,"rows":[[0,[[0,"     "]]],[1,[[1,"x"],[0,"    "]]]]}"#,
        #"{"t":12000,"end":true,"frames":3,"marks":2}"#,
    ]

    @Test func framesMarksResizesAndTheEndAreRead() throws {
        let log = try reader(Self.session)
        #expect(log.header.cols == 4 && log.header.app == "demo")
        #expect(log.frames == [.init(time: 0, number: 3), .init(time: 5000, number: 4), .init(time: 9100, number: 5)])
        #expect(log.marks == [
            .init(time: 1200, label: "start", holdMs: 400, framesBefore: 1),
            .init(time: 9000, label: "live", holdMs: nil, framesBefore: 2),
        ])
        #expect(log.marks.map(\.currentFrame) == [0, 1])
        #expect(log.resizes == [.init(time: 9100, cols: 5, rows: 2)])
        #expect(log.endTime == 12000)
        #expect(try log.markIndex(labelled: "live") == 1)
        #expect(throws: RecordingLogError("the log has no mark nowhere")) { try log.markIndex(labelled: "nowhere") }
    }

    @Test func aLogCutShortEndsAtItsLastLine() throws {
        let log = try reader(Array(Self.session.dropLast()))
        #expect(log.endTime == 9100)
    }

    @Test func aColourNoPaletteKnowsIsRefusedWithItsLine() {
        #expect(throws: RecordingLogError(line: 2, "style 0 names a colour no palette knows")) {
            try reader([header4x2, #"{"style":0,"fg":"purple","bg":null}"#,
                        #"{"t":0,"frame":1,"rows":[]}"#])
        }
        #expect(throws: RecordingLogError(line: 2, "windowBg is a colour no palette knows: rgb:1E1E2E")) {
            try reader([header4x2, #"{"t":0,"frame":1,"windowBg":"rgb:1E1E2E","rows":[]}"#])
        }
    }

    @Test func aLogWithoutAFrameIsRefused() {
        #expect(throws: RecordingLogError("the log holds no frame")) { try reader([header4x2]) }
        #expect(throws: RecordingLogError("the log has no header")) {
            try reader([#"{"t":0,"frame":1,"rows":[]}"#])
        }
    }

    @Test func eachScreenIsABufferInTheRecordedStyles() throws {
        let screens = Array(try reader(Self.session).screens)
        #expect(screens.map(\.index) == [0, 1, 2])

        let accent = Style(foreground: .rgb(0xCB, 0xA6, 0xF7), background: .ansi256(236),
                           bold: true, italic: false, underline: false)
        var expected = CellBuffer(width: 4, height: 2)
        expected.write("ac", x: 0, y: 0, style: accent)
        #expect(screens[1].buffer.cells == expected.cells)
        #expect(screens[1].windowBackground == .rgb(0x1E, 0x1E, 0x2E))

        // A resize blanks the screen; the frame after it draws it all.
        let resized = screens[2].buffer
        #expect(resized.width == 5 && resized.height == 2)
        #expect(resized[0, 1] == Cell(character: "x", style: accent))
    }

    @Test func aWideGlyphIsRebuiltWholeWithItsContinuation() throws {
        // The recorder keeps the continuation as the space the buffer
        // holds there; written back as a space, it would split the glyph.
        let log = try reader([header4x2, #"{"style":0,"fg":null,"bg":null}"#,
                              #"{"t":0,"frame":1,"rows":[[0,[[0,"界 a "]]],[1,[[0,"   界"]]]]}"#])
        let buffer = try #require(Array(log.screens).first).buffer
        var expected = CellBuffer(width: 4, height: 2)
        expected.write("界a", x: 0, y: 0, style: .plain)
        // A wide glyph in the last column cannot be drawn, so the buffer
        // holds a space there, as it did when the app drew it.
        expected.write("界", x: 3, y: 1, style: .plain)
        #expect(buffer.cells == expected.cells)
        #expect(buffer[1, 0].isContinuation)
    }

    @Test func everyColourSpellsAndReadsBackAsItself() {
        var colours: [Color] = Color.recordedNames.map(\.color)
        colours += (0...255).map { Color.ansi256(UInt8($0)) }
        colours += [.rgb(0, 0, 0), .rgb(0xCB, 0xA6, 0xF7), .rgb(255, 255, 255)]
        for colour in colours {
            let spelling = colour.recordedSpelling
            #expect(spelling.flatMap(Color.init(recordedSpelling:)) == colour, "\(colour) as \(spelling ?? "nil")")
        }
        #expect(Color.default.recordedSpelling == nil)
        for spelling in ["purple", "idx:256", "idx:01", "idx:+1", "idx:", "rgb:CBA6F7", "rgb:cba6f", "rgb:cba6f7a", "Red"] {
            #expect(Color(recordedSpelling: spelling) == nil, "\(spelling)")
        }
    }
}
