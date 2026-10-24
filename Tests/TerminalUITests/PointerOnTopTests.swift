import Testing
@testable import TerminalUI

// The pointer reaches what is drawn where it is. `.onHover` fired for every
// handler whose rect held the pointer, so a card under a popover lit up with
// the popover, and of two overlapping views both were hovered at once. A
// list's click found the row by counting lines from its top, as if every row
// were one line tall: on a list of two-line rows a click on the second line
// of the first row selected the second.

@MainActor
private final class Screen {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let width: Int
    let height: Int

    init(width: Int = 20, height: Int = 8, _ view: some TerminalView) {
        self.width = width
        self.height = height
        GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: view) }
        draw()
    }

    var root: AttributeNode { graph.root! }

    func draw() {
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: root, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
        }
        engine.rebuildIndex(root: root)
    }

    func move(_ x: Int, _ y: Int) {
        engine.applyMouseMove(x: x, y: y, root: root, policy: .clickToLock)
    }

    func click(_ x: Int, _ y: Int) {
        engine.handleMouseClick(x: x, y: y, root: root)
    }
}

@MainActor
private final class Hovered {
    var names: Set<String> = []
    func handler(_ name: String) -> (Bool) -> Void {
        { [self] isHovering in
            if isHovering { names.insert(name) } else { names.remove(name) }
        }
    }
}

private struct Row: Identifiable {
    let id: Int
}

@Suite("The pointer reaches what is drawn on top")
@MainActor
struct PointerOnTopTests {

    @Test func ofTwoOverlappingViewsOnlyTheOneOnTopIsHovered() {
        let hovered = Hovered()
        let screen = Screen(ZStack {
            Text("under").frame(width: 10, height: 2).onHover(hovered.handler("under"))
            Text("over").frame(width: 10, height: 2).onHover(hovered.handler("over"))
        })
        screen.move(1, 0)
        #expect(hovered.names == ["over"])
    }

    @Test func aViewBesideTheOneOnTopIsHoveredWhereNothingCoversIt() {
        let hovered = Hovered()
        let screen = Screen(ZStack(alignment: .topLeading) {
            Text("under").frame(width: 10, height: 2).onHover(hovered.handler("under"))
            Text("over").frame(width: 4, height: 1).onHover(hovered.handler("over"))
        })
        screen.move(6, 1)
        #expect(hovered.names == ["under"])
        screen.move(1, 0)
        #expect(hovered.names == ["over"])
    }

    @Test func aViewHoldingTheHoveredOneIsHoveredToo() {
        let hovered = Hovered()
        let screen = Screen(VStack {
            Text("inner").onHover(hovered.handler("inner"))
            Text("sibling")
        }
        .onHover(hovered.handler("outer")))
        screen.move(1, 0)
        #expect(hovered.names == ["inner", "outer"])
        screen.move(1, 1)
        #expect(hovered.names == ["outer"])
    }

    @Test func leavingTheViewOnTopForTheOneUnderItSwapsThem() {
        let hovered = Hovered()
        let screen = Screen(ZStack(alignment: .topLeading) {
            Text("under").frame(width: 10, height: 2).onHover(hovered.handler("under"))
            Text("over").frame(width: 4, height: 1).onHover(hovered.handler("over"))
        })
        screen.move(1, 0)
        screen.move(6, 0)
        #expect(hovered.names == ["under"])
    }

    @Test func aClickOnTheSecondLineOfARowSelectsThatRow() {
        let selection = Selection()
        let screen = Screen(List([Row(id: 0), Row(id: 1), Row(id: 2)],
                                 selection: selection.binding, visibleCount: 6) { row in
            VStack(spacing: 0) {
                Text("row \(row.id)")
                Text("detail \(row.id)")
            }
        })
        screen.click(4, 1)
        #expect(selection.id == 0)
        screen.click(4, 2)
        #expect(selection.id == 1)
        screen.click(4, 5)
        #expect(selection.id == 2)
    }

    @Test func aClickOnAScrolledListSelectsTheRowUnderIt() {
        let selection = Selection(8)
        let screen = Screen(List((0..<10).map(Row.init), selection: selection.binding,
                                 visibleCount: 4) { row in Text("row \(row.id)") })
        // "▲ 7 more", then rows 7, 8 and 9.
        screen.click(4, 1)
        #expect(selection.id == 7)
        screen.click(4, 0)
        #expect(selection.id == 7, "the indicator line is no row")
    }
}

@MainActor
private final class Selection {
    var id: Int?
    init(_ id: Int? = nil) { self.id = id }
    var binding: Binding<Int?> { Binding(get: { self.id }, set: { self.id = $0 }) }
}
