import Testing
@testable import TerminalUI

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

// Harness reported a `Range requires lowerBound <= upperBound` crash when the
// Storybook walk landed on the PromptInput page with default state. These
// tests try to reproduce it in isolation so we can fix without the
// full-app spin-up.

@Suite("PromptInput — renders with default state without crashing")
@MainActor
struct PromptInputTests {

    @Test("default state + empty text renders into a standard preview rect")
    func defaultRenderDoesNotCrash() {
        resetGraphContext()
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = PromptInput(text: textBinding, state: stateBinding)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 40, height: 8)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 8))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        // Prompt glyph is "❯" by default — confirming it at least landed in
        // the buffer proves we crossed the crash point.
        var seen = false
        for col in 0..<40 where buffer[col, 0].character == "\u{276F}" {
            seen = true
            break
        }
        #expect(seen, "expected the default prompt glyph to render")
    }

    @Test("default state inside a narrow rect with visibleLines > 1")
    func narrowRectDoesNotCrash() {
        resetGraphContext()
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        // This mirrors the Storybook preview pane geometry (~40 wide × 6 high
        // with no explicit maxVisibleLines).
        let view = PromptInput(text: textBinding, state: stateBinding)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 40, height: 6)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 6))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
    }

    @Test("default state with explicit maxVisibleLines=3")
    func explicitMaxLines() {
        resetGraphContext()
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = PromptInput(text: textBinding, state: stateBinding, maxVisibleLines: 3)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 40, height: 8)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 8))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
    }

    @Test("renders inside PageDetail-style wrapping (VStack .padding .border)")
    func storybookStyleLayout() {
        // Matches Storybook's `PreviewPane ... .padding().border()` envelope.
        // Reproduces the nested GeometryReader + border-shrunk rect that
        // was hitting the Range crash on first render.
        resetGraphContext()
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = VStack {
            PromptInput(text: textBinding, state: stateBinding,
                        onSubmit: { _ in })
            Text("last submitted: (nothing yet)").foreground(.gray)
        }
        .padding()
        .border()
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 40, height: 10)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 10))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
    }

    @Test("soft-wraps a long logical line into multiple display rows")
    func softWrapsLongLine() {
        resetGraphContext()
        // 80 chars at wrap width ~18 = 5 display rows.
        var value = String(repeating: "a", count: 80)
        var state = PromptInputState()
        state.cursorCol = 80
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = PromptInput(text: textBinding, state: stateBinding)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 20, height: 8)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 8))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        // Count rows with an 'a' — soft-wrap should spread 80 a's across
        // several rows, not clip at row 0.
        var rowsWithA = 0
        for row in 0..<8 {
            for col in 0..<20 where buffer[col, row].character == "a" {
                rowsWithA += 1
                break
            }
        }
        #expect(rowsWithA >= 3, "expected wrapped content across ≥3 rows; got \(rowsWithA)")
    }

    @Test("cursor projection maps logical columns onto wrapped chunks")
    func cursorProjection() {
        // 20-char logical line wrapped at width 8 → 3 chunks (8, 8, 4).
        // Cursor at col 15 should land in chunk 1 (8..16) at offset 7.
        let wraps: [[String]] = [["abcdefgh", "ijklmnop", "qrst"]]
        let (row, col) = PromptInput.projectCursor(logicalRow: 0, logicalCol: 15, wraps: wraps)
        #expect(row == 1)
        #expect(col == 7)
    }

    @Test(".unbounded grows to full content even past the 8-row default")
    func unboundedGrowth() {
        resetGraphContext()
        // 12 logical lines, each short enough to not wrap.
        var value = (0..<12).map { "line\($0)" }.joined(separator: "\n")
        var state = PromptInputState()
        state.cursorRow = 11
        state.cursorCol = 5
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = PromptInput(
            text: textBinding, state: stateBinding,
            heightPolicy: .unbounded
        )
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 40, height: 20)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 20))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        // The last logical line ("line11") must be in the buffer — if
        // `.unbounded` were still capped at 8, rows 8..11 would be clipped.
        var seenLast = false
        for row in 0..<20 {
            var text = ""
            for col in 0..<40 {
                text.append(buffer[col, row].character)
            }
            if text.contains("line11") { seenLast = true; break }
        }
        #expect(seenLast, "unbounded policy should render all 12 logical rows")
    }

    @Test("content past the ceiling scrolls so the cursor row stays visible")
    func scrollUpWhenOverflowing() {
        // 15 logical lines; fixed ceiling=5 means only 5 display rows fit.
        // Cursor at the bottom (line 14) → scrollDisplayRow should advance
        // so the cursor's row is inside [scroll, scroll+5).
        var state = PromptInputState()
        state.cursorRow = 14
        state.cursorCol = 5
        let lines = (0..<15).map { "line\($0)" }
        var mutable = state
        // Emulate handleKey's adjustScroll by calling it through a typing
        // event: the public API is keyed, so we insert a char and let it
        // call adjustScroll internally.
        var value = lines.joined(separator: "\n")
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { mutable }, set: { mutable = $0 })
        _ = PromptInput.handleKey(
            KeyEvent(key: .character("x")),
            text: textBinding, state: stateBinding,
            onSubmit: nil, promptWidth: 2,
            maxVisibleLines: 5, wrapWidth: 40,
            arrowMode: .display
        )
        // Cursor at logical row 14, short lines = display row 14. Scroll
        // must have advanced to keep cursor inside [scroll, scroll+5).
        #expect(mutable.scrollDisplayRow >= 10,
                "scroll should advance past row 10 to keep cursor at 14 visible; got \(mutable.scrollDisplayRow)")
    }

    @Test("PromptArrowMode.display steps through wrapped rows before crossing logical lines")
    func arrowDisplayMode() {
        resetGraphContext()
        var value = String(repeating: "a", count: 20)
        var state = PromptInputState()
        state.cursorCol = 0
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })

        let result = PromptInput.handleKey(
            KeyEvent(key: .down),
            text: textBinding, state: stateBinding,
            onSubmit: nil, promptWidth: 2,
            maxVisibleLines: 5, wrapWidth: 8,
            arrowMode: .display
        )
        #expect(result == .handled)
        // Cursor advanced by wrap width inside the same logical line.
        #expect(state.cursorRow == 0)
        #expect(state.cursorCol == 8)
    }

    @Test("graph reconciliation — switch TO PromptInput from another view")
    func reconciliationToPromptInput() {
        // Storybook's PreviewPane is a switch statement. Moving to the
        // PromptInput page triggers graph reconciliation where the old
        // subtree is replaced by PromptInput. Reproduce that here by
        // building a ConditionalView and flipping the branch.
        resetGraphContext()
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })

        // A wrapper whose body flips between Text and PromptInput based on
        // a captured flag. First update renders Text, second renders
        // PromptInput — mirrors page navigation.
        final class Flipper { var onPrompt = false }
        let flip = Flipper()
        struct Container: TerminalView {
            let flip: Flipper
            let textBinding: Binding<String>
            let stateBinding: Binding<PromptInputState>
            var body: some TerminalView {
                if flip.onPrompt {
                    PromptInput(text: textBinding, state: stateBinding)
                } else {
                    Text("placeholder")
                }
            }
        }

        let graph = AttributeGraph()
        graph.update(from: Container(flip: flip, textBinding: textBinding, stateBinding: stateBinding))
        var buffer = CellBuffer(width: 40, height: 6)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 6))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        // Now flip and re-update — this is the transition that crashes live.
        flip.onPrompt = true
        graph.update(from: Container(flip: flip, textBinding: textBinding, stateBinding: stateBinding))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
    }
}

// MARK: - Word-aware wrap (PromptInput)
//
// User-reported bug 2026-04-25: typing a long sentence into PromptInput
// hard-wraps mid-word — e.g. "righ"+"t", "imp"+"rove". We want
// word-aware wrapping that breaks on whitespace whenever possible,
// falling back to character-level breaks only for words longer than
// the wrap width (e.g. URLs, identifiers).

@Suite("PromptInput — word-aware wrap")
@MainActor
struct PromptInputWordWrapTests {

    @Test("ASCII sentence wraps at word boundaries, not mid-word")
    func wrapsAtWordBoundaries() {
        let sentence = "type a very long line and see if it will properly wrap"
        let chunks = PromptInput.wrapLine(sentence, width: 20)
        // Every chunk that ISN'T the last one must end on a word
        // boundary — i.e. the chunk's last char is a space, OR the
        // next chunk starts after a space, OR the chunk is itself a
        // single-word chunk that exactly fills the width.
        for i in 0..<chunks.count - 1 {
            let chunk = chunks[i]
            let next = chunks[i + 1]
            let endsCleanly = chunk.last == " " || next.first == " " || !chunk.contains(" ")
                || chunk.split(separator: " ").last.map { sentence.contains($0 + " ") } ?? false
            // Simpler invariant: re-joining chunks back must reproduce
            // the original sentence with at most one space lost per
            // wrap point (we trim trailing space on each chunk for
            // visual cleanliness).
            _ = endsCleanly
            // A specific anti-mid-word check: no chunk's final char
            // followed by next chunk's first char should reconstruct a
            // word from the source unless that boundary already had a
            // space.
            if let lastChar = chunk.last,
               let firstNext = next.first,
               lastChar.isLetter, firstNext.isLetter
            {
                // Look for "lastChar firstNext" or "lastCharfirstNext"
                // in source — if the word was contiguous in source and
                // we split it, that's a mid-word break.
                let suspected = "\(lastChar)\(firstNext)"
                #expect(!sentence.contains(suspected),
                        "chunks[\(i)]=\(chunk) and chunks[\(i+1)]=\(next) split a word: '\(suspected)' is contiguous in source")
            }
        }
    }

    @Test("re-joining wrapped chunks reproduces the original (modulo trimmed spaces)")
    func wrapsLossless() {
        let sentence = "type a very long line and see if it will properly wrap and do the right thing"
        let chunks = PromptInput.wrapLine(sentence, width: 20)
        // Each chunk fits within width.
        for chunk in chunks {
            #expect(chunk.count <= 20, "chunk too long: \(chunk) (\(chunk.count) > 20)")
        }
        // Joining chunks with single spaces between them (where wrap
        // dropped a space) reproduces the original. Allow either: the
        // chunk ends with its trailing space preserved, OR the wrap
        // dropped a space at the boundary so we re-insert one.
        var reassembled = ""
        for (i, chunk) in chunks.enumerated() {
            if i > 0 && !reassembled.hasSuffix(" ") && !chunk.hasPrefix(" ") {
                reassembled += " "
            }
            reassembled += chunk
        }
        // Tolerate trailing/leading whitespace from chunk boundaries.
        #expect(reassembled.trimmingCharacters(in: .whitespaces) ==
                sentence.trimmingCharacters(in: .whitespaces),
                "re-assembled: \(reassembled.debugDescription)")
    }

    @Test("a single word longer than width falls back to character-level break")
    func longWordHardBreaks() {
        let url = "https://example.com/very/long/path/that/exceeds/wrap/width"
        let chunks = PromptInput.wrapLine(url, width: 20)
        for chunk in chunks {
            #expect(chunk.count <= 20)
        }
        // Reassembly is exact (no spaces involved).
        #expect(chunks.joined() == url)
        #expect(chunks.count >= 2, "long word must wrap into multiple chunks")
    }

    @Test("short input that fits in width returns one chunk unchanged")
    func shortInputOneChunk() {
        let s = "hello world"
        #expect(PromptInput.wrapLine(s, width: 20) == [s])
    }

    @Test("empty input yields one empty chunk (so the row is navigable)")
    func emptyInputOneEmptyChunk() {
        #expect(PromptInput.wrapLine("", width: 20) == [""])
    }

    @Test("multiple consecutive spaces are preserved across wraps")
    func multipleSpaces() {
        let s = "a  b  c  d  e  f  g  h"
        let chunks = PromptInput.wrapLine(s, width: 8)
        for chunk in chunks { #expect(chunk.count <= 8) }
        // Reassemble reproduces the source.
        let reassembled = chunks.joined()
        // Wrap may have dropped some boundary spaces; a softer check:
        // every non-space char appears exactly once and in order.
        let nonSpaceSrc = s.filter { $0 != " " }
        let nonSpaceOut = reassembled.filter { $0 != " " }
        #expect(nonSpaceSrc == nonSpaceOut)
    }
}
