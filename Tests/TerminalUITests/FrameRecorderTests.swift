#if DEBUG
import Foundation
import Testing
@testable import TerminalUI
import TerminalUIConfig
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The recorder keeps what the runtime drew, frame by frame, in a `.tuirec`
// log: the first frame whole, then only the rows that changed, each style
// declared the first time a cell uses it. It writes a file that may hold
// every key typed into the app, so it makes the file itself, readable by
// its owner alone, and refuses any path that already names something.

@MainActor
@Suite("The frame recorder")
struct FrameRecorderTests {

    private static let accent = Style(foreground: .rgb(0xCB, 0xA6, 0xF7), background: nil,
                                      bold: true, italic: false, underline: false)

    private func scratchPath() -> String {
        NSTemporaryDirectory() + "terminalui-recorder-\(UUID().uuidString).tuirec"
    }

    private func buffer(_ rows: [String], width: Int? = nil, style: Style = .plain) -> CellBuffer {
        var buffer = CellBuffer(width: width ?? rows.map(\.count).max() ?? 0, height: rows.count)
        for (y, row) in rows.enumerated() {
            buffer.write(row, x: 0, y: y, style: style)
        }
        return buffer
    }

    private func lines(at path: String) throws -> [RecordingLine] {
        let data = try #require(FileManager.default.contents(atPath: path))
        return try RecordingLogReader.lines(in: Array(data))
    }

    private func frames(_ lines: [RecordingLine]) -> [RecordedFrame] {
        lines.compactMap { if case .frame(let frame) = $0 { frame } else { nil } }
    }

    private func styles(_ lines: [RecordingLine]) -> [Int: RecordedStyle] {
        var table: [Int: RecordedStyle] = [:]
        for case .style(let id, let style) in lines {
            #expect(table[id] == nil, "style \(id) declared twice")
            table[id] = style
        }
        return table
    }

    @Test func startingRecordsTheScreenAsItIs() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "Tasks", current: buffer(["Hello", "world"]),
                           windowBackground: .rgb(0x1E, 0x1E, 0x2E), frame: 9)
        recorder.stop()

        let lines = try lines(at: path)
        guard case .header(let header) = lines.first else {
            Issue.record("no header: \(lines)")
            return
        }
        #expect(header.cols == 5 && header.rows == 2 && header.app == "Tasks" && !header.cursorVisible)
        let first = try #require(frames(lines).first)
        #expect(first.time == 0 && first.number == 9)
        #expect(first.windowBackground == .some("rgb:1e1e2e"))
        #expect(first.rows.map(\.index) == [0, 1])
        #expect(first.rows.map { String($0.characters) } == ["Hello", "world"])
        #expect(styles(lines)[first.rows[0].runs[0].style] == RecordedStyle())
    }

    @Test func aRecorderStartedBeforeAnyFrameRecordsTheFirstOneDrawn() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "Tasks", current: nil, windowBackground: nil, frame: 0)
        #expect(recorder.isActive)
        recorder.frameDrawn(buffer(["abc"]), windowBackground: nil, frame: 1)
        recorder.stop()

        let lines = try lines(at: path)
        guard case .header(let header) = lines.first else {
            Issue.record("no header: \(lines)")
            return
        }
        #expect(header.cols == 3 && header.rows == 1)
        #expect(frames(lines).map(\.number) == [1])
        #expect(frames(lines).first?.windowBackground == nil)
    }

    @Test func aFrameIdenticalToTheLastIsNotRecorded() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["same"]), windowBackground: nil, frame: 1)
        recorder.frameDrawn(buffer(["same"]), windowBackground: nil, frame: 2)
        recorder.frameDrawn(buffer(["same"]), windowBackground: nil, frame: 3)
        recorder.stop()

        let lines = try lines(at: path)
        #expect(frames(lines).map(\.number) == [1])
        #expect(lines.last == .end(time: endTime(lines), frames: 1, marks: 0))
    }

    @Test func aFrameHoldsOnlyTheRowsThatChanged() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["one", "two", "six"]),
                           windowBackground: nil, frame: 1)
        recorder.frameDrawn(buffer(["one", "TWO", "six"]), windowBackground: nil, frame: 2)
        recorder.stop()

        let second = try #require(frames(try lines(at: path)).last)
        #expect(second.number == 2)
        #expect(second.rows.map(\.index) == [1])
        #expect(second.rows.map { String($0.characters) } == ["TWO"])
    }

    @Test func aStyleIsDeclaredOnceAndReusedByLaterFrames() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["ab"], style: Self.accent),
                           windowBackground: nil, frame: 1)
        recorder.frameDrawn(buffer(["cd"], style: Self.accent), windowBackground: nil, frame: 2)
        recorder.frameDrawn(buffer(["ef"]), windowBackground: nil, frame: 3)
        recorder.stop()

        let lines = try lines(at: path)
        let table = styles(lines)
        #expect(table.count == 2)
        #expect(Set(table.values) == [RecordedStyle(foreground: "rgb:cba6f7", bold: true), RecordedStyle()])
        let runs = frames(lines).map { $0.rows[0].runs[0].style }
        #expect(runs[0] == runs[1] && runs[1] != runs[2])
    }

    @Test func coloursAreRecordedAsTheyWereEncoded() throws {
        let path = scratchPath()
        defer { unlink(path) }
        var screen = CellBuffer(width: 4, height: 1)
        screen.write("a", x: 0, y: 0, style: Style(foreground: .gray, background: .brightBlue,
                                                    bold: false, italic: true, underline: false))
        screen.write("b", x: 1, y: 0, style: Style(foreground: .ansi256(236), background: .default,
                                                    bold: false, italic: false, underline: true))
        screen.write("c", x: 2, y: 0, style: Style(foreground: .default, background: nil,
                                                    bold: false, italic: false, underline: false))
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: screen, windowBackground: .default, frame: 1)
        recorder.stop()

        let lines = try lines(at: path)
        #expect(Set(styles(lines).values) == [
            RecordedStyle(foreground: "gray", background: "brightBlue", italic: true),
            RecordedStyle(foreground: "idx:236", underline: true),
            RecordedStyle(),
        ])
        let runs = try #require(frames(lines).first).rows[0].runs
        #expect(runs.map(\.cells.count) == [1, 1, 2], "a .default colour is the terminal's own, as nil is")
        #expect(frames(lines).first?.windowBackground == nil)
    }

    @Test func theWindowBackgroundIsWrittenWhenItChanges() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["x"]), windowBackground: nil, frame: 1)
        recorder.frameDrawn(buffer(["x"]), windowBackground: .red, frame: 2)
        recorder.frameDrawn(buffer(["y"]), windowBackground: .red, frame: 3)
        recorder.frameDrawn(buffer(["y"]), windowBackground: nil, frame: 4)
        recorder.stop()

        let recorded = frames(try lines(at: path))
        #expect(recorded.map(\.number) == [1, 2, 3, 4])
        #expect(recorded.map(\.windowBackground) == [nil, .some("red"), nil, .some(nil)])
        #expect(recorded[1].rows.isEmpty)
    }

    @Test func aResizeIsRecordedAndTheFrameAfterItIsWhole() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["ab", "cd"]), windowBackground: nil, frame: 1)
        recorder.frameDrawn(buffer(["ab", "cd", "ef"], width: 3), windowBackground: nil, frame: 2)
        recorder.stop()

        let lines = try lines(at: path)
        let resizes = lines.compactMap { line -> [Int]? in
            if case .resize(_, let cols, let rows) = line { [cols, rows] } else { nil }
        }
        #expect(resizes == [[3, 3]])
        #expect(frames(lines).last?.rows.map(\.index) == [0, 1, 2])
        #expect(try RecordingScreen.replay(lines, to: .end).textRows == ["ab ", "cd ", "ef "])
    }

    @Test func aMarkIsWrittenThroughToTheFile() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["x"]), windowBackground: nil, frame: 1)
        recorder.mark(label: "here", holdMs: 400)

        let lines = try lines(at: path)
        #expect(lines.contains { if case .mark(_, "here", 400) = $0 { true } else { false } })
        recorder.stop()
    }

    @Test func framesAreBufferedUntilSomethingFlushesThem() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["x"]), windowBackground: nil, frame: 1)
        recorder.frameDrawn(buffer(["y"]), windowBackground: nil, frame: 2)
        #expect(FileManager.default.contents(atPath: path)?.isEmpty == true)
        recorder.stop()
        #expect(frames(try lines(at: path)).count == 2)
    }

    @Test func stoppingEndsTheLogAndTheRecording() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["x"]), windowBackground: nil, frame: 1)
        recorder.mark(label: "m", holdMs: nil)
        recorder.frameDrawn(buffer(["y"]), windowBackground: nil, frame: 2)
        recorder.stop()
        #expect(!recorder.isActive)
        recorder.frameDrawn(buffer(["z"]), windowBackground: nil, frame: 3)
        recorder.stop()

        let lines = try lines(at: path)
        #expect(lines.last == .end(time: endTime(lines), frames: 2, marks: 1))
        #expect(lines.filter { if case .end = $0 { true } else { false } }.count == 1)
    }

    @Test func finishingEndsALogNobodyStopped() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["x"]), windowBackground: nil, frame: 1)
        recorder.finish()
        recorder.finish()

        let lines = try lines(at: path)
        #expect(lines.last == .end(time: endTime(lines), frames: 1, marks: 0))
    }

    @Test func finishingARecorderThatNeverDrewLeavesALogWithNoFrames() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: nil, windowBackground: nil, frame: 0)
        recorder.finish()
        #expect(FileManager.default.contents(atPath: path)?.isEmpty == true)
    }

    @Test func aSecondStartWhileRecordingIsRefused() throws {
        let path = scratchPath(), other = scratchPath()
        defer { unlink(path); unlink(other) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["x"]), windowBackground: nil, frame: 1)
        #expect(throws: RecordingError.alreadyRecording) {
            try recorder.start(path: other, appName: "a", current: nil, windowBackground: nil, frame: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: other))
        recorder.stop()
    }

    @Test func theLogIsItsOwnersAlone() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let recorder = FrameRecorder()
        try recorder.start(path: path, appName: "a", current: buffer(["x"]), windowBackground: nil, frame: 1)
        recorder.stop()
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFREG)
        #expect(info.st_mode & 0o777 == 0o600, "mode \(String(info.st_mode & 0o777, radix: 8))")
    }

    @Test func aPathThatExistsIsRefusedAndLeftAlone() throws {
        let path = scratchPath()
        defer { unlink(path) }
        #expect(FileManager.default.createFile(atPath: path, contents: Data("mine".utf8)))
        let recorder = FrameRecorder()
        #expect(throws: RecordingError.self) {
            try recorder.start(path: path, appName: "a", current: buffer(["x"]), windowBackground: nil, frame: 1)
        }
        #expect(!recorder.isActive)
        #expect(FileManager.default.contents(atPath: path) == Data("mine".utf8))
    }

    @Test func aLinkIsRefusedAndNothingIsWrittenWhereItPoints() throws {
        let path = scratchPath(), target = scratchPath()
        defer { unlink(path); unlink(target) }
        #expect(symlink(target, path) == 0)
        let recorder = FrameRecorder()
        #expect(throws: RecordingError.self) {
            try recorder.start(path: path, appName: "a", current: buffer(["x"]), windowBackground: nil, frame: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func aDirectoryIsRefused() throws {
        let path = scratchPath()
        defer { rmdir(path) }
        #expect(mkdir(path, 0o700) == 0)
        let recorder = FrameRecorder()
        #expect(throws: RecordingError.self) {
            try recorder.start(path: path, appName: "a", current: nil, windowBackground: nil, frame: 0)
        }
    }

    private func endTime(_ lines: [RecordingLine]) -> Int {
        if case .end(let time, _, _) = lines.last { time } else { -1 }
    }
}

@Suite("The [record] settings")
struct RecordConfigTests {

    @Test func recordingIsOffByDefault() {
        #expect(!DiagConfig.default.recordOnLaunch)
        #expect(DiagConfig.default.recordPath == nil)
        #expect(!DiagConfig(from: [:]).recordOnLaunch)
    }

    @Test func theSectionIsRead() {
        let config = DiagConfig(from: TOMLParser.parse("[record]\nenabled = true\npath = \"walk.tuirec\"\n"))
        #expect(config.recordOnLaunch)
        #expect(config.recordPath == "walk.tuirec")
    }

    @Test func theSectionIsWrittenAndReadBack() {
        var config = DiagConfig.default
        config.recordOnLaunch = true
        config.recordPath = "out/walk.tuirec"
        let read = DiagConfig(from: TOMLParser.parse(TOMLParser.write(config.toSections())))
        #expect(read.recordOnLaunch)
        #expect(read.recordPath == "out/walk.tuirec")

        let unset = DiagConfig(from: TOMLParser.parse(TOMLParser.write(DiagConfig.default.toSections())))
        #expect(!unset.recordOnLaunch && unset.recordPath == nil)
    }

    @Test func swtuiEnablesItByName() {
        let key = DiagConfig.featureKey(for: "record")
        #expect(key?.section == "record" && key?.key == "enabled")
        #expect(DiagConfig.featureNames.contains("record"))
    }

    @Test func theDefaultPathIsUnderTheProjectNotTheDataDir() {
        let path = DiagPaths.recordingPath(config: .default, appName: "Tasks", pid: 42)
        #expect(path == DiagPaths.configDir + "/recordings/Tasks-42.tuirec")
        #expect(!path.hasPrefix(DiagPaths.tmpDataDir))
    }

    @Test func aRelativePathIsTheProjects() {
        var config = DiagConfig.default
        config.recordPath = "walk.tuirec"
        let cwd = FileManager.default.currentDirectoryPath
        #expect(DiagPaths.recordingPath(config: config, appName: "a", pid: 1) == cwd + "/walk.tuirec")
        config.recordPath = "/var/tmp/walk.tuirec"
        #expect(DiagPaths.recordingPath(config: config, appName: "a", pid: 1) == "/var/tmp/walk.tuirec")
    }
}
#endif
