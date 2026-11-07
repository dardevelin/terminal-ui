import Testing
@testable import TerminalUI

// A ZStack offers each child its own size, and a child sits at the size it
// claims for that offer, as in SwiftUI. A view that takes what it is offered
// — a GeometryReader, a Divider, a scroll view, a frame reaching for
// `.infinity`, a stack holding a Spacer — claims all of it. Placed instead at
// what it measures, a GeometryReader saw one row, a Divider shrank to a dash,
// and a scroll view showed one line of its content.

@MainActor
private final class Screen {
    let graph = AttributeGraph()
    let rows: [String]

    init(width: Int, height: Int, _ view: some TerminalView) {
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        let graph = graph
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        rows = (0..<height).map { y in
            (0..<width).map { String(buffer[$0, y].character) }.joined()
        }
    }

    var root: AttributeNode { graph.root! }

    /// The rect of the stack's only child.
    var child: Rect { root.children[0].rect }

    /// Every primitive under the root, in drawing order.
    var primitives: [AttributeNode] {
        var found: [AttributeNode] = []
        func walk(_ node: AttributeNode) {
            if case .primitive = node.kind { found.append(node) }
            node.children.forEach(walk)
        }
        walk(root)
        return found
    }
}

@Suite("A ZStack child sits at the size it claims")
@MainActor
struct ZStackSizingTests {

    // MARK: - Greedy children under an alignment that places

    @Test func aGeometryReaderSeesTheWholeStack() {
        let screen = Screen(width: 12, height: 5, ZStack(alignment: .center) {
            GeometryReader { size in Text("\(size.width)x\(size.height)") }
        })
        #expect(screen.child == Rect(x: 0, y: 0, width: 12, height: 5))
        #expect(screen.rows[0].hasPrefix("12x5"))
    }

    @Test func aDividerSpansTheWidth() {
        let screen = Screen(width: 12, height: 5, ZStack(alignment: .center) { Divider() })
        #expect(screen.child == Rect(x: 0, y: 2, width: 12, height: 1))
        #expect(screen.rows[2] == String(repeating: "─", count: 12))
    }

    @Test func aFrameReachingForInfiniteHeightTakesTheWholeHeight() {
        let screen = Screen(width: 12, height: 5, ZStack(alignment: .center) {
            Text("tall").frame(maxHeight: .infinity)
        })
        #expect(screen.child == Rect(x: 4, y: 0, width: 4, height: 5))
    }

    @Test func aColumnHoldingASpacerTakesTheWholeHeight() {
        let screen = Screen(width: 12, height: 5, ZStack(alignment: .center) {
            VStack {
                Text("top")
                Spacer()
            }
        })
        #expect(screen.child == Rect(x: 4, y: 0, width: 3, height: 5),
                "a Spacer stretches its column down, not across")
        #expect(screen.rows[0] == "    top     ")
    }

    @Test func aVerticalScrollViewTakesTheWholeHeight() {
        let screen = Screen(width: 12, height: 5, ZStack(alignment: .center) {
            ScrollView {
                VStack {
                    Text("row 0")
                    Text("row 1")
                }
            }
        })
        #expect(screen.child == Rect(x: 0, y: 0, width: 12, height: 5),
                "a scroll view takes what it is offered on both axes")
        #expect(screen.rows[0].hasPrefix("row 0"))
    }
}
