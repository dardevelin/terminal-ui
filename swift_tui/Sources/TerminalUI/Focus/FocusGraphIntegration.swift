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
        #if DEBUG
        // Surface a stable-coded framework warning for the only
        // suspicious policy + .onHover pairing. .clickToLock /
        // .clickOnly compose orthogonally; .disabled IS the intended
        // pairing. .hoverFollows duplicates the framework's built-in
        // focus motion — almost always a sign the user wanted .disabled.
        if let env = GraphContext.currentEnvironment,
           env.mouseFocusPolicy == .hoverFollows
        {
            DebugStream.shared.emitWarning(
                .onHoverWithHoverFollows,
                message: """
                .onHover registered under .mouseFocusPolicy(.hoverFollows). \
                The framework will move keyboard focus on hover AND fire \
                this callback. If you want full control, use \
                .mouseFocusPolicy(.disabled). To intentionally keep both \
                behaviours, suppress with \
                DebugStream.shared.suppressWarning(.onHoverWithHoverFollows).
                """,
                nodeID: nodeID.path.map { "\($0)" }.joined(separator: ".")
            )
        }
        #endif
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
    ///
    /// Gated on `EnvironmentValues.isEnabled` so a `.disabled()` ancestor
    /// drops the handler from the engine entirely — there is no later
    /// "should I fire?" check on dispatch, the handler simply isn't there.
    /// Matches SwiftUI's `\.isEnabled` semantics.
    static func registerIfNeeded(modifier: any ViewModifier, nodeID: NodeID) {
        if let focusMod = modifier as? any _FocusGraphModifier {
            let env = GraphContext.currentEnvironment ?? EnvironmentValues()
            guard env.isEnabled else { return }
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
