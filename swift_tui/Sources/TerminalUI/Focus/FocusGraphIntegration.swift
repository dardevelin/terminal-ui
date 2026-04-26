/// Protocol for modifiers that need to register with the FocusEngine
/// during graph construction.
protocol _FocusGraphModifier {
    func registerWithFocusEngine(nodeID: NodeID)
}

extension OnKeyPressModifier: _FocusGraphModifier {
    func registerWithFocusEngine(nodeID: NodeID) {
        GraphContext.currentFocusEngine?.registerKeyHandler(for: nodeID, handler: handler)
    }
}

extension OnClickModifier: _FocusGraphModifier {
    func registerWithFocusEngine(nodeID: NodeID) {
        GraphContext.currentFocusEngine?.registerClickHandler(for: nodeID, handler: handler)
    }
}

extension OnHoverModifier: _FocusGraphModifier {
    func registerWithFocusEngine(nodeID: NodeID) {
        GraphContext.currentFocusEngine?.registerHoverHandler(for: nodeID, handler: handler)
    }
}

/// Protocol for modifiers that fire lifecycle events at appearance/update.
/// Called from `fireLifecycleIfNeeded` on every construct + update pass —
/// the modifier itself decides whether the event should fire (e.g. once-only
/// for onAppear, only-on-change for onChange).
protocol _LifecycleModifier {
    func onConstructOrUpdate(node: AttributeNode)
}

extension OnAppearModifier: _LifecycleModifier {
    func onConstructOrUpdate(node: AttributeNode) {
        if !node.didAppear {
            node.didAppear = true
            action()
        }
    }
}

extension OnChangeModifier: _LifecycleModifier {
    /// Compares the current `value` against the value previously stored on
    /// the node and fires the action if it changed. The first observation
    /// records the value but does not fire (SwiftUI parity — onChange only
    /// reacts to *changes*, not the initial render).
    func onConstructOrUpdate(node: AttributeNode) {
        node.lastObservedValue = compareAndFire(previous: node.lastObservedValue)
    }
}

extension OnDisappearModifier: _LifecycleModifier {
    /// onDisappear captures its closure on the node during construct/update.
    /// The graph invokes the captured closure when the node is detached
    /// from the tree (see `AttributeGraph.fireDisappear(_:)`).
    func onConstructOrUpdate(node: AttributeNode) {
        node.onDisappearAction = action
    }
}

/// Called by the graph during node construction/update for modifier nodes.
/// Checks if the modifier needs focus or lifecycle integration and wires it up.
enum FocusGraphIntegration {

    /// After constructing or updating a modifier node, register any focus-related
    /// behavior with the FocusEngine.
    static func registerIfNeeded(modifier: any ViewModifier, nodeID: NodeID) {
        if let focusMod = modifier as? any _FocusGraphModifier {
            focusMod.registerWithFocusEngine(nodeID: nodeID)
        }
    }

    /// Fire lifecycle events for newly constructed modifier nodes.
    static func fireLifecycleIfNeeded(modifier: any ViewModifier, node: AttributeNode) {
        if let lifecycle = modifier as? any _LifecycleModifier {
            lifecycle.onConstructOrUpdate(node: node)
        }
    }
}
