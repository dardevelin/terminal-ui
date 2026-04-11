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
        case let frm as FrameModifier: .frame(width: frm.width, height: frm.height)
        case let idm as IDModifier: .explicitID(idm.id)
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

// MARK: - ZStack

extension ZStack: _GraphZStack {
    func graphChildren() -> [Any] {
        extractChildren(from: content)
    }
}

// MARK: - ForEach

extension ForEach: _GraphForEach {
    func constructForEachNode(id: NodeID, graph: AttributeGraph) -> AttributeNode {
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .vstack)))
        for (i, element) in data.enumerated() {
            let childID = id.appending(.explicit(AnyHashable(element.id)))
            let childView = content(element)
            let childNode = graph.constructNode(for: childView, id: childID)
            childNode.parent = node
            node.children.append(childNode)
        }
        return node
    }

    func updateForEachNode(_ node: AttributeNode, graph: AttributeGraph) {
        guard case .layout = node.kind else { return }

        let newElements = Array(data)

        // Build lookup of existing children by explicit ID
        var existingByID: [AnyHashable: AttributeNode] = [:]
        for child in node.children {
            if let lastComponent = child.id.path.last,
               case .explicit(let key) = lastComponent {
                existingByID[key] = child
            }
        }

        // Rebuild children list — reuse existing nodes where possible
        var newChildren: [AttributeNode] = []
        var didChange = false

        for element in newElements {
            let key = AnyHashable(element.id)
            let childID = node.id.appending(.explicit(key))

            if let existing = existingByID[key] {
                // Reuse — update in place
                let childView = content(element)
                graph.updateNode(existing, from: childView)
                newChildren.append(existing)
            } else {
                // New element — construct
                let childView = content(element)
                let childNode = graph.constructNode(for: childView, id: childID)
                childNode.parent = node
                newChildren.append(childNode)
                didChange = true
            }
        }

        if newChildren.count != node.children.count { didChange = true }
        if didChange { graph.changed = true }
        node.children = newChildren
    }
}

extension ForEachWithID: _GraphForEach {
    func constructForEachNode(id: NodeID, graph: AttributeGraph) -> AttributeNode {
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .vstack)))
        for (i, element) in data.enumerated() {
            let key = element[keyPath: idKeyPath]
            let childID = id.appending(.explicit(AnyHashable(key)))
            let childView = content(element)
            let childNode = graph.constructNode(for: childView, id: childID)
            childNode.parent = node
            node.children.append(childNode)
        }
        return node
    }

    func updateForEachNode(_ node: AttributeNode, graph: AttributeGraph) {
        guard case .layout = node.kind else { return }

        var existingByID: [AnyHashable: AttributeNode] = [:]
        for child in node.children {
            if let lastComponent = child.id.path.last,
               case .explicit(let key) = lastComponent {
                existingByID[key] = child
            }
        }

        var newChildren: [AttributeNode] = []
        var didChange = false

        for element in data {
            let key = AnyHashable(element[keyPath: idKeyPath])
            let childID = node.id.appending(.explicit(key))

            if let existing = existingByID[key] {
                let childView = content(element)
                graph.updateNode(existing, from: childView)
                newChildren.append(existing)
            } else {
                let childView = content(element)
                let childNode = graph.constructNode(for: childView, id: childID)
                childNode.parent = node
                newChildren.append(childNode)
                didChange = true
            }
        }

        if newChildren.count != node.children.count { didChange = true }
        if didChange { graph.changed = true }
        node.children = newChildren
    }
}
