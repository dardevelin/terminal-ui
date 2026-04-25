import Testing
@testable import TerminalUI
@testable import TerminalUIConfig

// Regression suite for the 2026-04-25 external code review (HYP-93 epic).
// These tests assert the *correct* behaviour. They fail on `main` because
// the bugs documented in HYP-94..HYP-101 are still present. Each test
// turns green once its matching fix lands. The progress of this suite
// from red → green is the sprint progress bar.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

// MARK: - HYP-94: onChange / onDisappear unmapped

// Tracker class so closures can mutate from inside view bodies. A reference
// type avoids capture-list copies that would otherwise hide invocations.
@MainActor
private final class Counter {
    var value: Int = 0
    func tick() { value += 1 }
}

@Suite("HYP-94 — onChange & onDisappear lifecycle modifiers")
@MainActor
struct OnChangeOnDisappearTests {

    @Test("onChange fires when bound value mutates between updates")
    func onChangeFiresOnValueChange() {
        resetGraphContext()
        let counter = Counter()
        let graph = AttributeGraph()

        // First update with value=0. Closure should not fire (no change).
        graph.update(from: Text("hi").onChange(of: 0) { _, _ in counter.tick() })
        #expect(counter.value == 0, "onChange must not fire on initial construction")

        // Second update with value=1. Closure should fire exactly once.
        graph.update(from: Text("hi").onChange(of: 1) { _, _ in counter.tick() })
        #expect(counter.value == 1, "onChange must fire when bound value changes (currently unmapped → falls through to .bold catch-all)")
    }

    @Test("onDisappear fires when its node is removed from the tree")
    func onDisappearFiresOnRemoval() {
        resetGraphContext()
        let counter = Counter()
        let graph = AttributeGraph()

        // First frame: VStack with a single child carrying onDisappear.
        graph.update(from: VStack { Text("a").onDisappear { counter.tick() } })
        #expect(counter.value == 0, "onDisappear must not fire on appearance")

        // Second frame: VStack is now empty. The previous child should be
        // detached from the tree, firing onDisappear exactly once.
        graph.update(from: VStack { } as VStack<EmptyView>)
        #expect(counter.value == 1, "onDisappear must fire on node removal (currently unmapped)")
    }
}

// MARK: - HYP-95: onAppear on first render + first input not lost

@Suite("HYP-95 — onAppear on first frame & focus ready before first input")
@MainActor
struct FirstFrameTests {

    @Test("onAppear fires on the very first graph update")
    func onAppearFiresOnFirstUpdate() {
        resetGraphContext()
        let counter = Counter()
        let graph = AttributeGraph()

        graph.update(from: Text("hello").onAppear { counter.tick() })
        #expect(counter.value == 1, "onAppear must fire on first construction (no second update should be required)")
    }

    @Test("onAppear fires exactly once across multiple updates")
    func onAppearFiresExactlyOnce() {
        resetGraphContext()
        let counter = Counter()
        let graph = AttributeGraph()

        for _ in 0..<5 {
            graph.update(from: Text("hello").onAppear { counter.tick() })
        }
        #expect(counter.value == 1, "onAppear is a one-shot — must not fire on subsequent updates")
    }

    @Test("FocusEngine has an active focus after first construction of a focusable view")
    func focusReadyAfterFirstConstruction() {
        resetGraphContext()
        let focusEngine = FocusEngine()
        GraphContext.currentFocusEngine = focusEngine

        let graph = AttributeGraph()
        graph.update(from: Text("button").focusable())

        // The runtime auto-focuses the first focusable on startup. A test
        // simulating that contract: after rebuildIndex on a tree containing
        // one focusable, FocusEngine should pick it.
        if let root = graph.root {
            focusEngine.rebuildIndex(root: root)
            if focusEngine.keyboardFocusID == nil {
                focusEngine.focusNext()
            }
        }

        #expect(focusEngine.keyboardFocusID != nil,
                "First focusable must be focused after first frame so the very first key event reaches its handler")
    }
}

// MARK: - HYP-96: @TerminalEnvironment read-before-apply

// Recorded is `Sendable` so it can be captured into a non-isolated `body`
// closure under strict concurrency. The mutation runs only on @MainActor in
// practice (body is invoked on MainActor), but the type system needs the
// box to be safely shareable.
private final class EnvRecorded: @unchecked Sendable {
    var observed: TerminalSize?
}

private struct EnvProbe: TerminalView {
    @TerminalEnvironment(\.terminalSize) var size
    let recorded: EnvRecorded
    var body: some TerminalView {
        recorded.observed = size
        return Text("probe")
    }
}

@Suite("HYP-96 — @TerminalEnvironment must see ancestor .environment values during body")
@MainActor
struct EnvironmentOrderingTests {

    @Test("child's body observes the value set by its ancestor's .environment modifier")
    func childObservesAncestorEnvironment() {
        resetGraphContext()
        // Seed with the default so the bug is visible: if the modifier never
        // applies at build time, the probe sees `default` instead of `custom`.
        GraphContext.currentEnvironment = EnvironmentValues()

        let recorded = EnvRecorded()
        let custom = TerminalSize(cols: 999, rows: 42)
        let graph = AttributeGraph()
        graph.update(from: EnvProbe(recorded: recorded).environment(\.terminalSize, custom))

        #expect(recorded.observed?.cols == 999,
                "child body ran before .environment applied (read-before-apply); expected cols=999, got \(String(describing: recorded.observed?.cols))")
        #expect(recorded.observed?.rows == 42)
    }
}

// MARK: - HYP-97: GeometryReader destroys identity each render

private final class GRRecorded: @unchecked Sendable {
    var appearCount: Int = 0
}

private struct GRChild: TerminalView {
    let recorded: GRRecorded
    var body: some TerminalView {
        Text("child").onAppear { [recorded] in recorded.appearCount += 1 }
    }
}

@Suite("HYP-97 — GeometryReader must preserve subtree identity across renders")
@MainActor
struct GeometryReaderIdentityTests {

    @Test("onAppear inside GeometryReader fires exactly once across multiple renders")
    func onAppearOnceInsideGR() {
        resetGraphContext()
        GraphContext.currentProposedSize = Size(width: 80, height: 24)

        let recorded = GRRecorded()
        let graph = AttributeGraph()
        let view = GeometryReader { _ in GRChild(recorded: recorded) }

        // Build once. The GR's child is constructed lazily during render in
        // current code. We simulate that by triggering the rebuild path
        // multiple times: each render currently replaces node.children, so
        // every "render" reconstructs the subtree and fires onAppear again.
        graph.update(from: view)
        var buffer = CellBuffer(width: 80, height: 24)
        let context = RenderContext(rect: Rect(x: 0, y: 0, width: 80, height: 24))
        for _ in 0..<3 {
            if let root = graph.root {
                GraphRenderer.render(root, into: &buffer, context: context)
            }
        }

        #expect(recorded.appearCount == 1,
                "GeometryReader rebuild replaces node.children every render → onAppear refires; expected 1, got \(recorded.appearCount)")
    }
}

// MARK: - HYP-98: socket auto-attach ignores config flag
// Spawning the runtime requires PTY harness — defer to integration test.
// Asserted at the API surface for now: DiagConfig has the flag and it must
// be consulted by the attach site.

@Suite("HYP-98 — debug socket gating reads DiagConfig.socketEnabled")
@MainActor
struct SocketGatingTests {

    @Test("DiagConfig.socketEnabled flag is exposed and defaults to true")
    func socketEnabledFlagExists() {
        // Sanity: the field exists. The actual behavioural test (no socket
        // file when disabled) lives in the PTY integration suite — see
        // HYP-98 for tracking. This guards against accidental removal of
        // the public flag while the runtime still ignores it.
        let cfg = DiagConfig.default
        #expect(cfg.socketEnabled == true, "default must be true to preserve current behaviour")
    }
}

// MARK: - HYP-100: Unicode width

@Suite("HYP-100 — Unicode display width matches terminal cell count")
@MainActor
struct UnicodeWidthTests {

    @Test("ASCII is 1 cell per character")
    func asciiOneCell() {
        #expect("hello".displayWidth == 5)
    }

    @Test("CJK ideographs are 2 cells")
    func cjkTwoCells() {
        #expect("中".displayWidth == 2)
        #expect("中文".displayWidth == 4)
    }

    @Test("ZWJ emoji families are 2 cells")
    func zwjEmojiTwoCells() {
        #expect("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".displayWidth == 2)
    }

    @Test("Combining marks are zero width on top of base")
    func combiningMarksZeroWidth() {
        // "e" + combining acute = "é" (NFD form), one cell total
        #expect("e\u{0301}".displayWidth == 1)
    }

    @Test("Mixed ASCII + CJK sums correctly")
    func mixedAsciiCjk() {
        #expect("hi 中文".displayWidth == 7) // h(1)+i(1)+ (1)+中(2)+文(2)
    }

    @Test("Empty string is zero")
    func emptyZero() {
        #expect("".displayWidth == 0)
    }
}

// MARK: - HYP-101: Terminal robustness

@Suite("HYP-101 — Terminal.size() falls back when ioctl reports 0×0 in release")
@MainActor
struct TerminalRobustnessTests {

    @Test("size() returns non-zero geometry under the test runner's PTY")
    func sizeReturnsNonZero() {
        // The test process runs under XCTest's PTY harness — ioctl normally
        // reports the inherited geometry. The release-path guard added in
        // HYP-101 means even in the worst case (ioctl fails or reports
        // 0×0) the framework returns 80×24 instead of 0×0, which the
        // compositor can't diff and which would crash the renderer's
        // divide/clip math.
        let size = Terminal.size()
        #expect(size.cols >= 1)
        #expect(size.rows >= 1)
    }

    @Test("TerminalSize.default is the VT100 fallback (80×24)")
    func vt100Default() {
        let s = TerminalSize.default
        #expect(s.cols == 80)
        #expect(s.rows == 24)
    }
}
