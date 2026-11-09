import Foundation
import Testing
import TerminalUI
import TerminalUIConfig
@testable import TerminalUIRecording

// A recording as an asciicast v2 file, byte for byte: the same log must
// give the same file on macOS and Linux, and each output event must be the
// bytes the framework itself would have sent a terminal for that frame.

@Suite("The asciicast encoder")
struct CastEncoderTests {

    private static let session = [
        header4x2,
        #"{"style":0,"fg":null,"bg":null}"#,
        #"{"style":1,"fg":"red","bg":null,"bold":true}"#,
        #"{"t":0,"frame":1,"windowBg":"rgb:1e1e2e","rows":[[0,[[1,"ab"],[0,"  "]]],[1,[[0,"    "]]]]}"#,
        #"{"t":1000,"mark":"start","hold":500}"#,
        #"{"t":3000,"frame":2,"rows":[[0,[[1,"ac"],[0,"  "]]]]}"#,
        #"{"t":4000,"mark":"wide","hold":250}"#,
        #"{"t":5000,"resize":[5,2]}"#,
        #"{"t":5000,"frame":3,"windowBg":null,"rows":[[0,[[0,"界 x  "]]],[1,[[1,"\""],[0,"    "]]]]}"#,
        #"{"t":6000,"mark":"end","hold":1000}"#,
        #"{"t":7000,"end":true,"frames":3,"marks":3}"#,
    ]

    private func cast(_ lines: [String] = session, range: PresentationClock.Range = .whole,
                      palette: RecordingPalette = .catppuccinMocha) throws -> String {
        let log = try reader(lines)
        let timeline = try PresentationClock(mode: .script).timeline(of: log, range: range)
        return CastEncoder(palette: palette).encode(log, timeline: timeline)
    }

    /// An event's fields, read back with a JSON decoder the encoder does not use.
    private func fields(_ line: Substring) throws -> [Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any])
    }

    private func outputs(_ cast: String) throws -> [String] {
        try cast.split(separator: "\n").dropFirst().compactMap { line in
            let event = try fields(line)
            return event[1] as? String == "o" ? event[2] as? String : nil
        }
    }

    @Test func theFileIsPinnedByteForByte() throws {
        let expected = #"""
            {"version":2,"width":4,"height":2,"title":"demo","env":{"TERM":"xterm-256color"},"theme":{"fg":"#cdd6f4","bg":"#1e1e2e","palette":"#45475a:#f38ba8:#a6e3a1:#f9e2af:#89b4fa:#f5c2e7:#94e2d5:#a6adc8:#585b70:#f37799:#89d88b:#ebd391:#74a8fc:#f2aede:#6bd7ca:#bac2de"}}
            [0.000000,"o","\u001b[?1049h\u001b[?25l\u001b]11;rgb:1e/1e/2e\u001b\\\u001b[H\u001b[0m\u001b[31m\u001b[1mab\u001b[0m  \r\n    \u001b[0m"]
            [0.000000,"m","start"]
            [0.500000,"o","\u001b[1;2H\u001b[0m\u001b[31m\u001b[1mc\u001b[0m"]
            [0.500000,"m","wide"]
            [0.750000,"r","5x2"]
            [0.750000,"o","\u001b[H界x  \r\n\u001b[0m\u001b[31m\u001b[1m\"\u001b[0m    \u001b[0m\u001b]111\u001b\\"]
            [0.750000,"m","end"]

            """#
        #expect(try cast() == expected)
    }

    @Test func theFirstEventEntersTheAlternateScreenSetsTheBackgroundAndDrawsItAll() throws {
        let first = try #require(try outputs(try cast()).first)
        var buffer = CellBuffer(width: 4, height: 2)
        buffer.write("ab", x: 0, y: 0, style: Style(foreground: .red, background: nil, bold: true,
                                                     italic: false, underline: false))
        var full = OutputBuffer()
        buffer.renderFull(into: &full)
        #expect(first == "\u{1B}[?1049h\u{1B}[?25l" + "\u{1B}]11;rgb:1e/1e/2e\u{1B}\\"
                + String(decoding: full.writtenBytes, as: UTF8.self))
    }

    @Test func eachLaterEventIsTheFrameworksOwnDiff() throws {
        let log = try reader(Self.session)
        let screens = Array(log.screens).map(\.buffer)
        let events = try outputs(try cast())
        #expect(events.count == 3)
        var diff = OutputBuffer()
        screens[1].renderDiff(from: screens[0], into: &diff)
        #expect(events[1] == String(decoding: diff.writtenBytes, as: UTF8.self))
        // A new size draws the whole screen, and the background the app
        // took back is the terminal's own again (OSC 111), after the cells.
        screens[2].renderDiff(from: screens[1], into: &diff)
        #expect(events[2] == String(decoding: diff.writtenBytes, as: UTF8.self) + "\u{1B}]111\u{1B}\\")
    }

    @Test func marksAndResizesAreEventsOfTheirOwn() throws {
        let events = try cast().split(separator: "\n").dropFirst().map { try fields($0) }
        let codes = events.map { "\($0[0] as? Double ?? -1) \($0[1]) \($0[1] as? String == "o" ? "…" : "\($0[2])")" }
        #expect(codes == [
            "0.0 o …", "0.0 m start", "0.5 o …", "0.5 m wide", "0.75 r 5x2", "0.75 o …", "0.75 m end",
        ])
    }

    @Test func aRangeStartsFromItsFirstMarksScreen() throws {
        let range = try cast(range: .between(from: "wide", to: "end"))
        let lines = range.split(separator: "\n")
        // The header is sized for the frame the range opens with.
        #expect(lines[0].hasPrefix(#"{"version":2,"width":4,"height":2,"#))
        let first = try fields(lines[1])
        #expect(first[0] as? Double == 0 && first[1] as? String == "o")
        #expect((first[2] as? String)?.hasPrefix("\u{1B}[?1049h\u{1B}[?25l\u{1B}]11;") == true)
        #expect(lines.count == 6)
    }

    @Test func timesAreSecondsWithSixDecimals() {
        #expect(CastEncoder.seconds(microseconds: 0) == "0.000000")
        #expect(CastEncoder.seconds(microseconds: 1) == "0.000001")
        #expect(CastEncoder.seconds(microseconds: 1_250_000) == "1.250000")
        #expect(CastEncoder.seconds(microseconds: 61_000_123) == "61.000123")
    }

    @Test func stringsAreEscapedAsRFC8259Says() throws {
        var lines = Self.session
        lines[0] = lines[0].replacingOccurrences(of: #""app":"demo""#, with: #""app":"say \"hi\"\\\u0001""#)
        let header = try #require(try cast(lines).split(separator: "\n").first)
        #expect(header.contains(#""title":"say \"hi\"\\\u0001""#))
        // A frame's escape sequences: ESC is a control, so `\u001b`.
        #expect(try cast().contains(#"[0.000000,"o","\u001b[?1049h\u001b[?25l"#))
    }

    @Test func theThemeFollowsThePaletteAndTheWindowBackground() throws {
        let header = try #require(try cast(palette: .xterm).split(separator: "\n").first)
        #expect(header.contains(##""theme":{"fg":"#c0c0c0","bg":"#1e1e2e","palette":"#000000:#800000:"##))
        var plain = Self.session
        plain[3] = plain[3].replacingOccurrences(of: #""windowBg":"rgb:1e1e2e","#, with: "")
        let unset = try #require(try cast(plain, palette: .xterm).split(separator: "\n").first)
        #expect(unset.contains(##""bg":"#000000""##))
        // No OSC 11 for a window the app never coloured.
        #expect(try outputs(try cast(plain)).first?.contains("\u{1B}]11;") == false)
    }
}
