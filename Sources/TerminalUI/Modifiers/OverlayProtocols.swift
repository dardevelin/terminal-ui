/// Protocols for overlay/background/modal modifiers to expose their content
/// to the graph without type erasure.

protocol _OverlayModifierProtocol {
    func constructOverlayNode(id: NodeID, graph: AttributeGraph) -> AttributeNode
    func updateOverlayNode(_ node: AttributeNode, graph: AttributeGraph)
    var overlayAlignment: Alignment { get }
}

protocol _BackgroundViewModifierProtocol {
    func constructBackgroundNode(id: NodeID, graph: AttributeGraph) -> AttributeNode
    func updateBackgroundNode(_ node: AttributeNode, graph: AttributeGraph)
    var backgroundAlignment: Alignment { get }
}

protocol _ModalModifierProtocol {
    var modalIsPresented: Bool { get }
    func constructModalNode(id: NodeID, graph: AttributeGraph) -> AttributeNode
    func updateModalNode(_ node: AttributeNode, graph: AttributeGraph)
}

// MARK: - Conformances

extension OverlayModifier: _OverlayModifierProtocol {
    var overlayAlignment: Alignment { alignment }

    func constructOverlayNode(id: NodeID, graph: AttributeGraph) -> AttributeNode {
        graph.constructNode(for: overlay, id: id)
    }
    func updateOverlayNode(_ node: AttributeNode, graph: AttributeGraph) {
        graph.updateNode(node, from: overlay)
    }
}

extension BackgroundViewModifier: _BackgroundViewModifierProtocol {
    var backgroundAlignment: Alignment { alignment }

    func constructBackgroundNode(id: NodeID, graph: AttributeGraph) -> AttributeNode {
        graph.constructNode(for: background, id: id)
    }
    func updateBackgroundNode(_ node: AttributeNode, graph: AttributeGraph) {
        graph.updateNode(node, from: background)
    }
}

extension ModalModifier: _ModalModifierProtocol {
    var modalIsPresented: Bool { isPresented }
    func constructModalNode(id: NodeID, graph: AttributeGraph) -> AttributeNode {
        graph.constructNode(for: content, id: id)
    }
    func updateModalNode(_ node: AttributeNode, graph: AttributeGraph) {
        graph.updateNode(node, from: content)
    }
}
