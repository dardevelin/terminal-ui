// Connect existing view types to the attribute graph.

// MARK: - VStack

extension VStack: _GraphVStack {
    func graphChildren() -> [Any] {
        extractChildren(from: content)
    }
}

// MARK: - HStack

extension HStack: _GraphHStack {
    func graphChildren() -> [Any] {
        extractChildren(from: content)
    }
}

// MARK: - ModifiedView

extension ModifiedView: _GraphModified {
    func graphEffect() -> ModifierEffect {
        switch modifier {
        case let fg as ForegroundModifier: .foreground(fg.color)
        case let bg as BackgroundModifier: .background(bg.color)
        case is BoldModifier: .bold
        case is ItalicModifier: .italic
        case is UnderlineModifier: .underline
        case let pad as PaddingModifier: .padding(pad.amount)
        case let bdr as BorderModifier: .border(bdr.style)
        default: .bold
        }
    }

    func constructChildNode(id: NodeID, graph: AttributeGraph) -> AttributeNode {
        graph.constructNode(for: content, id: id)
    }

    func updateChild(_ child: AttributeNode, graph: AttributeGraph) {
        graph.updateNode(child, from: content)
    }
}

// MARK: - ConditionalView

extension ConditionalView: _GraphConditional {
    func constructConditionalNode(id: NodeID, graph: AttributeGraph) -> AttributeNode {
        switch self {
        case .first(let view):
            return graph.constructNode(for: view, id: id.appending(.conditional(true)))
        case .second(let view):
            return graph.constructNode(for: view, id: id.appending(.conditional(false)))
        }
    }

    func updateConditionalNode(_ node: AttributeNode, graph: AttributeGraph) {
        switch self {
        case .first(let view):
            // Check if the branch is the same
            if node.children.count == 1, let child = node.children.first {
                graph.updateNode(child, from: view)
            } else {
                let childNode = graph.constructNode(for: view, id: node.id.appending(.conditional(true)))
                childNode.parent = node
                node.children = [childNode]
            }
        case .second(let view):
            if node.children.count == 1, let child = node.children.first {
                graph.updateNode(child, from: view)
            } else {
                let childNode = graph.constructNode(for: view, id: node.id.appending(.conditional(false)))
                childNode.parent = node
                node.children = [childNode]
            }
        }
    }
}
