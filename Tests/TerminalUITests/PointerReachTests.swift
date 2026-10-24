import Testing
@testable import TerminalUI

// A scroll view shows its content only through its viewport. Rows scrolled
// out of it keep rects outside it — over the header above, the footer below —
// and every pointer lookup that walked into them found a row nobody could
// see: a click on the header selected row 4, a wheel over the footer
// scrolled the list, and hovering the header lit a hidden row. The pointer
// reaches a scroll view's content only where it lies inside the viewport,
// as `HitTest` (what `swtui ctl probe` reports) already had it.

private final class Clicks: @unchecked Sendable {
    var labels: [String] = []
}

@MainActor
private final class Screen {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let width: Int
    let height: Int

    init(width: Int = 30, height: Int = 8, _ view: some TerminalView) {
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

    /// The first scroll view's content scrolled down by `rows`, and redrawn.
    func scroll(by rows: Int) {
        func find(_ node: AttributeNode) -> AttributeNode? {
            if case .layout(let info) = node.kind, case .scroll = info.kind { return node }
            return node.children.lazy.compactMap(find).first
        }
        find(root)!.scrollOffset = rows
        draw()
    }

    func click(_ x: Int, _ y: Int) {
        engine.handleMouseClick(x: x, y: y, root: root)
    }
}

/// Header (row 0), a four-row scroll view of twenty clickable rows (rows
/// 1–4), and a footer (row 5).
private func listBetweenHeaderAndFooter(_ clicks: Clicks) -> some TerminalView {
    VStack(spacing: 0) {
        Text("header").onClick { _, _ in clicks.labels.append("header") }
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEachWithID(0..<20, id: \.self) { row in
                    Text("row \(row)").onClick { _, _ in clicks.labels.append("row \(row)") }
                }
            }
        }
        .frame(height: 4)
        Text("footer").onClick { _, _ in clicks.labels.append("footer") }
    }
}

@Suite("The pointer reaches only what a viewport shows")
@MainActor
struct PointerReachTests {

    @Test func aClickOnTheHeaderAboveAScrolledListHitsTheHeader() {
        let clicks = Clicks()
        let screen = Screen(listBetweenHeaderAndFooter(clicks))
        screen.scroll(by: 5)
        screen.click(1, 0)
        #expect(clicks.labels == ["header"])
    }

    @Test func aClickOnTheFooterBelowAListHitsTheFooter() {
        let clicks = Clicks()
        let screen = Screen(listBetweenHeaderAndFooter(clicks))
        screen.click(1, 5)
        #expect(clicks.labels == ["footer"])
    }

    @Test func aClickInsideTheViewportHitsTheRowShownThere() {
        let clicks = Clicks()
        let screen = Screen(listBetweenHeaderAndFooter(clicks))
        screen.scroll(by: 5)
        screen.click(1, 2)
        #expect(clicks.labels == ["row 6"])
    }

    @Test func aWheelOverTheFooterDoesNotScrollTheListAbove() {
        let clicks = Clicks()
        let screen = Screen(listBetweenHeaderAndFooter(clicks))
        #expect(screen.engine.findScrollNodeAt(x: 1, y: 5, root: screen.root) == nil)
    }

    @Test func hoverOverTheHeaderLightsNoHiddenRow() {
        let hovered = Clicks()
        let screen = Screen(VStack(spacing: 0) {
            Text("header")
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEachWithID(0..<20, id: \.self) { row in
                        Text("row \(row)").onHover { inside in
                            if inside { hovered.labels.append("row \(row)") }
                        }
                    }
                }
            }
            .frame(height: 4)
        })
        screen.scroll(by: 5)
        screen.engine.updateMouseHover(x: 1, y: 0, root: screen.root)
        #expect(hovered.labels.isEmpty, "\(hovered.labels)")
    }
}

private final class Presses: @unchecked Sendable {
    var events: [String] = []
}

@Suite("A click reaches the control under it")
@MainActor
struct ClickTargetTests {

    /// A row that is clickable as a whole, holding a label and a button.
    private func row(_ presses: Presses) -> some TerminalView {
        VStack(spacing: 0) {
            Text("above")
            HStack(spacing: 1) {
                Text("label").focusable()
                Button("go") { presses.events.append("button") }
            }
            .onClick { x, y in presses.events.append("row \(x),\(y)") }
        }
    }

    @Test func aButtonInAClickableRowRunsItsOwnAction() {
        let presses = Presses()
        let screen = Screen(row(presses))
        // "label" takes 0–4, a space, then the button.
        screen.click(7, 1)
        #expect(presses.events == ["button"])
    }

    @Test func theRowsHandlerGetsCoordinatesInTheRow() {
        let presses = Presses()
        let screen = Screen(row(presses))
        screen.click(2, 1)
        #expect(presses.events == ["row 2,0"], "relative to the row, not to the label that took focus")
    }
}
