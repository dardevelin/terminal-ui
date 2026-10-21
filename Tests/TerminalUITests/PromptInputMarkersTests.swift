import Testing
@testable import TerminalUI

// PromptInput paste markers (Claude Code parity).
//   * Paste with newlines OR > 200 chars collapses to `[Pasted text #N +M lines]`.
//   * Buffer pool dedupes by content hash.
//   * "Paste again to expand" — re-paste of same content adjacent to a
//     collapsed reference flips it expanded.
//   * Backspace at right edge of marker = atomic delete of underlying
//     range; buffer stays in pool.
//   * Submit sends pristine expanded text (markers stripped).
//   * History snapshot preserves references + buffers; ↑ recall restores them.

@Suite("PromptInput — paste markers")
@MainActor
struct PromptInputMarkersTests {

    private func paste(_ payload: String, into text: Binding<String>, state: Binding<PromptInputState>, mode: PasteMode = .claudeCode) {
        PromptInput.handlePaste(payload, text: text, state: state, maxVisibleLines: 8, wrapWidth: 80, pasteMode: mode)
    }

    @Test("Multi-line paste registers a Buffer + collapsed Reference")
    func multilineRegistersReference() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste("line one\nline two\nline three", into: textBinding, state: stateBinding)

        #expect(state.buffers.count == 1, "one buffer registered")
        #expect(state.references.count == 1, "one reference registered")
        #expect(state.references.first?.isExpanded == false, "marker collapsed by default")
        // Binding holds expanded text always.
        #expect(value.contains("line one"))
        #expect(value.contains("line three"))
    }

    @Test("Single-line short paste does NOT register a reference")
    func shortSingleLineSkipsCollapse() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste("hello", into: textBinding, state: stateBinding)

        #expect(state.buffers.isEmpty, "short paste below threshold → no buffer")
        #expect(state.references.isEmpty, "short paste below threshold → no reference")
        #expect(value == "hello")
    }

    @Test("Single-line long paste (> 200 chars) DOES collapse")
    func longSingleLineCollapses() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste(String(repeating: "A", count: 250), into: textBinding, state: stateBinding)

        #expect(state.references.count == 1, "long single-line crosses char threshold")
        #expect(state.references.first?.isExpanded == false)
    }

    @Test(".inline mode skips collapse entirely")
    func inlineModeNoCollapse() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste("multi\nline\npaste", into: textBinding, state: stateBinding, mode: .inline)

        #expect(state.references.isEmpty, ".inline mode never collapses")
    }

    @Test(".alwaysPlaceholder collapses every paste")
    func alwaysPlaceholderForcesCollapse() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste("hi", into: textBinding, state: stateBinding, mode: .alwaysPlaceholder)

        #expect(state.references.count == 1, ".alwaysPlaceholder collapses even tiny pastes")
    }

    @Test("Buffer dedupe — same content twice reuses buffer ID")
    func bufferDedupe() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste("aaa\nbbb", into: textBinding, state: stateBinding)
        // Type a separator character so the next paste isn't adjacent
        // to the first reference's right edge — otherwise the
        // "paste again to expand" path fires instead of dedupe.
        // Drive a character key event so cursor + reference state
        // update via the real handler.
        _ = PromptInput.handleKey(
            KeyEvent(key: .character(" ")),
            text: textBinding,
            state: stateBinding,
            onSubmit: nil,
            promptWidth: 2,
            maxVisibleLines: 8,
            wrapWidth: 80
        )
        paste("aaa\nbbb", into: textBinding, state: stateBinding)
        // Two distinct references, but they share a single buffer.
        #expect(state.buffers.count == 1, "same payload → single buffer")
        #expect(state.references.count == 2, "two insertions → two references")
        let bufferIDs = Set(state.references.map(\.bufferID))
        #expect(bufferIDs.count == 1, "both references point to the same buffer")
    }

    @Test("Backspace at right edge of marker atomic-deletes the range")
    func backspaceAtomicDelete() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste("multi\nline\nblob", into: textBinding, state: stateBinding)
        #expect(state.references.count == 1)
        let originalLength = value.count

        // Cursor sits at the right edge of the just-inserted reference.
        // Drive a backspace event through handleKey.
        let result = PromptInput.handleKey(
            KeyEvent(key: .backspace),
            text: textBinding,
            state: stateBinding,
            onSubmit: nil,
            promptWidth: 2,
            maxVisibleLines: 8,
            wrapWidth: 80
        )
        #expect(result == .handled)
        #expect(state.references.isEmpty, "reference removed by atomic delete")
        #expect(state.buffers.count == 1, "buffer stays in pool — re-applicable")
        #expect(value.count < originalLength, "underlying range was removed")
    }

    @Test("Submit sends expanded text and snapshots references in history")
    func submitSnapshotsReferences() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste("multi\nline", into: textBinding, state: stateBinding)
        let beforeSubmit = value
        var submittedText: String?
        let result = PromptInput.handleKey(
            KeyEvent(key: .enter),
            text: textBinding,
            state: stateBinding,
            onSubmit: { submittedText = $0 },
            promptWidth: 2,
            maxVisibleLines: 8,
            wrapWidth: 80
        )
        #expect(result == .handled)
        #expect(submittedText == beforeSubmit, "onSubmit receives expanded text")
        #expect(state.history.count == 1)
        #expect(state.history[0].references.count == 1, "history entry preserves the reference")
        #expect(value == "", "binding cleared after submit")
        #expect(state.references.isEmpty, "live references cleared after submit; buffer pool retained")
    }

    @Test("Marker label format: multi-line uses `+M lines`")
    func markerFormatMultiLine() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste("a\nb\nc\nd", into: textBinding, state: stateBinding)
        let ref = state.references[0]
        let label = PromptInput.markerLabel(for: ref, buffers: state.buffers)
        #expect(label == "[Pasted text #1 +4 lines]")
    }

    @Test("Marker label format: single-line uses `+M chars`")
    func markerFormatSingleLine() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste(String(repeating: "x", count: 250), into: textBinding, state: stateBinding)
        let ref = state.references[0]
        let label = PromptInput.markerLabel(for: ref, buffers: state.buffers)
        #expect(label == "[Pasted text #1 +250 chars]")
    }

    @Test("Render projection replaces collapsed reference with marker text")
    func renderProjection() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste("alpha\nbeta\ngamma", into: textBinding, state: stateBinding)

        let projection = PromptInput.projectCollapsedDisplay(
            expandedText: value, references: state.references, buffers: state.buffers)
        #expect(projection.displayText.contains("[Pasted text #1 +3 lines]"))
        #expect(!projection.displayText.contains("alpha"), "expanded payload not visible while collapsed")
    }

    @Test("Render projection falls through when reference is expanded")
    func renderProjectionExpanded() {
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        paste("alpha\nbeta", into: textBinding, state: stateBinding)
        state.references[0].isExpanded = true

        let projection = PromptInput.projectCollapsedDisplay(
            expandedText: value, references: state.references, buffers: state.buffers)
        #expect(projection.displayText.contains("alpha"), "expanded reference renders inline")
        #expect(!projection.displayText.contains("[Pasted text"), "no marker when expanded")
    }
}
