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
            files: files(),
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
                output: "482 lines"
            )),
            .tool(ToolCall(
                id: 4,
                name: "Grep",
                summary: "previousBuffer = nil",
                state: .success,
                output: "Compositor.swift:311\nCompositor.swift:408"
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
                output: "+14 −6"
            )),
            .tool(ToolCall(
                id: 7,
                name: "Bash",
                summary: "swift test --filter Compositor",
                state: .pending,
                output: nil
            )),
        ]
    }

    static func resources() -> [Resource] {
        [
            Resource(id: 1, name: "sourcekit-lsp", health: .online, detail: "ready"),
            Resource(id: 2, name: "gopls", health: .offline, detail: "not started"),
            Resource(id: 3, name: "filesystem", health: .online, detail: "12 tools"),
            Resource(id: 4, name: "github", health: .busy, detail: "starting…"),
            Resource(id: 5, name: "postgres", health: .failed, detail: "auth failed"),
        ]
    }

    static func files() -> [TouchedFile] {
        [
            TouchedFile(id: 1, path: "Rendering/Compositor.swift", added: 14, removed: 6),
            TouchedFile(id: 2, path: "Core/FrameStats.swift", added: 3, removed: 1),
            TouchedFile(id: 3, path: "Tests/CompositorTests.swift", added: 41, removed: 0),
        ]
    }

    static func todos() -> [Todo] {
        [
            Todo(id: 1, title: "Reproduce the full-repaint case", status: .done),
            Todo(id: 2, title: "Separate skip signal from buffer nil", status: .done),
            Todo(id: 3, title: "Add a regression test", status: .inProgress),
            Todo(id: 4, title: "Check the SSH byte counts again", status: .pending),
        ]
    }
}
