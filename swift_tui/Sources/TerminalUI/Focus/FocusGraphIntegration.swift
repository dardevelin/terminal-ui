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

/// Protocol for modifiers that fire lifecycle events.
protocol _LifecycleModifier {
    func onConstruct(node: AttributeNode)
}

extension OnAppearModifier: _LifecycleModifier {
    func onConstruct(node: AttributeNode) {
        if !node.didAppear {
            node.didAppear = true
            action()
        }
    }
}

/// Called by the graph during node construction/update for modifier nodes.
/// Checks if the modifier needs focus or lifecycle integration and wires it up.
enum FocusGraphIntegration {

    /// After constructing or updating a modifier node, register any focus-related
    /// behavior with the FocusEngine.
    static func registerIfNeeded(modifier: any ViewModifier, nodeID: NodeID) {
        if let focusMod = modifier as? _FocusGraphModifier {
            focusMod.registerWithFocusEngine(nodeID: nodeID)
        }
    }

    /// Fire lifecycle events for newly constructed modifier nodes.
    static func fireLifecycleIfNeeded(modifier: any ViewModifier, node: AttributeNode) {
        if let lifecycle = modifier as? _LifecycleModifier {
            lifecycle.onConstruct(node: node)
        }
    }
}
