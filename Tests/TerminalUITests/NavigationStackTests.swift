import Foundation
import Testing
@testable import TerminalUI

// Apple HIG, Navigation: a navigation stack "lets people move through a
// hierarchy of content, one level at a time, and back out the way they came."
// Two rules from that guidance are load-bearing in a terminal, where there is
// no window chrome to fall back on:
//
//   * Esc pops. It is the terminal-native counterpart to Enter pushing a
//     NavigationLink; without it the user is stranded on a pushed screen.
//   * Popping restores focus to the row that pushed — not the top of the
//     parent screen. Losing your place in a long list on every pop is the
//     thing that makes TUI navigation feel broken.
//
// A pushed screen also confines focus, the same way a presented modal does, so
// the covered parent is unreachable while a child is up. That is reused from
// the modal containment machinery, not reimplemented.

private struct Item: Hashable { let id: Int; var name: String { "Item \(id)" } }

@MainActor
private final class Path {
    var elements: [Item] = []
    var binding: Binding<[Item]> {
        Binding(get: { self.elements }, set: { self.elements = $0 })
    }
}

@discardableResult
@MainActor
private func render(_ graph: AttributeGraph, width: Int = 50, height: Int = 16) -> CellBuffer {
    var buffer = CellBuffer(width: width, height: height)
    guard let root = graph.root else { return buffer }
    GraphRenderer.render(
        root,
        into: &buffer,
        context: RenderContext(rect: Rect(x: 0, y: 0, width: width, height: height))
    )
    return buffer
}

private func renderedText(_ buffer: CellBuffer) -> String {
    var out = ""
    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            out.append(buffer[x, y].character)
        }
        out.append("\n")
    }
    return out
}

@MainActor
private func frame(_ engine: FocusEngine, _ graph: AttributeGraph, _ view: some TerminalView,
                   width: Int = 50, height: Int = 16) -> String {
    GraphContext.$currentFocusEngine.withValue(engine) {
        graph.update(from: view)
        let text = renderedText(render(graph, width: width, height: height))
        engine.rebuildIndex(root: graph.root!)
        return text
    }
}

@MainActor
private func drillView(_ path: Path) -> some TerminalView {
    NavigationStack(path: path.binding) {
        VStack {
            NavigationLink(value: Item(id: 1)) { Text("Row 1") }
            NavigationLink(value: Item(id: 2)) { Text("Row 2") }
        }
    }
    .navigationDestination(for: Item.self) { item in
        VStack {
            Text("Detail of \(item.name)")
            NavigationLink(value: Item(id: item.id * 10)) { Text("Deeper") }
        }
    }
}

@Suite("NavigationStack — push and pop")
@MainActor
struct NavigationStackPushPopTests {

    @Test("the root shows when the path is empty")
    func rootRendersWhenPathEmpty() {
        let path = Path()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let text = frame(engine, graph, drillView(path))
        #expect(text.contains("Row 1"))
        #expect(!text.contains("Detail of"))
    }

    @Test("activating a NavigationLink pushes its destination")
    func navigationLinkPushesDestination() {
        let path = Path()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, drillView(path))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(path.elements == [Item(id: 1)])
        #expect(frame(engine, graph, drillView(path)).contains("Detail of Item 1"))
    }

    @Test("Esc pops one level")
    func escPopsOneLevel() {
        let path = Path()
        path.elements = [Item(id: 1)]
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, drillView(path))

        _ = engine.routeKeyEvent(KeyEvent(key: .escape), root: graph.root!)
        #expect(path.elements.isEmpty)
    }

    @Test("Esc at the root does nothing")
    func escOnRootIsNoOp() {
        let path = Path()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, drillView(path))

        _ = engine.routeKeyEvent(KeyEvent(key: .escape), root: graph.root!)
        #expect(path.elements.isEmpty)  // still empty, no crash
    }

    @Test("programmatic append pushes")
    func programmaticAppendPushes() {
        let path = Path()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        path.elements.append(Item(id: 3))
        #expect(frame(engine, graph, drillView(path)).contains("Detail of Item 3"))
    }

    @Test("programmatic removeLast pops")
    func programmaticRemoveLastPops() {
        let path = Path()
        path.elements = [Item(id: 1), Item(id: 2)]
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, drillView(path))
        path.elements.removeLast()
        #expect(frame(engine, graph, drillView(path)).contains("Detail of Item 1"))
    }

    @Test("clearing the path pops to root")
    func pathResetPopsToRoot() {
        let path = Path()
        path.elements = [Item(id: 1), Item(id: 2)]
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, drillView(path))
        path.elements = []
        let text = frame(engine, graph, drillView(path))
        #expect(text.contains("Row 1"))
        #expect(!text.contains("Detail of"))
    }

    @Test("five levels down and back round-trips")
    func deepStackPushPopRoundTrips() {
        let path = Path()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        for depth in 1...5 { path.elements.append(Item(id: depth)) }
        #expect(frame(engine, graph, drillView(path)).contains("Detail of Item 5"))
        for _ in 1...5 {
            _ = frame(engine, graph, drillView(path))
            _ = engine.routeKeyEvent(KeyEvent(key: .escape), root: graph.root!)
        }
        #expect(path.elements.isEmpty)
        #expect(frame(engine, graph, drillView(path)).contains("Row 1"))
    }
}

@Suite("NavigationStack — focus")
@MainActor
struct NavigationStackFocusTests {

    // Containment is structural here: navigation replaces the screen, so the
    // covered parent's focusables are never built while a child is up. There is
    // nothing for Tab to escape *to*, without needing a containment-depth trap.
    @Test("a pushed screen's focusables are only its own; the parent's are gone")
    func pushedScreenTrapsFocus() {
        let path = Path()
        path.elements = [Item(id: 1)]
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let text = frame(engine, graph, drillView(path))

        // The pushed screen ("Deeper") shows; the parent rows do not.
        #expect(text.contains("Deeper"))
        #expect(!text.contains("Row 1"))
        #expect(!text.contains("Row 2"))

        // Every focusable belongs to the pushed screen — tabbing cannot reach a
        // parent row because none exists in the tree.
        engine.focusNext()
        for _ in 0..<4 {
            engine.focusNext()
            #expect(engine.keyboardFocusID != nil)
        }
    }

    @Test("popping returns to the root and its links are focusable again")
    func popReturnsToRoot() {
        let path = Path()
        path.elements = [Item(id: 1)]
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, drillView(path))

        _ = engine.routeKeyEvent(KeyEvent(key: .escape), root: graph.root!)
        let text = frame(engine, graph, drillView(path))
        #expect(text.contains("Row 1"))
        #expect(engine.collectFocusables(graph.root!).count >= 2)  // both rows focusable
    }
}

@Suite("NavigationStack — title and unbound")
@MainActor
struct NavigationStackTitleTests {

    @Test("the current screen's navigation title renders")
    func navigationTitleRenders() {
        let path = Path()
        path.elements = [Item(id: 1)]
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = NavigationStack(path: path.binding) {
            Text("root").navigationTitle("Home")
        }
        .navigationDestination(for: Item.self) { item in
            Text("body").navigationTitle(item.name)
        }
        #expect(frame(engine, graph, view).contains("Item 1"))
    }

    @Test("the unbound initialiser works without a path binding")
    func unboundInitWorksWithoutPathBinding() {
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = NavigationStack {
            NavigationLink(value: Item(id: 1)) { Text("Row 1") }
        }
        .navigationDestination(for: Item.self) { item in Text("Detail \(item.name)") }

        _ = frame(engine, graph, view)
        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(frame(engine, graph, view).contains("Detail Item 1"))
    }
}

// The live Navigation demo's `.section` screens are plain Text rows — zero
// focusable descendants. "A screen is presented" is a fact about the tree, not
// about whether Tab can reach something inside it: containment, Esc ownership,
// and key routing must all hold for an inert screen, or Esc falls through to
// the framework's quit default and tears the app down — the worst failure mode
// in a terminal, where there is no window chrome to recover from.
@MainActor
private func textOnlyDrillView(_ path: Path) -> some TerminalView {
    NavigationStack(path: path.binding) {
        VStack {
            NavigationLink(value: Item(id: 1)) { Text("Row 1") }
            NavigationLink(value: Item(id: 2)) { Text("Row 2") }
        }
    }
    .navigationDestination(for: Item.self) { item in
        VStack {
            Text("Inside \(item.name)")
            Text("Esc goes back")
        }
    }
}

@Suite("NavigationStack — screens with no focusable content")
@MainActor
struct NavigationStackNoFocusableContentTests {

    @Test("a pushed screen with no focusables still contains focus")
    func pushedTextOnlyScreenContainsFocus() {
        let path = Path()
        path.elements = [Item(id: 1)]
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, textOnlyDrillView(path))
        #expect(engine.isContainingFocus)
    }

    @Test("Esc pops a screen with no focusables")
    func escPopsTextOnlyScreen() {
        let path = Path()
        path.elements = [Item(id: 1)]
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, textOnlyDrillView(path))

        let handled = engine.routeKeyEvent(KeyEvent(key: .escape), root: graph.root!)
        #expect(handled)
        #expect(path.elements.isEmpty)
    }

    @Test("popping the last screen releases containment")
    func popReleasesContainment() {
        let path = Path()
        path.elements = [Item(id: 1)]
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, textOnlyDrillView(path))
        _ = engine.routeKeyEvent(KeyEvent(key: .escape), root: graph.root!)
        _ = frame(engine, graph, textOnlyDrillView(path))
        #expect(!engine.isContainingFocus)
    }

    @Test("the live drill shape round-trips: Enter pushes, Esc returns")
    func liveShapedRoundTrip() {
        let path = Path()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, textOnlyDrillView(path))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(path.elements == [Item(id: 1)])
        #expect(frame(engine, graph, textOnlyDrillView(path)).contains("Inside Item 1"))

        _ = engine.routeKeyEvent(KeyEvent(key: .escape), root: graph.root!)
        #expect(path.elements.isEmpty)
        #expect(frame(engine, graph, textOnlyDrillView(path)).contains("Row 1"))
    }
}

extension NavigationStackNoFocusableContentTests {

    // The pop must land on the row that pushed, not the top of the list —
    // losing your place on every pop is what makes TUI navigation feel
    // broken. The base is blanked while a screen is up, so the link node
    // leaves the tree entirely; the engine must remember it across that
    // absence, not just across a covered-but-present base.
    @Test("popping restores focus to the link that pushed")
    func popRestoresOriginatingLink() {
        let path = Path()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, textOnlyDrillView(path))

        engine.focusNext()
        engine.focusNext()
        let originatingLink = engine.keyboardFocusID
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(path.elements == [Item(id: 2)])
        _ = frame(engine, graph, textOnlyDrillView(path))

        _ = engine.routeKeyEvent(KeyEvent(key: .escape), root: graph.root!)
        _ = frame(engine, graph, textOnlyDrillView(path))
        #expect(engine.keyboardFocusID == originatingLink)
    }
}
