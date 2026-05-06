import Foundation
import Observation

// HYP-277 — @Observable wrapper around SplitNode so SplitView re-
// renders when the tree mutates. Mirrors SwiftUI's NavigationPath
// pattern: the consumer holds the state, the view binds to it,
// mutations propagate via Observation.
//
// Non-isolated to match the framework's "main thread by convention"
// rule (per `feedback_drop_mainactor_to_match_neighbor.md`).
// AttributeNode is `@unchecked Sendable`; tests run inside
// `@MainActor` suites; the runtime invokes graph code from main-
// thread render code.

@Observable
public final class SplitState {
    public var root: SplitNode

    public init(root: SplitNode) {
        self.root = root
    }

    /// Convenience init for callers that build the tree lazily.
    /// Defaults to a placeholder leaf wrapping the framework's
    /// `EmptyView` so app code doesn't carry an `Optional<SplitNode>`
    /// through its data flow. Replace `root` before first render.
    public convenience init() {
        self.init(root: .leaf(EmptyView()))
    }
}
