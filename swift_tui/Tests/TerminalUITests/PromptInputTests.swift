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
