import Testing
@testable import TerminalUI

// `.scrollPosition(id:anchor:)` and scrolling to focus worked out where a
// view started by measuring what came before it at no width at all, as if
// nothing wrapped, and by stacking the views with no spacing and no insets.
// In a chat transcript — wrapped messages, a blank row between them, a rail
// and padding on each — every position was off, so bringing an entry into
// sight scrolled when it was already in sight, and to the wrong place when
// it was not. Positions are worked out the way the frame is drawn.

/// Draws frames as the app does: the pre-render scroll passes, then layout
/// and render.
@MainActor
private final class Frames<View: TerminalView> {
    let graph = AttributeGraph()
    let width: Int
    let height: Int
    var buffer: CellBuffer

    init(_ view: View, width: Int, height: Int) {
        self.width = width
        self.height = height
        buffer = CellBuffer(width: width, height: height)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) { graph.update(from: view) }
    }

    func draw() {
        GraphRenderer.adjustScrollForExplicitTarget(root: graph.root, viewportWidth: width, viewportHeight: height)
        buffer = renderedFrame()
    }

    private func renderedFrame() -> CellBuffer {
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        var buffer = CellBuffer(width: width, height: height)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        return buffer
    }

    var rows: [String] { buffer.rowTexts }
}

@MainActor
private final class Position {
    var id: Int?
    init(_ id: Int?) { self.id = id }
    var binding: Binding<Int?> { Binding(get: { self.id }, set: { self.id = $0 }) }
}

/// Eight entries, each a wrapped paragraph behind a rail and padding, a
/// blank row between them: a transcript.
@MainActor
private func transcript(_ position: Position, anchor: Alignment? = .top) -> some TerminalView {
    ScrollView {
        VStack(spacing: 1) {
            ForEachWithID(0..<8, id: \.self) { index in
                Text("entry \(index) says a sentence long enough to wrap")
                    .padding(.leading, 1)
                    .border(.rounded, edges: .leading)
                    .id(index)
            }
        }
    }
    .scrollPosition(id: position.binding, anchor: anchor)
}

@Suite("Scroll positions are worked out as the frame is drawn")
@MainActor
struct ScrollPositionMeasureTests {

    @Test func anEntryBroughtToTheTopIsAtTheTop() {
        let position = Position(5)
        let frames = Frames(transcript(position), width: 20, height: 8)
        frames.draw()
        frames.draw()
        #expect(frames.rows.first?.contains("entry 5") == true, "\(frames.rows)")
    }

    /// Already in sight, it needs no movement, and gets none.
    @Test func anEntryInSightDoesNotMove() {
        let position = Position(nil)
        let frames = Frames(transcript(position, anchor: nil), width: 20, height: 12)
        frames.draw()
        let before = frames.rows
        #expect(before.contains { $0.contains("entry 1") })
        position.id = 1
        frames.draw()
        #expect(frames.rows == before)
    }

    /// Scrolled by the reader, the binding names the entry now at the top.
    @Test func theEntryAtTheTopIsReported() {
        let position = Position(nil)
        let frames = Frames(transcript(position), width: 20, height: 8)
        frames.draw()
        let scroll = scrollNode(in: frames.graph.root!)!
        let entryHeight = 4  // three wrapped rows and a blank row
        scroll.scrollOffset = entryHeight * 3
        frames.draw()
        #expect(position.id == 3)
        #expect(frames.rows.first?.contains("entry 3") == true, "\(frames.rows)")
    }

    private func scrollNode(in node: AttributeNode) -> AttributeNode? {
        if case .layout(let info) = node.kind, case .scroll = info.kind { return node }
        return node.children.lazy.compactMap { scrollNode(in: $0) }.first
    }
}
