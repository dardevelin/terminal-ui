import Testing
@testable import TerminalUI

// An app with nothing focused focuses its first focusable, in the order Tab
// walks. A chat's transcript comes before its composer on screen and in that
// order, yet the composer is where the keys belong when the app opens — as
// in Crush. SwiftUI lets a view ask for that with `prefersDefaultFocus`.

@Suite("A view can ask to be focused when nothing is")
@MainActor
struct DefaultFocusTests {

    private func engine(for view: some TerminalView) -> (FocusEngine, AttributeGraph) {
        let engine = FocusEngine()
        let graph = AttributeGraph()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) { graph.update(from: view) }
        }
        engine.rebuildIndex(root: graph.root!)
        return (engine, graph)
    }

    private func focusedText(_ engine: FocusEngine, _ graph: AttributeGraph) -> String? {
        guard let id = engine.keyboardFocusID, let node = engine.findNode(id: id, in: graph.root!) else { return nil }
        return renderedText(node)
    }

    private func renderedText(_ node: AttributeNode) -> String? {
        if case .primitive(.text(let spans)) = node.kind { return spans.map(\.text).joined() }
        return node.children.lazy.compactMap { renderedText($0) }.first
    }

    @Test func withNoPreferenceTheFirstFocusableIsFocused() {
        let (engine, graph) = engine(for: VStack {
            Text("transcript").focusable()
            Text("composer").focusable()
        })
        engine.focusDefault()
        #expect(focusedText(engine, graph) == "transcript")
    }

    @Test func aViewThatPrefersItIsFocused() {
        let (engine, graph) = engine(for: VStack {
            Text("transcript").focusable()
            Text("composer").focusable().prefersDefaultFocus()
        })
        engine.focusDefault()
        #expect(focusedText(engine, graph) == "composer")
    }

    /// The preference picks where focus starts, not the order Tab walks.
    @Test func tabStillWalksInOrder() {
        let (engine, graph) = engine(for: VStack {
            Text("transcript").focusable()
            Text("composer").focusable().prefersDefaultFocus()
        })
        engine.focusDefault()
        engine.focusNext()
        #expect(focusedText(engine, graph) == "transcript")
    }

    @Test func aPreferenceTurnedOffIsNone() {
        let (engine, graph) = engine(for: VStack {
            Text("transcript").focusable()
            Text("composer").focusable().prefersDefaultFocus(false)
        })
        engine.focusDefault()
        #expect(focusedText(engine, graph) == "transcript")
    }

    /// A dialog presented over a focused view pulls focus inside it, to the
    /// view in it that asked.
    @Test func aDialogFocusesTheViewInItThatAsked() {
        func view(_ presented: Bool) -> some TerminalView {
            Text("background").focusable()
                .modal(isPresented: presented) {
                    VStack {
                        Text("Cancel").focusable()
                        Text("Confirm").focusable().prefersDefaultFocus()
                    }
                }
        }
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) { graph.update(from: view(false)) }
        engine.rebuildIndex(root: graph.root!)
        engine.focusDefault()
        #expect(focusedText(engine, graph) == "background")

        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) { graph.update(from: view(true)) }
        engine.rebuildIndex(root: graph.root!)
        #expect(focusedText(engine, graph) == "Confirm")
    }

    /// The preference is a flag on the modifier, so turning it off keeps the
    /// view: a composer keeps what was typed in it.
    @Test func turningThePreferenceOffKeepsTheView() {
        func view(_ prefers: Bool) -> some TerminalView {
            VStack { Text("composer").focusable().prefersDefaultFocus(prefers) }
        }
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) { graph.update(from: view(true)) }
        engine.rebuildIndex(root: graph.root!)
        let before = engine.collectFocusables(graph.root!).map(\.id)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) { graph.update(from: view(false)) }
        engine.rebuildIndex(root: graph.root!)
        #expect(engine.collectFocusables(graph.root!).map(\.id) == before)
    }

    /// On a container, the preference falls to the first focusable inside.
    @Test func aContainerPassesItToItsFirstFocusable() {
        let (engine, graph) = engine(for: VStack {
            Text("transcript").focusable()
            VStack {
                Text("composer").focusable()
                Text("send").focusable()
            }
            .prefersDefaultFocus()
        })
        engine.focusDefault()
        #expect(focusedText(engine, graph) == "composer")
    }
}
