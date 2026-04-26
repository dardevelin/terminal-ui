import Testing
@testable import TerminalUI

// Failing tests that pin each genuinely-open issue against the
// current codebase. Each test should fail or fail-to-compile until
// its issue is addressed; passing means the work is done.
//
// Tests are organised by feature-area (List/TreeView virtualization,
// MouseFocusPolicy, CellBuffer blit, GlobalShortcuts, responsive
// sizing, scrollbar thumb-track). The bindings-in-GR-closure sweep
// and the `[Any]` boxing rewrite need deeper test design — they're
// handled later in their own focused passes.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

// MARK: - List virtualization probe
//
// `List.renderList` calls `Array(data)` to materialize the entire
// input sequence regardless of how many rows are actually visible.
// For a 10-row viewport over a 10,000-row source, that allocates
// and walks all 10,000 entries. The fix is lazy materialization
// bounded by the visible window.
//
// Probe: custom RandomAccessCollection that counts how many times
// `subscript(_:)` and the iterator are touched. Assert that for a
// 10-row viewport the count is bounded by `visibleCount + indicators`,
// not `total`.

private final class AccessCounter: @unchecked Sendable {
    var subscriptCount = 0
    var iteratorAdvanceCount = 0
}

private struct CountingItem: Identifiable {
    let id: Int
}

private struct CountingCollection: RandomAccessCollection {
    typealias Element = CountingItem
    typealias Index = Int

    let total: Int
    let counter: AccessCounter

    var startIndex: Int { 0 }
    var endIndex: Int { total }

    subscript(position: Int) -> CountingItem {
        counter.subscriptCount += 1
        return CountingItem(id: position)
    }

    func index(after i: Int) -> Int { i + 1 }
    func index(before i: Int) -> Int { i - 1 }
    func index(_ i: Int, offsetBy distance: Int) -> Int { i + distance }
    func distance(from start: Int, to end: Int) -> Int { end - start }
}

@Suite("List — virtualization (currently materializes whole sequence)")
@MainActor
struct ListVirtualizationTests {

    @Test("rendering a 10-row viewport over 10,000 items must NOT touch all items")
    func listShouldNotMaterializeWholeSequence() {
        resetGraphContext()
        let counter = AccessCounter()
        let data = CountingCollection(total: 10_000, counter: counter)
        let graph = AttributeGraph()
        graph.update(from: List(data, visibleCount: 10) { item in
            Text("\(item.id)")
        })

        // SwiftUI parity (LazyVStack/LazyVGrid promise): only visible
        // items + a small overscan are materialized. Our promise:
        // bounded by visibleCount, never tied to total.
        //
        // Today this fails — `Array(data)` at List.swift:51 walks all
        // 10,000 elements, so subscriptCount ≈ 10,000.
        #expect(counter.subscriptCount < 100,
                "list rendered with visibleCount=10 should touch <100 items, not all 10,000; got \(counter.subscriptCount)")
    }
}

// MARK: - TreeView virtualization probe
//
// Same anti-pattern at `TreeView.swift:311` — `Array(data)` flattens
// the source roots regardless of how many branches are actually
// expanded. With most branches collapsed, the framework still walks
// every node.

// TreeView's public init constrains `data: Array<Element>` — a
// counting-Sequence probe can't slot in. The right test seam is
// dependency injection: the framework-internal materialize helper
// becomes test-overridable. Until that DI seam lands, this suite
// stays empty (the absence is the red signal). Drive the actual
// virtualization invariant via the smoke harness instead.
//
// See `feedback_test_seams_via_DI_or_smoke.md`. The DI seam IS the
// design spec — once `_materialize(_:visibleRange:)` exists and
// returns only the visible window, both List and TreeView tests
// can probe it directly.

// MARK: - MouseFocusPolicy enum
//
// Hard-coded `.clickToLock` semantics from the wheel-routing fix: mouse-move
// never moves keyboard focus, click promotes to keyboard focus, wheel
// routes to hover-target focusable. User direction (verbatim 2026-04-25):
// "the risk is after hover i might want to move the mouse" — implying
// configurable policy.
//
// Today: no public `MouseFocusPolicy` enum exists. The test below
// fails to compile until one is added.
//
// To enable: uncomment and run; the @Suite will fail-to-compile on
// the missing type, which IS the red phase.

@Suite("Mouse focus policy is configurable")
@MainActor
struct MouseFocusPolicyTests {
    @Test("MouseFocusPolicy enum is public and ships four cases")
    func mouseFocusPolicyEnumExists() {
        // The enum models four observable behaviours; the runtime
        // branches on these in handleMouseEvent.
        //   .clickToLock  — default. Hover does not move keyboard focus;
        //                   click promotes to keyboard focus; wheel
        //                   routes to hover-target focusable.
        //   .hoverFollows — hover ALSO sets keyboard focus.
        //   .clickOnly    — wheel routes to keyboard focus, not hover.
        //   .disabled     — framework gets out of the way: hover state
        //                   is not tracked, click does not auto-focus,
        //                   wheel does not auto-route. View callbacks
        //                   (.onHover / .onClick) still fire.
        let _: MouseFocusPolicy = .clickToLock
        let _: MouseFocusPolicy = .hoverFollows
        let _: MouseFocusPolicy = .clickOnly
        let _: MouseFocusPolicy = .disabled
    }

    @Test(".mouseFocusPolicy(_:) modifier compiles on any TerminalView")
    func mouseFocusPolicyModifierExists() {
        let _ = Text("probe").mouseFocusPolicy(.hoverFollows)
        let _ = Text("probe").mouseFocusPolicy(.disabled)
    }

    @Test(".onHover(_:) modifier compiles with SwiftUI-style closure")
    func onHoverModifierExists() {
        // SwiftUI's signature: { isHovering in … }. Callback is fired
        // on hover state transitions only (true on enter, false on leave).
        let _ = Text("probe").onHover { _ in }
    }
}

// MARK: - CellBuffer blit primitive
//
// Compile-probe pin for the public API surface. Behavioural tests
// (rect blit, clipping, paint-empty-cells, measurement) live in
// BufferViewTests.swift.

@Suite("CellBuffer blit primitive — render external buffer into view rect")
@MainActor
struct CellBufferBlitTests {
    @Test("BufferView accepts an external buffer at its public init")
    func cellBufferBlitExists() {
        let source = CellBuffer(width: 5, height: 3)
        let view = BufferView(source)
        _ = view
    }
}

// MARK: - Global shortcuts API
//
// Today only Ctrl+C is hardcoded at TerminalApp.swift:280-281. There
// is no `TerminalAppProtocol.shortcuts` registry. Filing a single
// shortcut requires editing the framework or stuffing onEvent
// switches into app code.
//
// To enable: uncomment when the registry lands.

/*
@Suite("Global shortcuts API — register app-level keybindings")
@MainActor
struct GlobalShortcutsTests {
    @Test("Shortcut struct exists and can be registered on the app")
    func shortcutsRegistryExists() {
        // Compile-only red. Real test: register a shortcut, fire its
        // chord, assert handler ran.
        let _: Shortcut = Shortcut(.character("p"), modifiers: [.ctrl]) { }
    }
}
*/

// MARK: - Flexible / responsive sizing
//
// `.frame(min: max:)` exists; `Spacer` is the flex-grow analog. The
// gap is a SwiftUI-style `maxWidth: .infinity` declaration that lets
// a child opt into "fill available space" without a sibling Spacer.
//
// To enable: uncomment when `FrameDimension.infinity` (or
// equivalent) is added.

/*
@Suite("Frame dimensions support fill-available declaration")
@MainActor
struct FillAvailableTests {
    @Test("FrameDimension.infinity is a public sentinel for fill-available")
    func fillAvailableSentinelExists() {
        // Compile-only red.
        let _ = Text("probe").frame(maxWidth: .infinity)
    }
}
*/

// MARK: - ScrollView thumb-track scrollbar
//
// Edge indicators (▲▼◀▶) already ship. The thumb-track
// scrollbar (proportional thumb, click-to-jump) is what's left.
//
// To enable: uncomment when ScrollIndicatorVisibility gains a
// `.scrollbar` case (or new `.scrollbarStyle(_:)` modifier).

/*
@Suite("ScrollView thumb-track scrollbar")
@MainActor
struct ScrollbarThumbTests {
    @Test("ScrollIndicatorVisibility.scrollbar enables proportional thumb")
    func scrollbarVisibilityCaseExists() {
        // Compile-only red. Real test: scroll, assert thumb position
        // moves proportionally in the rendered output.
        let _: ScrollIndicatorVisibility = .scrollbar
    }
}
*/
