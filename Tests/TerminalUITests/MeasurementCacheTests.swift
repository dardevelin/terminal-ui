import Testing
@testable import TerminalUI

// Two measurement caches went stale. A changed Text invalidated its cached
// size and that of its layout ancestors, but stopped at the first modifier —
// and a modifier's cached size is its child's, so `Text(…).foreground(…)`
// kept answering with the old width. And width, unlike height, reused a cached
// answer for containers whose composite-view content can change without
// marking them dirty. Together they left Storybook's detail column at the
// width of a page it had already left.

@Suite("Measurement caches follow what they measured")
@MainActor
struct MeasurementCacheTests {

    /// A changed Text invalidates every ancestor, modifiers included.
    @Test func aChangedTextReachesTheWidthOfItsAncestors() {
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            _ = graph.update(from: VStack { Text("ab").foreground(.red) })
            #expect(GraphMeasurer.measureWidth(graph.root!) == 2)
            _ = graph.update(from: VStack { Text("abcdefgh").foreground(.red) })
            #expect(GraphMeasurer.measureWidth(graph.root!) == 8)
        }
    }

    /// A container holding a composite view re-measures its width, as it
    /// already did its height.
    @Test func aContainerOfACompositeViewReMeasuresItsWidth() {
        struct Label: TerminalView {
            let text: String
            var body: some TerminalView { Text(text) }
        }
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            _ = graph.update(from: VStack { Label(text: "ab") }.padding(1))
            #expect(GraphMeasurer.measureWidth(graph.root!) == 4)
            _ = graph.update(from: VStack { Label(text: "abcdefgh") }.padding(1))
            #expect(GraphMeasurer.measureWidth(graph.root!) == 10)
        }
    }
}
