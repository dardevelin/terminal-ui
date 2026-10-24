import Testing
@testable import TerminalUI

// SwiftUI's `.inspector` is a panel along the trailing edge, beside the
// content rather than over a dimmed screen. Here it is a presentation like a
// modal's — focus moves into it and stays while it is up, and a click beside
// it does not reach what it covers — drawn full height at the right edge, as
// wide as its content, with what it presents over left undimmed.

@MainActor
private func built(_ view: some TerminalView, engine: FocusEngine = FocusEngine(),
                   width: Int = 40, height: Int = 8) -> (AttributeNode, CellBuffer) {
    let graph = AttributeGraph()
    GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: view) }
    let root = graph.root!
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    Layout.measureAndPlace(graph: root, in: rect)
    GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
    engine.rebuildIndex(root: root)
    return (root, buffer)
}

@MainActor
private func text(of node: AttributeNode) -> String {
    if case .primitive(.text(let spans)) = node.kind { return spans.map(\.text).joined() }
    return node.children.map(text(of:)).joined()
}

@Suite("An inspector is a panel along the trailing edge")
@MainActor
struct InspectorTests {

    private func base() -> some TerminalView {
        VStack(spacing: 0) {
            // Rows as wide as the screen, so the panel has something to stand beside.
            ForEachWithID(0..<8, id: \.self) { _ in Text(String(repeating: "x", count: 40)).wrap(.truncate(.tail)) }
        }
    }

    @Test func itIsDrawnFullHeightAtTheTrailingEdge() {
        let (_, buffer) = built(base().inspector(isPresented: .constant(true)) {
            VStack(spacing: 0) {
                Text("panel")
                Spacer()
                Text("end")
            }
            .frame(width: 12, alignment: .topLeading)
        })
        let panelStart = 40 - 12
        let column = { (row: Int) in String(buffer.text(row: row).dropFirst(panelStart)) }
        #expect(column(0) == "panel", "\(buffer.rowTexts)")
        #expect(column(7) == "end", "the panel runs to the bottom row")
    }

    @Test func itTakesTheTrailingEdgeOfTheViewItIsDeclaredOn() {
        // SwiftUI's inspector belongs to the view it modifies: a header and a
        // footer around that view stay as they are, as a chat's composer and
        // footer stay under a review panel.
        let (_, buffer) = built(VStack(spacing: 0) {
            Text("header")
            base().inspector(isPresented: .constant(true)) {
                Text("panel").frame(width: 12, alignment: .topLeading)
            }
            .frame(height: 5)
            Text("footer")
        }, height: 7)
        let panelStart = 40 - 12
        #expect(buffer.text(row: 0) == "header", "\(buffer.rowTexts)")
        #expect(buffer.text(row: 1).dropFirst(panelStart) == "panel")
        #expect(buffer.text(row: 5).count <= panelStart, "nothing of the base under the panel")
        #expect(buffer.text(row: 6) == "footer")
    }

    @Test func theViewBesideItIsLaidOutNarrower() {
        // A wrapping text beside the panel wraps at the panel's edge rather
        // than running under it, as a transcript beside SwiftUI's inspector
        // reflows.
        let (_, buffer) = built(Text(String(repeating: "word ", count: 12)).inspector(isPresented: .constant(true)) {
            Text("panel").frame(width: 20, alignment: .topLeading)
        })
        #expect(buffer.text(row: 0).hasPrefix("word word word word "), "\(buffer.rowTexts)")
        #expect(buffer.text(row: 0).hasSuffix("panel"))
        #expect(buffer.text(row: 1).hasPrefix("word"), "the text should wrap at the panel's edge")
    }

    @Test func aFlexibleViewStaysFlexibleUnderIt() {
        // A transcript that fills what it is given keeps doing so with an
        // inspector on it: the panel is not the view's to size, and a
        // footer below must stay on screen.
        let (_, buffer) = built(VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEachWithID(0..<20, id: \.self) { row in Text("row \(row)") }
            }
            .flexible(.vertical)
            .inspector(isPresented: .constant(true)) { Text("panel").frame(width: 12) }
            Text("footer")
        })
        #expect(buffer.text(row: 7) == "footer", "\(buffer.rowTexts)")
    }

    @Test func whatItPresentsOverIsNotDimmed() {
        let (_, plain) = built(base())
        let (_, inspected) = built(base().inspector(isPresented: .constant(true)) {
            Text("panel").frame(width: 12)
        })
        #expect(inspected[0, 0] == plain[0, 0])
    }

    @Test func focusMovesIntoItAndStays() {
        let engine = FocusEngine()
        let (root, _) = built(
            Text("under").focusable().inspector(isPresented: .constant(true)) {
                Text("inside").focusable().frame(width: 12)
            },
            engine: engine)
        #expect(engine.focusedNode(in: root).map(text(of:)) == "inside")
        engine.focusNext()
        #expect(engine.focusedNode(in: root).map(text(of:)) == "inside", "Tab must not leave the panel")
    }

    @Test func aClickBesideItDoesNotReachWhatItCovers() {
        let (root, _) = built(Text("under").focusable().inspector(isPresented: .constant(true)) {
            Text("inside").frame(width: 12)
        })
        let hit = HitTest.nodeAt(x: 1, y: 0, root: root)?.node
        #expect(hit.map(text(of:)) != "under")
    }

    @Test func notPresentedItIsNotThere() {
        let (_, buffer) = built(base().inspector(isPresented: .constant(false)) {
            Text("panel").frame(width: 12)
        })
        #expect(!buffer.rowTexts.joined().contains("panel"))
    }
}
