import Testing
@testable import TerminalUI

// An app could bring a tagged view into sight and learn which one sat at
// the top, but not which it could see: a transcript that keeps its
// selection on screen as the reader scrolls, as Crush's does, needs the
// whole visible set. SwiftUI answers with
// `onScrollTargetVisibilityChange(idType:threshold:_:)`.

@MainActor
private final class Seen {
    var reports: [[Int]] = []
}

/// Ten two-row entries tagged 0…9 in a six-row viewport: three entries fit.
@MainActor
private func transcript(_ seen: Seen, threshold: Double = 0.5) -> some TerminalView {
    ScrollView(.vertical) {
        VStack(spacing: 0) {
            ForEachWithID(0..<10, id: \.self) { index in
                VStack(spacing: 0) {
                    Text("entry \(index)")
                    Text("  body")
                }
                .id(index)
            }
        }
    }
    .onScrollTargetVisibilityChange(idType: Int.self, threshold: threshold) { seen.reports.append($0) }
}

/// Draws `view` and reports, as a frame does; returns the scroll node so a
/// case can scroll it between frames.
@MainActor
private final class Frames<View: TerminalView> {
    let graph = AttributeGraph()
    let view: View

    init(_ view: View) {
        self.view = view
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) { graph.update(from: view) }
    }

    var scrollNode: AttributeNode { Self.scrollNode(in: graph.root!)! }

    private static func scrollNode(in node: AttributeNode) -> AttributeNode? {
        if case .layout(let info) = node.kind, case .scroll = info.kind { return node }
        return node.children.lazy.compactMap { scrollNode(in: $0) }.first
    }

    /// Laid out, drawn and reported in a 20 × 6 terminal, as a frame is.
    func draw() {
        let rect = Rect(x: 0, y: 0, width: 20, height: 6)
        var buffer = CellBuffer(width: 20, height: 6)
        var environment = EnvironmentValues()
        environment.terminalSize = TerminalSize(cols: 20, rows: 6)
        GraphContext.$currentEnvironment.withValue(environment) {
            GraphContext.$currentProposedSize.withValue(Size(width: 20, height: 6)) {
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        GraphRenderer.reportScrollTargetVisibility(root: graph.root)
    }
}

@Suite("A scroll view says which of its tagged views can be seen")
@MainActor
struct ScrollTargetVisibilityTests {

    @Test func theFirstFrameReportsWhatItShows() {
        let seen = Seen()
        Frames(transcript(seen)).draw()
        #expect(seen.reports == [[0, 1, 2]])
    }

    @Test func scrollingReportsTheNewSet() {
        let seen = Seen()
        let frames = Frames(transcript(seen))
        frames.draw()
        frames.scrollNode.scrollOffset = 4
        frames.draw()
        #expect(seen.reports == [[0, 1, 2], [2, 3, 4]])
    }

    @Test func anUnchangedSetIsNotReportedAgain() {
        let seen = Seen()
        let frames = Frames(transcript(seen))
        frames.draw()
        frames.draw()
        #expect(seen.reports == [[0, 1, 2]])
    }

    /// Scrolled by one row, the first entry shows its second row only: half
    /// of it, which is visible at the default threshold and not at a higher.
    /// A scroll view nested in one that asks reports nothing of its own:
    /// the action asks about the outer view's targets.
    @Test func aNestedScrollViewDoesNotInheritTheAction() {
        let seen = Seen()
        let view = ScrollView(.vertical) {
            VStack(spacing: 0) {
                Text("outer").id(100)
                ScrollView(.vertical) {
                    VStack(spacing: 0) { ForEachWithID(0..<3, id: \.self) { Text("inner \($0)").id($0) } }
                }
                .frame(height: 2)
            }
        }
        .onScrollTargetVisibilityChange(idType: Int.self) { seen.reports.append($0) }
        Frames(view).draw()
        #expect(seen.reports == [[100]])
    }

    @Test func theThresholdIsTheShareOfAViewThatMustShow() {
        let half = Seen()
        let halfFrames = Frames(transcript(half))
        halfFrames.scrollNode.scrollOffset = 1
        halfFrames.draw()
        #expect(half.reports.last == [0, 1, 2, 3])

        let whole = Seen()
        let wholeFrames = Frames(transcript(whole, threshold: 1))
        wholeFrames.scrollNode.scrollOffset = 1
        wholeFrames.draw()
        #expect(whole.reports.last == [1, 2])
    }
}
