import Observation
import Testing
@testable import TerminalUI

// A presentation (a modal, an alert, a confirmation dialog) is drawn after
// the tree, against the whole screen, so a dialog declared inside a scrolled
// pane is not clipped to the pane. A presentation declared inside another is
// drawn on top of it, and two renders — `TerminalApp.print` may run on any
// thread — share nothing, so neither draws the other's.

private func render(_ view: some TerminalView, width: Int = 40, height: Int = 12) -> String {
    let graph = AttributeGraph()
    graph.update(from: view)
    var buffer = CellBuffer(width: width, height: height)
    guard let root = graph.root else { return "" }
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    Layout.measureAndPlace(graph: root, in: rect)
    GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
    return (0..<height).map { y in
        (0..<width).map { String(buffer[$0, y].character) }.joined()
    }.joined(separator: "\n")
}

@Suite("Presentations are drawn over the whole screen, in order")
struct PresentationDrawingTests {

    @Test func aModalPresentedFromAModalIsDrawn() {
        // Both centre on the screen; the outer is taller, so its first and
        // last rows stay visible around the inner one drawn over its middle.
        let screen = render(
            Text("base").modal(isPresented: true) {
                VStack {
                    Text("outer top")
                    Text("outer middle")
                    Text("outer bottom")
                }
                .modal(isPresented: true) {
                    Text("inner")
                }
            }
        )
        #expect(screen.contains("outer top"))
        #expect(screen.contains("outer bottom"))
        #expect(screen.contains("inner"))
        #expect(!screen.contains("outer middle"), "the inner dialog is drawn on top")
    }

    @Test func concurrentRendersKeepTheirOwnPresentations() async {
        let names = (0..<64).map { "n\($0)" }
        let screens = await withTaskGroup(of: (String, String).self) { group in
            for name in names {
                group.addTask {
                    (name, render(Text("base").modal(isPresented: true) { Text("dialog \(name)") }))
                }
            }
            var screens: [(String, String)] = []
            for await screen in group { screens.append(screen) }
            return screens
        }
        for (name, screen) in screens {
            #expect(screen.contains("dialog \(name) "), "render \(name) lost its own dialog")
            let others = names.filter { $0 != name && screen.contains("dialog \($0) ") }
            #expect(others.isEmpty, "render \(name) drew \(others)")
        }
    }
}

// The renderer draws presentations level by level — everything the walk
// declares, then what those declare — each over the last, so the dialog on
// top is the last one in tree order at the deepest level. Focus and hit
// testing must agree with what is drawn, wherever in the tree the dialog was
// declared.

@MainActor
private func built(_ view: some TerminalView, engine: FocusEngine = FocusEngine(),
                   width: Int = 40, height: Int = 12) -> AttributeNode {
    let graph = AttributeGraph()
    GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: view) }
    let root = graph.root!
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    Layout.measureAndPlace(graph: root, in: rect)
    GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
    engine.rebuildIndex(root: root)
    return root
}

@MainActor
private func text(of node: AttributeNode) -> String {
    if case .primitive(.text(let spans)) = node.kind {
        return spans.map(\.text).joined()
    }
    return node.children.map(text(of:)).joined()
}

@MainActor
private func screenPosition(of label: String, in root: AttributeNode) -> (x: Int, y: Int)? {
    if case .primitive(.text) = root.kind, text(of: root) == label {
        return (root.rect.x, root.rect.y)
    }
    return root.children.lazy.compactMap { screenPosition(of: label, in: $0) }.first
}

@MainActor
private func depth(of label: String, in node: AttributeNode) -> Int? {
    if node.isFocusable, text(of: node) == label { return node.containmentDepth }
    return node.children.lazy.compactMap { depth(of: label, in: $0) }.first
}

@Suite("The dialog drawn on top owns focus and the pointer")
@MainActor
struct DialogOnTopTests {

    @Test func focusStaysInTheLaterOfTwoDialogsAtOneLevel() {
        let engine = FocusEngine()
        let root = built(
            HStack {
                Text("left").modal(isPresented: true) { Text("first").focusable() }
                Text("right").modal(isPresented: true) { Text("second").focusable() }
            },
            engine: engine
        )
        let focused = engine.focusedNode(in: root)
        #expect(focused.map(text(of:)) == "second")
        engine.focusNext()
        let afterTab = engine.focusedNode(in: root)
        #expect(afterTab.map(text(of:)) == "second", "Tab must not reach the dialog underneath")
    }

    @Test func aDialogDeclaredBelowTheRootIsHit() throws {
        let root = built(
            VStack {
                Text("header")
                Text("small").modal(isPresented: true) { Text("dialog body") }
                Text("footer")
            }
        )
        let point = try #require(screenPosition(of: "dialog body", in: root))
        let hit = try #require(HitTest.nodeAt(x: point.x, y: point.y, root: root))
        #expect(text(of: hit.node) == "dialog body")
        #expect(hit.path.first === root)
    }

    @Test func outsideTheDialogTheDimmedScreenIsHit() throws {
        let root = built(
            VStack {
                Text("header")
                Text("small").modal(isPresented: true) { Text("dialog body") }
            }
        )
        let hit = try #require(HitTest.nodeAt(x: 0, y: 0, root: root))
        #expect(!hit.path.contains { text(of: $0) == "header" }, "the base under the dim must not be hit")
        #expect(hit.node.presentedContent != nil, "the presenting modal takes the hit")
    }

    @Test func theInnerOfTwoNestedDialogsIsHit() throws {
        let root = built(
            Text("base").modal(isPresented: true) {
                VStack {
                    Text("outer top")
                    Text("outer middle")
                    Text("outer bottom")
                }
                .modal(isPresented: true) { Text("inner") }
            }
        )
        let point = try #require(screenPosition(of: "inner", in: root))
        let hit = try #require(HitTest.nodeAt(x: point.x, y: point.y, root: root))
        #expect(text(of: hit.node) == "inner")
    }

    @Test func aSheetWhoseBodyIsAnAlertKeepsTheAlertOnTop() {
        let engine = FocusEngine()
        let root = built(
            HStack {
                Text("left").modal(isPresented: true) { Text("first").focusable() }
                Text("right").modal(isPresented: true) {
                    Text("sheet").focusable()
                        .modal(isPresented: true) { Text("alert").focusable() }
                }
            },
            engine: engine
        )
        let focused = engine.focusedNode(in: root)
        #expect(focused.map(text(of:)) == "alert")
    }

    @Test func aNestedDialogKeepsItsDepthWhenOnlyItsViewReevaluates() throws {
        let model = DialogModel()
        let graph = AttributeGraph()
        graph.update(from: Text("base").modal(isPresented: true) { InnerDialog(model: model) })
        model.label = "inner again"
        #expect(graph.drain())
        let root = try #require(graph.root)
        #expect(depth(of: "outer", in: root) == 1)
        #expect(depth(of: "inner again", in: root) == 2)
    }

    @Test func aKeyTheDialogIgnoresDoesNotReachTheViewUnderIt() throws {
        let engine = FocusEngine()
        let keys = Box(0)
        let root = built(
            VStack {
                Text("small").modal(isPresented: true) { Text("dialog").focusable() }
            }
            .onKeyPress { _ in
                keys.value += 1
                return .handled
            },
            engine: engine
        )
        let focused = try #require(engine.focusedNode(in: root))
        #expect(text(of: focused) == "dialog")
        #expect(!engine.routeKeyEvent(KeyEvent(key: .down), root: root))
        #expect(keys.value == 0, "a key bubbled out of the dialog")
    }

    @Test func anActionOfTheViewUnderTheDialogDoesNotFire() throws {
        let engine = FocusEngine()
        let fired = Box(0)
        let root = built(
            VStack {
                Text("small").modal(isPresented: true) { Text("dialog").focusable() }
            }
            .actions {
                Action(id: "covered", title: .literal("Covered")) { fired.value += 1 }
                    .bound(to: .keyboard(.character("x"), []))
            },
            engine: engine
        )
        let focused = try #require(engine.focusedNode(in: root))
        #expect(!ActionDispatch.dispatch(binding: .keyboard(.character("x"), []), from: focused))
        #expect(fired.value == 0)
    }

    @Test func thePointerDoesNotReachThroughTheDim() throws {
        let engine = FocusEngine()
        let clicks = Box(0)
        let hovers = Box(0)
        let root = built(
            VStack {
                Text("row").onClick { _, _ in clicks.value += 1 }.onHover { _ in hovers.value += 1 }
                Text("small").modal(isPresented: true) { Text("dialog body") }
            },
            engine: engine
        )
        let row = try #require(screenPosition(of: "row", in: root))
        engine.handleMouseClick(x: row.x, y: row.y, root: root)
        engine.fireClickHandlerOnly(x: row.x, y: row.y, root: root)
        engine.applyMouseMove(x: row.x, y: row.y, root: root, policy: .clickToLock)
        #expect(clicks.value == 0, "a click on the dim reached the row underneath")
        #expect(hovers.value == 0, "hover reached the row underneath")
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@Observable
private final class DialogModel {
    var label = "inner"
}

private struct InnerDialog: TerminalView {
    let model: DialogModel
    var body: some TerminalView {
        Text("outer").focusable()
            .modal(isPresented: true) { Text(model.label).focusable() }
    }
}
