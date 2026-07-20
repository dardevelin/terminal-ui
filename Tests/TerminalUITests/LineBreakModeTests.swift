import Testing
@testable import TerminalUI

// `LineBreakMode` modifier for TextInput.
//
// HIG `apple-hig/components/text-fields.md` §"Adjust line breaks
// according to field needs":
//
//   "Default behavior: System clips text extending beyond field
//    bounds. Alternatives: Wrap text to new line at character or
//    word level; truncate with ellipsis at beginning, middle, or
//    end."
//
// Today TextInput always clips with virtual horizontal scroll
// (matches HIG default). Apps that want non-default break behaviour
// have no public knob — this ticket adds:
//   - `LineBreakMode` enum (six cases per HIG)
//   - `EnvironmentValues.lineBreakMode` (default `.byClipping`)
//   - `.lineBreakMode(_:)` modifier
//   - TextInput consults the env when composing spans

@Suite("LineBreakMode — enum + truncation helper")
@MainActor
struct LineBreakModeUnitTests {

    @Test("six cases per HIG prescription")
    func sixCases() {
        // Just confirms the enum exists with the expected cases.
        let modes: [LineBreakMode] = [
            .byClipping,
            .byCharWrapping,
            .byWordWrapping,
            .byTruncatingHead,
            .byTruncatingMiddle,
            .byTruncatingTail,
        ]
        #expect(modes.count == 6)
    }

    @Test("byTruncatingTail puts ellipsis at the end")
    func truncateTail() {
        let s = "this is a very long string"
        let out = LineBreakMode.byTruncatingTail.apply(to: s, width: 10)
        #expect(out.count == 10)
        #expect(out.hasSuffix("…"))
        #expect(s.hasPrefix(String(out.dropLast())),
                "leading characters preserved up to ellipsis; got '\(out)'")
    }

    @Test("byTruncatingHead puts ellipsis at the start")
    func truncateHead() {
        let s = "this is a very long string"
        let out = LineBreakMode.byTruncatingHead.apply(to: s, width: 10)
        #expect(out.count == 10)
        #expect(out.hasPrefix("…"))
        #expect(s.hasSuffix(String(out.dropFirst())),
                "trailing characters preserved after ellipsis; got '\(out)'")
    }

    @Test("byTruncatingMiddle puts ellipsis in the middle")
    func truncateMiddle() {
        let s = "this is a very long string"
        let out = LineBreakMode.byTruncatingMiddle.apply(to: s, width: 11)
        #expect(out.count == 11)
        #expect(out.contains("…"))
        // Should preserve some chars from both ends.
        let parts = out.split(separator: "…")
        #expect(parts.count == 2,
                "expected exactly one ellipsis; got '\(out)'")
        if let first = parts.first, let last = parts.last {
            #expect(s.hasPrefix(String(first)),
                    "head preserved; got '\(out)'")
            #expect(s.hasSuffix(String(last)),
                    "tail preserved; got '\(out)'")
        }
    }

    @Test("byClipping returns the leading prefix")
    func clip() {
        let s = "this is a very long string"
        let out = LineBreakMode.byClipping.apply(to: s, width: 10)
        #expect(out == "this is a ")
    }

    @Test("strings shorter than width are returned unchanged")
    func shorterThanWidth() {
        let s = "hello"
        for mode in LineBreakMode.allCases {
            #expect(mode.apply(to: s, width: 10) == s,
                    "mode \(mode) modified short string: '\(mode.apply(to: s, width: 10))'")
        }
    }

    @Test("byCharWrapping splits to multi-row chunks")
    func charWrap() {
        let s = "abcdefghij"
        let chunks = LineBreakMode.byCharWrapping.wrap(s, width: 4)
        #expect(chunks == ["abcd", "efgh", "ij"])
    }

    @Test("byWordWrapping uses TextLayout.wrapWords")
    func wordWrap() {
        let s = "hello world foo bar"
        let chunks = LineBreakMode.byWordWrapping.wrap(s, width: 10)
        // Same contract as TextLayout.wrapWords — at least 2 chunks,
        // no mid-word splits.
        #expect(chunks.count >= 2)
        for chunk in chunks {
            #expect(chunk.count <= 10)
        }
    }
}

@Suite("LineBreakMode — env propagation + .lineBreakMode() modifier")
@MainActor
struct LineBreakModeEnvTests {

    @Test("default env value is .byClipping (HIG default)")
    func defaultIsClipping() {
        let env = EnvironmentValues()
        #expect(env.lineBreakMode == .byClipping)
    }

    @Test(".lineBreakMode(_:) modifier overrides env for descendants")
    func modifierSetsEnv() {
        // Probe view reads the env value during body. After ancestor
        // applies `.lineBreakMode(.byTruncatingTail)`, the probe must
        // see that value (not the default). Same shape as the
        // environment read-before-apply ordering tests.

        final class Recorded: @unchecked Sendable {
            var observed: LineBreakMode?
        }
        struct Probe: TerminalView {
            @TerminalEnvironment(\.lineBreakMode) var mode
            let recorded: Recorded
            var body: some TerminalView {
                recorded.observed = mode
                return Text("p")
            }
        }
        let r = Recorded()
        let graph = AttributeGraph()
        // Bind a fresh default environment for the body-eval scope so
        // the modifier walk has a concrete baseline to mutate.
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: Probe(recorded: r).lineBreakMode(.byTruncatingTail))
        }
        #expect(r.observed == .byTruncatingTail,
                "child read \(String(describing: r.observed)); expected .byTruncatingTail")
    }
}

// MARK: - TextInput integration

@Suite("LineBreakMode — TextInput integration")
@MainActor
struct LineBreakModeTextInputTests {

    @Test("default (byClipping) renders the tail of a long value with cursor pinned right")
    func clippingDefault() {
        // Long value, narrow rect — TextInput's existing "virtual
        // horizontal scroll" keeps the cursor at the right edge,
        // dropping the leading characters. This is the HIG default
        // and `.byClipping` preserves the legacy behaviour byte-for-byte.
        var value = "this is a very long input value"
        var validation: TextInputValidation? = nil
        let textBinding = Binding(get: { value }, set: { value = $0 })
        _ = validation
        let view = TextInput(text: textBinding)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 12, height: 3)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 12, height: 3))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        var row = ""
        for c in 0..<12 { row.append(buffer[c, 0].character) }
        #expect(row.contains("value"),
                "byClipping must show the tail of the value (cursor pinned right); got '\(row)'")
    }

    @Test("byTruncatingTail shows leading chars + ellipsis")
    func truncatingTail() {
        var value = "this is a very long input value"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: textBinding)
            .lineBreakMode(.byTruncatingTail)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 12, height: 3)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 12, height: 3))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        var row = ""
        for c in 0..<12 { row.append(buffer[c, 0].character) }
        #expect(row.contains("…"),
                "byTruncatingTail must include an ellipsis; got '\(row)'")
        #expect(row.contains("this"),
                "byTruncatingTail must show the leading chars; got '\(row)'")
    }

    @Test("byTruncatingHead shows ellipsis + trailing chars")
    func truncatingHead() {
        var value = "this is a very long input value"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: textBinding)
            .lineBreakMode(.byTruncatingHead)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 12, height: 3)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 12, height: 3))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        var row = ""
        for c in 0..<12 { row.append(buffer[c, 0].character) }
        #expect(row.contains("…"),
                "byTruncatingHead must include an ellipsis; got '\(row)'")
        #expect(row.contains("value"),
                "byTruncatingHead must show the trailing chars; got '\(row)'")
    }

    @Test("byTruncatingMiddle shows head + ellipsis + tail")
    func truncatingMiddle() {
        var value = "this is a very long input value"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: textBinding)
            .lineBreakMode(.byTruncatingMiddle)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 13, height: 3)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 13, height: 3))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        var row = ""
        for c in 0..<13 { row.append(buffer[c, 0].character) }
        #expect(row.contains("…"),
                "byTruncatingMiddle must include an ellipsis; got '\(row)'")
        #expect(row.contains("th"),
                "byTruncatingMiddle must show the head; got '\(row)'")
        #expect(row.contains("ue"),
                "byTruncatingMiddle must show the tail; got '\(row)'")
    }
}

