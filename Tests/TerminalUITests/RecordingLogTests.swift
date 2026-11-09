import Testing
import TerminalUIConfig

// A `.tuirec` log is what every picture of the framework will be rendered
// from, on macOS and on Linux, so its bytes are pinned here: key order,
// integers, escaping, and the run encoding that keeps one character per
// cell even where adjacent cells would join into one grapheme.

@Suite("The recording log")
struct RecordingLogTests {

    private static let header = RecordingHeader(
        cols: 94, rows: 26, cursorVisible: false, app: "tasks20201",
        environment: [.init(name: "TERM", value: "xterm-256color"),
                      .init(name: "COLORTERM", value: "truecolor")])

    private static let everyLine: [RecordingLine] = [
        .header(header),
        .style(id: 0, RecordedStyle()),
        .style(id: 1, RecordedStyle(foreground: "rgb:cba6f7", bold: true)),
        .style(id: 2, RecordedStyle(foreground: "brightRed", background: "idx:236",
                                    italic: true, underline: true)),
        .frame(RecordedFrame(time: 0, number: 1, windowBackground: .some("rgb:1e1e2e"), rows: [
            RecordedRow(index: 0, styles: [1, 1, 1, 1, 1, 0, 0, 0, 0],
                        characters: Array("Tasks   …")),
        ])),
        .mark(time: 0, label: "start", holdMs: 2500),
        .frame(RecordedFrame(time: 41233, number: 7, windowBackground: nil, rows: [
            RecordedRow(index: 3, styles: [2, 2, 2], characters: Array("▸ ☐")),
        ])),
        .frame(RecordedFrame(time: 41300, number: 8, windowBackground: .some(nil), rows: [])),
        .mark(time: 50000, label: "live", holdMs: nil),
        .resize(time: 51200, cols: 100, rows: 30),
        .end(time: 90000, frames: 12, marks: 5),
    ]

    private func written(_ lines: [RecordingLine]) -> [UInt8] {
        var writer = RecordingLogWriter()
        for line in lines { writer.write(line) }
        return writer.takeBytes()
    }

    @Test func everyLineTypeReadsBackAsItWasWritten() throws {
        let bytes = written(Self.everyLine)
        #expect(try RecordingLogReader.lines(in: bytes) == Self.everyLine)
    }

    @Test func linesAreWrittenInTheDocumentedShape() {
        let text = String(decoding: written(Self.everyLine), as: UTF8.self)
        let expected = """
            {"tuirec":1,"cols":94,"rows":26,"cursor":"hidden","app":"tasks20201","env":{"TERM":"xterm-256color","COLORTERM":"truecolor"}}
            {"style":0,"fg":null,"bg":null}
            {"style":1,"fg":"rgb:cba6f7","bg":null,"bold":true}
            {"style":2,"fg":"brightRed","bg":"idx:236","italic":true,"underline":true}
            {"t":0,"frame":1,"windowBg":"rgb:1e1e2e","rows":[[0,[[1,"Tasks"],[0,"   …"]]]]}
            {"t":0,"mark":"start","hold":2500}
            {"t":41233,"frame":7,"rows":[[3,[[2,"▸ ☐"]]]]}
            {"t":41300,"frame":8,"windowBg":null,"rows":[]}
            {"t":50000,"mark":"live"}
            {"t":51200,"resize":[100,30]}
            {"t":90000,"end":true,"frames":12,"marks":5}

            """
        #expect(text == expected)
    }

    @Test func identicalInputWritesIdenticalBytes() {
        #expect(written(Self.everyLine) == written(Self.everyLine))
    }

    @Test func cellsThatWouldJoinIntoOneGraphemeAreWrittenOnePerCell() throws {
        // U+1F1FA U+1F1F8 in adjacent cells: concatenated they are one flag,
        // which would read back as one cell instead of two.
        let row = RecordedRow(index: 0, styles: [0, 0, 0], characters: ["a", "🇺", "🇸"])
        let line = RecordingLine.frame(RecordedFrame(time: 0, number: 1, windowBackground: nil, rows: [row]))
        #expect(line.json == #"{"t":0,"frame":1,"rows":[[0,[[0,["a","🇺","🇸"]]]]]}"#)
        let read = try RecordingLogReader.lines(in: written([line]))
        guard case .frame(let frame) = read.first else {
            Issue.record("read \(read)")
            return
        }
        #expect(frame.rows.first?.characters == ["a", "🇺", "🇸"])
    }

    @Test func aRunThatSplitsBackIntoItsCellsStaysText() {
        let row = RecordedRow(index: 2, styles: [0, 0, 1, 1], characters: ["中", " ", "e\u{301}", "x"])
        #expect(row.runs == [RecordedRun(style: 0, cells: ["中", " "]),
                             RecordedRun(style: 1, cells: ["e\u{301}", "x"])])
        let line = RecordingLine.frame(RecordedFrame(time: 0, number: 1, windowBackground: nil, rows: [row]))
        #expect(line.json == "{\"t\":0,\"frame\":1,\"rows\":[[2,[[0,\"中 \"],[1,\"e\u{301}x\"]]]]}")
    }

    @Test func stringsEscapeQuotesBackslashesAndControlCharacters() throws {
        let label = "say \"hi\"\\ \n\t\r\u{08}\u{0C}\u{01}\u{1F}\u{7F}é"
        let line = RecordingLine.mark(time: 1, label: label, holdMs: nil)
        #expect(line.json
                == #"{"t":1,"mark":"say \"hi\"\\ \n\t\r\b\f\u0001\u001f"# + "\u{7F}é\"}")
        #expect(try RecordingLogReader.lines(in: written([line])) == [line])
    }

    @Test func theReaderTakesEveryJSONEscape() throws {
        let read = try RecordingLogReader.lines(in: Array(#"{"t":0,"mark":"\/é🇺"}"#.utf8))
        #expect(read == [.mark(time: 0, label: "/é🇺", holdMs: nil)])
    }

    @Test(arguments: [
        #"{"t":1.5,"mark":"x"}"#,
        #"{"t":1e3,"mark":"x"}"#,
        #"{"t":0,"mark":"x""#,
        #"{"t":0,"mark":"\x"}"#,
        #"{"t":0,"mark":"\ud83c"}"#,
        #"{"t":0}"#,
        #"{"t":0,"frame":1,"rows":[[0,[[0,7]]]]}"#,
        #"{"tuirec":2,"cols":1,"rows":1,"cursor":"hidden","app":"x","env":{}}"#,
        #"{"t":0,"mark":"x"} trailing"#,
    ])
    func theReaderRefusesWhatItCannotRead(line: String) {
        #expect(throws: RecordingLogError.self) { try RecordingLogReader.lines(in: Array(line.utf8)) }
    }

    @Test func anErrorNamesItsLine() {
        let text = "{\"t\":0,\"mark\":\"a\"}\n{\"t\":0,\"mark\":}\n"
        do throws(RecordingLogError) {
            _ = try RecordingLogReader.lines(in: Array(text.utf8))
            Issue.record("read a broken line")
        } catch {
            #expect(error.line == 2)
        }
    }

    @Test func keysInAnyOrderAndUnknownKeysAreRead() throws {
        let read = try RecordingLogReader.lines(in: Array(#"{"hold":40,"later":[1,{"a":null}],"mark":"m","t":3}"#.utf8))
        #expect(read == [.mark(time: 3, label: "m", holdMs: 40)])
    }

    // MARK: - Replaying

    private static let session: [RecordingLine] = [
        .header(RecordingHeader(cols: 3, rows: 2, cursorVisible: false, app: "a", environment: [])),
        .style(id: 0, RecordedStyle()),
        .frame(RecordedFrame(time: 0, number: 1, windowBackground: nil, rows: [
            RecordedRow(index: 0, styles: [0, 0, 0], characters: Array("abc")),
            RecordedRow(index: 1, styles: [0, 0, 0], characters: Array("def")),
        ])),
        .mark(time: 10, label: "first", holdMs: nil),
        .frame(RecordedFrame(time: 20, number: 4, windowBackground: nil, rows: [
            RecordedRow(index: 1, styles: [0, 0, 0], characters: Array("xyz")),
        ])),
        .mark(time: 30, label: "second", holdMs: 400),
        .resize(time: 40, cols: 2, rows: 1),
        .frame(RecordedFrame(time: 40, number: 5, windowBackground: .some("red"), rows: [
            RecordedRow(index: 0, styles: [0, 0], characters: Array("OK")),
        ])),
        .end(time: 50, frames: 3, marks: 2),
    ]

    @Test func aFrameIsRebuiltFromTheDeltasBeforeIt() throws {
        let screen = try RecordingScreen.replay(Self.session, to: .frame(4))
        #expect(screen.textRows == ["abc", "xyz"])
        #expect(screen.frameNumber == 4)
    }

    @Test func aMarkShowsTheScreenAsItWasWhenTheMarkWasMade() throws {
        #expect(try RecordingScreen.replay(Self.session, to: .mark("first")).textRows == ["abc", "def"])
        #expect(try RecordingScreen.replay(Self.session, to: .mark("second")).textRows == ["abc", "xyz"])
    }

    @Test func theEndShowsTheLastFrameAtItsSize() throws {
        let screen = try RecordingScreen.replay(Self.session, to: .end)
        #expect(screen.textRows == ["OK"])
        #expect(screen.windowBackground == "red")
    }

    @Test func aPositionTheLogNeverReachesIsAnError() {
        #expect(throws: RecordingLogError.self) { try RecordingScreen.replay(Self.session, to: .frame(2)) }
        #expect(throws: RecordingLogError.self) { try RecordingScreen.replay(Self.session, to: .mark("none")) }
        #expect(throws: RecordingLogError.self) { try RecordingScreen.replay(Array(Self.session.dropFirst()), to: .end) }
    }
}
