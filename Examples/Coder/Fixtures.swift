import TerminalUI

/// Canned session content. No agent, no network — this is a look-and-
/// interaction demo, and fixed data keeps the PTY harness's cell-grid
/// comparisons stable across runs.
enum Fixtures {
    static func session() -> CoderState {
        CoderState(
            sessionTitle: "Wire the compositor delta to the frame budget",
            workingDirectory: "~/src/terminal-ui",
            modelName: "opus-5",
            providerName: "anthropic",
            contextUsed: 48_320,
            contextWindow: 200_000,
            cost: 0.42,
            entries: transcript(),
            resources: resources(),
            changes: changes(),
            todos: todos()
        )
    }

    static func transcript() -> [Entry] {
        [
            .message(Message(
                id: 1,
                author: .user,
                body: "The compositor is emitting a full repaint whenever the "
                    + "frame budget is missed. Find out why and fix it.",
                timestamp: "14:02"
            )),
            .message(Message(
                id: 2,
                author: .assistant,
                body: "Let me look at how the delta is computed against the "
                    + "previous buffer.",
                timestamp: "14:02"
            )),
            .tool(ToolCall(
                id: 3,
                name: "Read",
                summary: "Sources/TerminalUI/Rendering/Compositor.swift",
                state: .success,
                output: nil,
                excerpt: FileExcerpt(path: "Sources/TerminalUI/Rendering/Compositor.swift",
                                     firstLine: 298, code: compositorExcerpt)
            )),
            .tool(ToolCall(
                id: 4,
                name: "Grep",
                summary: "previousBuffer = nil",
                state: .success,
                output: """
                    Compositor.swift:311:        previousBuffer = nil
                    Compositor.swift:408:        previousBuffer = nil  // reset on resize
                    """
            )),
            .message(Message(
                id: 5,
                author: .assistant,
                body: """
                    Found it. The frame loop drops `previousBuffer` to signal a \
                    skip, but the compositor reads that same nil as *first \
                    frame* and repaints everything.

                    ## The fix

                    1. Give the skip its **own flag**
                    2. Leave `previousBuffer` meaning one thing

                    > The buffer was carrying two meanings. That is the whole bug.

                    ```swift
                    if skippedFrame { return .unchanged }
                    ```
                    """,
                timestamp: "14:03"
            )),
            .tool(ToolCall(
                id: 6,
                name: "Edit",
                summary: "Compositor.swift — add skippedFrame flag",
                state: .success,
                output: nil,
                diff: DiffEngine.diff(original: compositorBefore, modified: compositorAfter)
            )),
            .tool(ToolCall(
                id: 7,
                name: "Bash",
                summary: "swift test --filter Compositor",
                state: .success,
                output: compositorTestRun
            )),
            .tool(ToolCall(
                id: 8,
                name: "Bash",
                summary: "swift run -c release Demo --measure-bytes",
                state: .pending,
                output: nil
            )),
        ]
    }

    /// Long enough to pass the card's line cap, with one diagnostic wider
    /// than the transcript so the card has to cut it.
    private static let compositorTestRun = """
        Building for debugging...
        [412/415] Compiling TerminalUI Compositor.swift
        Sources/TerminalUI/Rendering/Compositor.swift:311:9: note: previousBuffer is now nil only before the first frame; the skip path reads skippedFrame
        Build complete! (3.41s)
        ◇ Test run started.
        ↳ Testing Library Version: 6.2
        ◇ Suite CompositorDeltaTests started.
        ✔ Test skippedFrameEmitsNoBytes() passed after 0.002 seconds.
        ✔ Test firstFrameRepaintsEverything() passed after 0.001 seconds.
        ✔ Test deltaAgainstPreviousBufferBridgesGaps() passed after 0.003 seconds.
        ✔ Test missedBudgetSkipsWithoutRepainting() passed after 0.002 seconds.
        ✔ Test cursorTrackingSurvivesASkippedFrame() passed after 0.001 seconds.
        ✔ Suite CompositorDeltaTests passed after 0.011 seconds.
        ✔ Test run with 5 tests in 1 suite passed after 0.012 seconds.
        """

    /// What the Read call returned: fifteen lines from line 298, so the card
    /// shows ten and holds five back — among them line 311, where Grep finds
    /// the nil the bug hangs on.
    private static let compositorExcerpt = """
            /// Compute the bytes that turn the last frame into this one.
            func flush(_ buffer: CellBuffer) -> FrameResult {
                guard let previous = previousBuffer else {
                    // No previous frame: everything on screen is new.
                    previousBuffer = buffer
                    return .fullRepaint(buffer)
                }
                let delta = diff(previous, buffer)
                previousBuffer = buffer
                return delta.isEmpty ? .unchanged : .delta(delta)
            }

            func skip() {
                previousBuffer = nil
            }
        """

    private static let compositorBefore = """
            private var previousBuffer: CellBuffer?

            func skip() {
                previousBuffer = nil
            }

            func flush(_ buffer: CellBuffer) -> FrameResult {
                guard let previous = previousBuffer else {
        """

    private static let compositorAfter = """
            private var previousBuffer: CellBuffer?
            private var skippedFrame = false

            func skip() {
                skippedFrame = true
            }

            func flush(_ buffer: CellBuffer) -> FrameResult {
                if skippedFrame { return .unchanged }
                guard let previous = previousBuffer else {
        """

    static func resources() -> [Resource] {
        [
            Resource(id: 1, kind: .lsp, name: "sourcekit-lsp", health: .online, detail: "ready"),
            Resource(id: 2, kind: .lsp, name: "gopls", health: .offline, detail: "not started"),
            Resource(id: 3, kind: .mcp, name: "filesystem", health: .online, detail: "12 tools"),
            Resource(id: 4, kind: .mcp, name: "github", health: .busy, detail: "starting…"),
            Resource(id: 5, kind: .mcp, name: "postgres", health: .failed, detail: "auth failed"),
        ]
    }

    /// The session's edits, as its transcript shows them. The other sources
    /// are read from git when the review opens.
    static func changes() -> [ReviewSource: [FileChange]] {
        func change(_ path: String, from before: String, to after: String) -> FileChange {
            FileChange(path: path, lines: DiffEngine.diff(original: before, modified: after))
        }
        return [
            .session: [
                change("Rendering/Compositor.swift", from: compositorBefore, to: compositorAfter),
                change("Core/FrameStats.swift", from: frameStatsBefore, to: frameStatsAfter),
                change("Tests/CompositorTests.swift", from: "", to: compositorTests),
            ],
        ]
    }

    private static let frameStatsBefore = """
        struct FrameStats {
            var bytesWritten = 0
            var repaints = 0
        }
        """

    private static let frameStatsAfter = """
        struct FrameStats {
            var bytesWritten = 0
            var repaints = 0
            /// Frames the loop skipped: nothing changed, nothing written.
            var skipped = 0
        }
        """

    private static let compositorTests = """
        import Testing
        @testable import TerminalUI

        @Suite("A skipped frame writes nothing")
        struct CompositorDeltaTests {
            @Test func skippedFrameEmitsNoBytes() {
                let compositor = Compositor()
                compositor.flush(CellBuffer(width: 4, height: 1))
                compositor.skip()
                #expect(compositor.flush(CellBuffer(width: 4, height: 1)) == .unchanged)
            }

            @Test func firstFrameRepaintsEverything() {
                let compositor = Compositor()
                let result = compositor.flush(CellBuffer(width: 4, height: 1))
                #expect(result.isFullRepaint)
            }
        }
        """

    static func todos() -> [Todo] {
        [
            Todo(id: 1, title: "Reproduce the full-repaint case", status: .done),
            Todo(id: 2, title: "Separate skip signal from buffer nil", status: .done),
            Todo(id: 3, title: "Add a regression test", status: .inProgress),
            Todo(id: 4, title: "Check the SSH byte counts again", status: .pending),
        ]
    }
}
