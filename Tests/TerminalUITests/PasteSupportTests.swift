import Testing
@testable import TerminalUI

// HYP-211 — bracketed-paste support across TextInput / TextArea / PromptInput.
//
// Three layers of coverage:
//   1. FocusEngine.routePasteEvent — payload reaches the focused subtree's
//      .onPaste handler; falls back to no-op when nothing claims it.
//   2. Per-component static paste handlers — the actual mutation logic
//      (newline strip, multi-row split, logical-line insert) tested in
//      isolation via Binding-driven fixtures.
//   3. End-to-end through the focus engine — `.onPaste` modifier wired
//      to a real component view, payload routed to it, binding mutates.

@MainActor
private func driveGraph<V: TerminalView>(_ view: V) -> (FocusEngine, AttributeGraph) {
    let graph = AttributeGraph()
    let engine = FocusEngine()
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
        }
    }
    engine.rebuildIndex(root: graph.root!)
    engine.focusNext()
    return (engine, graph)
}

@Suite("FocusEngine.routePasteEvent — dispatch to focused subtree")
@MainActor
struct PasteRoutingTests {

    @Test("Payload reaches the focused node's .onPaste handler")
    func payloadReachesHandler() {
        final class Captured: @unchecked Sendable {
            nonisolated(unsafe) var value: String?
        }
        let captured = Captured()

        // Use a plain focusable Text so the only .onPaste in the chain
        // is ours — TextInput would attach its own inner handler that
        // wins ancestor-walk priority for being closer to the focus.
        let view = Text("typing")
            .focusable()
            .onPaste { payload in captured.value = payload }

        let (engine, graph) = driveGraph(view)
        let claimed = engine.routePasteEvent("hello", root: graph.root)

        #expect(claimed, "routePasteEvent must report a handler claimed the payload")
        #expect(captured.value == "hello", "captured payload should be 'hello'")
    }

    @Test("End-to-end: paste through real TextInput mutates its binding")
    func realTextInputE2E() {
        var value = "ab"
        let binding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: binding)

        let (engine, graph) = driveGraph(view)
        let claimed = engine.routePasteEvent("CD", root: graph.root)

        #expect(claimed, "TextInput's built-in .onPaste should claim the payload")
        #expect(value == "abCD", "binding should reflect the inserted paste")
    }

    @Test("No focused node → routePasteEvent returns false")
    func noFocusedNode() {
        let view = Text("idle")  // no focusable descendants

        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)
        // Deliberately do NOT focusNext()

        let claimed = engine.routePasteEvent("anything", root: graph.root)
        #expect(!claimed, "no keyboardFocusID → drop on the floor")
    }

    @Test("Focused node without .onPaste → drop on the floor")
    func focusedButNoPasteHandler() {
        // TextInput is focusable but has its own .onPaste; wrap a plain
        // .focusable() to prove the no-handler fallback path.
        let view = Text("typing").focusable()

        let (engine, graph) = driveGraph(view)
        let claimed = engine.routePasteEvent("ignored", root: graph.root)

        #expect(!claimed, "focusable without .onPaste → no claim")
    }
}

@Suite("TextInput.handlePaste — single-line semantics")
@MainActor
struct TextInputPasteTests {

    @Test("Plain payload inserts at cursor, advances cursor")
    func insertAtCursor() {
        var value = "ab"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var cursorState = 2
        let cursorBinding = Binding(get: { cursorState }, set: { cursorState = $0 })

        TextInput.handlePaste("XYZ",
                              text: textBinding,
                              cursor: cursorBinding,
                              maxLength: nil,
                              boundaryMode: .bounce,
                              onBoundaryHit: nil)

        #expect(value == "abXYZ")
        #expect(cursorState == 5)
    }

    @Test("Embedded newlines collapse to spaces (single-line invariant)")
    func newlinesStrippedToSpaces() {
        var value = ""
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var cursorState = 0
        let cursorBinding = Binding(get: { cursorState }, set: { cursorState = $0 })

        TextInput.handlePaste("a\nb\r\nc",
                              text: textBinding,
                              cursor: cursorBinding,
                              maxLength: nil,
                              boundaryMode: .bounce,
                              onBoundaryHit: nil)

        // Every line terminator scalar becomes a space, so CRLF yields two.
        // Replacement runs over unicode scalars rather than Characters:
        // "\r\n" is one grapheme cluster equal to neither "\n" nor "\r",
        // so a per-Character map would leave it intact and a literal newline
        // would survive into a single-line field. The single-line guarantee
        // is what matters; whitespace shape is incidental.
        #expect(!value.contains("\n"))
        #expect(!value.contains("\r"))
        #expect(value.count == cursorState)
    }

    @Test("maxLength truncates and emits .maxLength boundary")
    func maxLengthTruncates() {
        final class Recorder: @unchecked Sendable {
            nonisolated(unsafe) var hits: [BoundaryHitReason] = []
        }
        let recorder = Recorder()
        let savedBounce = BoundaryFeedbackEmitter.shared.bounceSink
        BoundaryFeedbackEmitter.shared.bounceSink = { reason in
            recorder.hits.append(reason)
        }
        defer { BoundaryFeedbackEmitter.shared.bounceSink = savedBounce }

        var value = "ab"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var cursorState = 2
        let cursorBinding = Binding(get: { cursorState }, set: { cursorState = $0 })

        TextInput.handlePaste("XXXXX",
                              text: textBinding,
                              cursor: cursorBinding,
                              maxLength: 5,
                              boundaryMode: .bounce,
                              onBoundaryHit: nil)

        #expect(value == "abXXX")  // 5-char ceiling → 3 chars accepted
        #expect(cursorState == 5)
        #expect(recorder.hits == [.maxLength])
    }

    @Test("Empty payload is a no-op")
    func emptyPasteNoop() {
        var value = "untouched"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var cursorState = 4
        let cursorBinding = Binding(get: { cursorState }, set: { cursorState = $0 })

        TextInput.handlePaste("",
                              text: textBinding,
                              cursor: cursorBinding,
                              maxLength: nil,
                              boundaryMode: .bounce,
                              onBoundaryHit: nil)

        #expect(value == "untouched")
        #expect(cursorState == 4)
    }
}

@Suite("TextArea.handlePaste — multi-line splice")
@MainActor
struct TextAreaPasteTests {

    @Test("Single-line paste splices into current row, no new rows")
    func singleLinePaste() {
        var text = "hello world"
        let textBinding = Binding(get: { text }, set: { text = $0 })
        var st = TextAreaState()
        st.cursor = TextAreaCursor(row: 0, col: 5)
        let stateBinding = Binding(get: { st }, set: { st = $0 })

        TextArea.handlePaste(" big",
                             text: textBinding,
                             state: stateBinding,
                             visibleHeight: 10)

        #expect(text == "hello big world")
        #expect(st.cursor.row == 0)
        #expect(st.cursor.col == 9)  // "hello big" length
    }

    @Test("Multi-line paste splits into rows")
    func multiLinePaste() {
        var text = "first|last"
        let textBinding = Binding(get: { text }, set: { text = $0 })
        var st = TextAreaState()
        st.cursor = TextAreaCursor(row: 0, col: 5)  // between "first" and "|last"
        let stateBinding = Binding(get: { st }, set: { st = $0 })

        TextArea.handlePaste("alpha\nbeta\ngamma",
                             text: textBinding,
                             state: stateBinding,
                             visibleHeight: 10)

        // Expected splice:
        //   "firstalpha"
        //   "beta"
        //   "gamma|last"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines[0] == "firstalpha")
        #expect(lines[1] == "beta")
        #expect(lines[2] == "gamma|last")
        #expect(st.cursor.row == 2)
        #expect(st.cursor.col == 5)  // end of "gamma"
    }

    @Test("CRLF normalises to LF before splitting")
    func crlfNormalised() {
        var text = ""
        let textBinding = Binding(get: { text }, set: { text = $0 })
        var st = TextAreaState()
        let stateBinding = Binding(get: { st }, set: { st = $0 })

        TextArea.handlePaste("a\r\nb\r\nc",
                             text: textBinding,
                             state: stateBinding,
                             visibleHeight: 10)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines.map(String.init) == ["a", "b", "c"])
    }
}

@Suite("PromptInput.handlePaste — logical-row split")
@MainActor
struct PromptInputPasteTests {

    @Test("Single-line paste appends to current row")
    func singleLinePaste() {
        var text = "hi"
        let textBinding = Binding(get: { text }, set: { text = $0 })
        var st = PromptInputState()
        st.cursorRow = 0
        st.cursorCol = 2
        let stateBinding = Binding(get: { st }, set: { st = $0 })

        PromptInput.handlePaste(" world",
                                text: textBinding,
                                state: stateBinding,
                                maxVisibleLines: 5,
                                wrapWidth: 80)

        #expect(text == "hi world")
        #expect(st.cursorRow == 0)
        #expect(st.cursorCol == 8)
    }

    @Test("Multi-line paste produces logical newlines")
    func multiLinePaste() {
        var text = ""
        let textBinding = Binding(get: { text }, set: { text = $0 })
        var st = PromptInputState()
        let stateBinding = Binding(get: { st }, set: { st = $0 })

        PromptInput.handlePaste("line one\nline two\nline three",
                                text: textBinding,
                                state: stateBinding,
                                maxVisibleLines: 5,
                                wrapWidth: 80)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines.map(String.init) == ["line one", "line two", "line three"])
        #expect(st.cursorRow == 2)
        #expect(st.cursorCol == 10)  // "line three"
    }

    @Test("Paste resets historyIndex")
    func resetsHistoryIndex() {
        var text = ""
        let textBinding = Binding(get: { text }, set: { text = $0 })
        var st = PromptInputState()
        st.historyIndex = 3
        let stateBinding = Binding(get: { st }, set: { st = $0 })

        PromptInput.handlePaste("typed",
                                text: textBinding,
                                state: stateBinding,
                                maxVisibleLines: 5,
                                wrapWidth: 80)

        #expect(st.historyIndex == -1, "any text mutation drops the user out of history-recall mode")
    }
}

// "\r\n" is a SINGLE grapheme cluster in Swift, equal to neither "\n" nor
// "\r". A per-Character replacement therefore skips it entirely and a literal
// newline reaches a single-line field. This passed on macOS and failed on
// Linux purely by how the rest of the payload clustered — the invariant was
// broken on both.

@Suite("TextInput paste — line terminators are neutralised at scalar level")
@MainActor
struct PasteLineTerminatorTests {

    private func pasted(_ payload: String) -> String {
        var value = ""
        var cursorState = 0
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let cursorBinding = Binding(get: { cursorState }, set: { cursorState = $0 })
        TextInput.handlePaste(payload,
                              text: textBinding,
                              cursor: cursorBinding,
                              maxLength: nil,
                              boundaryMode: .bounce,
                              onBoundaryHit: nil)
        return value
    }

    @Test("CRLF does not survive as a grapheme cluster")
    func crlfNeutralised() {
        let value = pasted("a\r\nb")
        #expect(!value.contains("\n"), "literal LF survived CRLF: \(value.debugDescription)")
        #expect(!value.contains("\r"), "literal CR survived CRLF: \(value.debugDescription)")
        #expect(value == "a  b", "CRLF is two scalars → two spaces; got \(value.debugDescription)")
    }

    @Test("non-ASCII line terminators are neutralised too")
    func unicodeSeparatorsNeutralised() {
        // NEL, LINE SEPARATOR, PARAGRAPH SEPARATOR — a terminal renders each
        // as a break, so a single-line field must not carry them.
        for scalar in ["\u{0085}", "\u{2028}", "\u{2029}", "\u{000B}", "\u{000C}"] {
            let value = pasted("a\(scalar)b")
            #expect(value == "a b",
                    "scalar U+\(String(format: "%04X", scalar.unicodeScalars.first!.value)) not neutralised: \(value.debugDescription)")
        }
    }
}
