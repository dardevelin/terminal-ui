#if DEBUG
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import Testing
@testable import TerminalUI
import TerminalUIConfig

// A client records a running app over its control socket: `record_start`
// opens a log on the screen as it is, `record_mark` names a moment of it,
// `record_stop` ends it and `record_status` says how it stands. The verbs
// reach the recorder through `RecordingRuntime`, which the runtime conforms
// to and the public `RemoteControlRuntime` knows nothing of.

/// A runtime as the dispatcher sees one, with nothing drawn and no recorder.
@MainActor
private class ControlledApp: RemoteControlRuntime {
    private let focusEngine = FocusEngine()
    private let inspector = Inspector()
    func enqueueEvent(_ event: TerminalEvent) {}
    func remoteCurrentGraphRoot() -> AttributeNode? { nil }
    func remoteFocusEngine() -> FocusEngine { focusEngine }
    func remoteInspector() -> Inspector { inspector }
    func remotePreviousBuffer() -> CellBuffer? { nil }
    func remoteRequestCapture() {}
    func remoteCurrentFrameNumber() -> Int { 0 }
    func remoteTerminalInputTaken() -> TerminalInputTaken { TerminalInputTaken() }
    func remoteFrameworkDefaultsScope() -> ActionScope { ActionScope(boundActions: []) }
}

/// One that draws, frame by frame, and records what it draws as the
/// runtime does: each frame handed to the recorder once it is drawn.
@MainActor
private final class RecordedApp: ControlledApp, RecordingRuntime {
    let frameRecorder = FrameRecorder()
    let recordingAppName = "Recorded"
    private var screen: DrawnScreen?

    func drawnScreen() -> DrawnScreen? { screen }

    func draw(_ rows: [String], frame: Int) {
        var buffer = CellBuffer(width: rows.map(\.count).max() ?? 0, height: rows.count)
        for (y, row) in rows.enumerated() {
            buffer.write(row, x: 0, y: y, style: .plain)
        }
        screen = DrawnScreen(buffer: buffer, windowBackground: nil, frame: frame)
        frameRecorder.frameDrawn(buffer, windowBackground: nil, frame: frame)
    }
}

@MainActor
@Suite("The recording verbs")
struct RecordingVerbTests {

    private func scratchPath() -> String {
        NSTemporaryDirectory() + "terminalui-verbs-\(UUID().uuidString).tuirec"
    }

    private func send(_ dispatcher: RuntimeRemoteDispatcher, _ cmd: String, path: String? = nil,
                      label: String? = nil, holdMs: Int? = nil) -> RemoteResponse {
        var request = RemoteRequest(id: 1, cmd: cmd)
        request.path = path
        request.label = label
        request.holdMs = holdMs
        return dispatcher.dispatch(request)
    }

    private func lines(at path: String) throws -> [RecordingLine] {
        let data = try #require(FileManager.default.contents(atPath: path))
        return try RecordingLogReader.lines(in: Array(data))
    }

    @Test func startRecordsTheScreenAsItIsNow() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let app = RecordedApp()
        app.draw(["Page one"], frame: 7)
        let dispatcher = RuntimeRemoteDispatcher(runtime: app)

        let started = send(dispatcher, "record_start", path: path)
        #expect(started.ok, "\(started.error ?? "")")
        #expect(started.result?.recording == RecordingInfo(path: path, frames: 1, marks: 0, durationMs: 0, active: true))
        #expect(started.result?.frame == 7)
        #expect(send(dispatcher, "record_stop").ok)

        let lines = try lines(at: path)
        guard case .header(let header) = lines.first else {
            Issue.record("no header: \(lines)")
            return
        }
        #expect(header.app == "Recorded")
        #expect(try RecordingScreen.replay(lines, to: .end).textRows == ["Page one"])
        #expect(try RecordingScreen.replay(lines, to: .end).frameNumber == 7)
    }

    @Test func aLabelOnStartMarksTheFirstFrame() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let app = RecordedApp()
        app.draw(["first"], frame: 1)
        let dispatcher = RuntimeRemoteDispatcher(runtime: app)

        let started = send(dispatcher, "record_start", path: path, label: "start", holdMs: 2500)
        #expect(started.result?.recording?.marks == 1)
        app.draw(["second"], frame: 2)
        _ = send(dispatcher, "record_stop")

        let lines = try lines(at: path)
        #expect(lines.contains { if case .mark(0, "start", 2500) = $0 { true } else { false } })
        #expect(try RecordingScreen.replay(lines, to: .mark("start")).textRows == ["first"])
    }

    @Test func aMarkNamesTheFrameOnScreen() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let app = RecordedApp()
        app.draw(["one"], frame: 1)
        let dispatcher = RuntimeRemoteDispatcher(runtime: app)
        _ = send(dispatcher, "record_start", path: path)
        app.draw(["two"], frame: 2)
        app.draw(["two"], frame: 3)

        let marked = send(dispatcher, "record_mark", label: "second", holdMs: 400)
        #expect(marked.ok, "\(marked.error ?? "")")
        // Frame 3 drew nothing new, so the screen at the mark is frame 2's.
        #expect(marked.result?.frame == 2)
        #expect(marked.result?.recording?.marks == 1)
        #expect(marked.result?.recording?.frames == 2)
        _ = send(dispatcher, "record_stop")

        let lines = try lines(at: path)
        #expect(lines.contains { if case .mark(_, "second", 400) = $0 { true } else { false } })
        #expect(try RecordingScreen.replay(lines, to: .mark("second")).textRows == ["two"])
    }

    @Test func stopEndsTheLogAndStatusStillDescribesIt() throws {
        let path = scratchPath()
        defer { unlink(path) }
        let app = RecordedApp()
        app.draw(["x"], frame: 1)
        let dispatcher = RuntimeRemoteDispatcher(runtime: app)
        _ = send(dispatcher, "record_start", path: path)
        #expect(send(dispatcher, "record_status").result?.recording?.active == true)
        _ = send(dispatcher, "record_mark", label: "m")

        let stopped = send(dispatcher, "record_stop")
        #expect(stopped.ok)
        let info = try #require(stopped.result?.recording)
        #expect(!info.active && info.path == path && info.frames == 1 && info.marks == 1)
        #expect(info.durationMs >= 0)
        #expect(send(dispatcher, "record_status").result?.recording == info)
        guard case .end(_, 1, 1) = try lines(at: path).last else {
            Issue.record("the log does not end with its end line")
            return
        }
    }

    @Test func statusBeforeAnyRecordingSaysNoneIsActive() {
        let app = RecordedApp()
        let dispatcher = RuntimeRemoteDispatcher(runtime: app)
        let status = send(dispatcher, "record_status")
        #expect(status.ok)
        #expect(status.result?.recording == RecordingInfo(path: nil, frames: 0, marks: 0, durationMs: 0, active: false))
        withExtendedLifetime(app) {}
    }

    @Test func aSecondStartIsAnErrorAndCreatesNothing() throws {
        let path = scratchPath(), other = scratchPath()
        defer { unlink(path); unlink(other) }
        let app = RecordedApp()
        app.draw(["x"], frame: 1)
        let dispatcher = RuntimeRemoteDispatcher(runtime: app)
        _ = send(dispatcher, "record_start", path: path)

        let again = send(dispatcher, "record_start", path: other)
        #expect(!again.ok)
        #expect(again.error == RecordingError.alreadyRecording.description)
        #expect(!FileManager.default.fileExists(atPath: other))
        #expect(app.frameRecorder.isActive)
        _ = send(dispatcher, "record_stop")
    }

    @Test func aPathThatExistsIsAnError() throws {
        let path = scratchPath()
        defer { unlink(path) }
        #expect(FileManager.default.createFile(atPath: path, contents: Data("mine".utf8)))
        let app = RecordedApp()
        app.draw(["x"], frame: 1)
        let refused = send(RuntimeRemoteDispatcher(runtime: app), "record_start", path: path)
        #expect(!refused.ok && refused.error?.contains("already exists") == true, "\(refused.error ?? "")")
        #expect(FileManager.default.contents(atPath: path) == Data("mine".utf8))
        withExtendedLifetime(app) {}
    }

    @Test func markAndStopWithNothingRecordingAreErrors() {
        let app = RecordedApp()
        let dispatcher = RuntimeRemoteDispatcher(runtime: app)
        for verb in ["record_mark", "record_stop"] {
            let response = send(dispatcher, verb, label: "m")
            #expect(!response.ok, "\(verb)")
            #expect(response.error == RecordingError.notRecording.description, "\(verb)")
        }
        withExtendedLifetime(app) {}
    }

    @Test(arguments: [
        ("record_start", nil, nil, "record_start requires `path`"),
        ("record_start", "", nil, "record_start requires `path`"),
        ("record_mark", nil, nil, "record_mark requires `label`"),
        ("record_mark", "", nil, "record_mark requires `label`"),
        ("record_mark", "m", -1, "hold_ms is a duration, at least 0"),
    ] as [(String, String?, Int?, String)])
    func aRequestMissingWhatItNeedsIsAnError(verb: String, text: String?, holdMs: Int?, error: String) throws {
        let path = scratchPath()
        defer { unlink(path) }
        let app = RecordedApp()
        app.draw(["x"], frame: 1)
        let dispatcher = RuntimeRemoteDispatcher(runtime: app)
        if verb == "record_mark" { _ = send(dispatcher, "record_start", path: path) }

        let response = verb == "record_start"
            ? send(dispatcher, verb, path: text, holdMs: holdMs)
            : send(dispatcher, verb, label: text, holdMs: holdMs)
        #expect(!response.ok)
        #expect(response.error == error)
        _ = send(dispatcher, "record_stop")
    }

    @Test func aRuntimeThatCannotRecordSaysSo() {
        let app = ControlledApp()
        let dispatcher = RuntimeRemoteDispatcher(runtime: app)
        for verb in ["record_start", "record_mark", "record_stop", "record_status"] {
            let response = send(dispatcher, verb, path: "/nowhere", label: "m")
            #expect(!response.ok && response.error == "this app cannot record", "\(verb)")
        }
        withExtendedLifetime(app) {}
    }

    // The wire is snake_case both ways: `hold_ms` in, `duration_ms` out.
    @Test func theVerbsSpeakTheWireOverTheSocket() async throws {
        let path = scratchPath()
        defer { unlink(path) }
        let socketPath = "/tmp/terminalui-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let app = RecordedApp()
        app.draw(["x"], frame: 1)
        let server = RemoteControlServer(path: socketPath, dispatcher: RuntimeRemoteDispatcher(runtime: app))
        let client = try #require(UnixSocket.connected(to: socketPath))
        defer { close(client) }

        func call(_ line: String) async throws -> [String: Any] {
            _ = UnixSocket.sendLine(Array(line.utf8), to: client)
            let reader = BlockingThread(name: "client") { UnixSocket.readLine(from: client) }
            server.pump()
            let reply = await reader.value
            return try #require(try JSONSerialization.jsonObject(with: Data(reply)) as? [String: Any])
        }

        let started = try await call(#"{"id":1,"cmd":"record_start","path":"\#(path)"}"#)
        #expect(started["ok"] as? Bool == true)
        let marked = try await call(#"{"id":2,"cmd":"record_mark","label":"here","hold_ms":400}"#)
        let result = try #require(marked["result"] as? [String: Any])
        let recording = try #require(result["recording"] as? [String: Any])
        #expect(Set(recording.keys) == ["path", "frames", "marks", "duration_ms", "active"])
        #expect(recording["marks"] as? Int == 1)
        #expect(result["frame"] as? Int == 1)
        _ = try await call(#"{"id":3,"cmd":"record_stop"}"#)
        #expect(try lines(at: path).contains { if case .mark(_, "here", 400) = $0 { true } else { false } })
        withExtendedLifetime(server) {}
    }
}
#endif
