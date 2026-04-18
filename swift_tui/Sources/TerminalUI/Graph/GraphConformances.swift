// Connect existing view types to the attribute graph.

// MARK: - TupleView unpacking
//
// @TerminalViewBuilder produces TupleView<(V0, V1, ...)> wrapping a tuple.
// To get individual children, we use Swift's Mirror API (runtime reflection)
// to inspect the tuple's elements.
//
// Two-stage check:
// 1. Protocol check — TupleView conforms to _TupleViewProtocol for explicit extraction.
// 2. Mirror fallback — raw tuples from nested result builders.
// 3. Single view — if neither, it's one child.
//
// This is the [Any] boxing hot path (HYP-5). Parameter packs will replace it.

func extractChildren(from value: Any) -> [Any] {
    let mirror = Mirror(reflecting: value)

    if let tupleView = value as? any _TupleViewProtocol {
        return tupleView.children()
    }

    if mirror.displayStyle == .tuple {
        return mirror.children.map(\.value)
    }

    return [value]
}

protocol _TupleViewProtocol {
    func children() -> [Any]
}

extension TupleView: _TupleViewProtocol {
    public func children() -> [Any] {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .tuple {
            return mirror.children.map(\.value)
        }
        return [value]
    }
}

extension TupleView: _GraphVStack {
    func graphChildren() -> [Any] {
        extractChildren(from: value)
    }
}

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

// MARK: - ScrollView

extension ScrollView: _GraphScrollView {
    var scrollAxis: ScrollAxis { axes }

    func graphChild() -> Any { content }
}

// MARK: - GeometryReader

extension GeometryReader: _GraphGeometryReader {
    /// Erase `Content` by returning an `any TerminalView`. The graph's
    /// `constructAnyView` handles the rebuild on the fresh value each frame.
    func rebuild(with size: Size) -> any TerminalView {
        content(size)
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
        case let frm as FrameModifier: .frame(width: frm.width, height: frm.height, minWidth: frm.minWidth, maxWidth: frm.maxWidth, minHeight: frm.minHeight, maxHeight: frm.maxHeight)
        case let idm as IDModifier: .explicitID(idm.id)
        case is any _OverlayModifierProtocol: .overlay
        case is any _BackgroundViewModifierProtocol: .backgroundView
        case let modal as any _ModalModifierProtocol: .modal(isPresented: modal.modalIsPresented)
        case is FocusableModifier: .focusable
        case let scope as FocusScopeModifier: .focusScope(scope.id)
        case is OnKeyPressModifier: .onKeyPress
        case is OnAppearModifier: .onAppear
        case is OnClickModifier: .onClick
        case let env as any _AnyEnvironmentModifier: .environment(env.apply(to:))
        default:
            #if DEBUG
            fatalError("Unmapped modifier: \(type(of: modifier))")
            #else
            .bold
            #endif
        }
    }

    func constructChildNode(id: NodeID, graph: AttributeGraph) -> AttributeNode {
        let node = graph.constructNode(for: content, id: id)
        // Register focus-related modifiers (onKeyPress, etc.)
        FocusGraphIntegration.registerIfNeeded(modifier: modifier, nodeID: id)
        return node
    }

    func updateChild(_ child: AttributeNode, graph: AttributeGraph) {
        graph.updateNode(child, from: content)
        // Re-register on every update since handlers are cleared each frame
        FocusGraphIntegration.registerIfNeeded(modifier: modifier, nodeID: child.id)
        // Fire lifecycle events
        FocusGraphIntegration.fireLifecycleIfNeeded(modifier: modifier, node: child)
    }

    func constructExtraChild(id: NodeID, graph: AttributeGraph) -> AttributeNode? {
        if let ovl = modifier as? any _OverlayModifierProtocol {
            return ovl.constructOverlayNode(id: id, graph: graph)
        }
        if let bg = modifier as? any _BackgroundViewModifierProtocol {
            return bg.constructBackgroundNode(id: id, graph: graph)
        }
        if let modal = modifier as? any _ModalModifierProtocol, modal.modalIsPresented {
            return modal.constructModalNode(id: id, graph: graph)
        }
        return nil
    }

    func updateExtraChild(_ child: AttributeNode, graph: AttributeGraph) {
        if let ovl = modifier as? any _OverlayModifierProtocol {
            ovl.updateOverlayNode(child, graph: graph)
        } else if let bg = modifier as? any _BackgroundViewModifierProtocol {
            bg.updateBackgroundNode(child, graph: graph)
        } else if let modal = modifier as? any _ModalModifierProtocol {
            modal.updateModalNode(child, graph: graph)
        }
    }
}

// MARK: - ConditionalView

extension ConditionalView: _GraphConditional {
    func constructConditionalNode(id: NodeID, graph: AttributeGraph) -> AttributeNode {
        // Create a wrapper node for the conditional — viewBody with "Conditional" name
        let info = ViewBodyInfo(viewTypeName: "Conditional")
        let node = AttributeNode(id: id, kind: .viewBody(info))

        switch self {
        case .first(let view):
            let childNode = graph.constructNode(for: view, id: id.appending(.conditional(true)))
            childNode.parent = node
            node.children = [childNode]
        case .second(let view):
            let childNode = graph.constructNode(for: view, id: id.appending(.conditional(false)))
            childNode.parent = node
            node.children = [childNode]
        }
        return node
    }

    func updateConditionalNode(_ node: AttributeNode, graph: AttributeGraph) {
        let currentBranch: Bool
        switch self {
        case .first: currentBranch = true
        case .second: currentBranch = false
        }

        // Check what branch was active before
        let existingBranch: Bool?
        if let child = node.children.first,
           let lastComponent = child.id.path.last,
           case .conditional(let b) = lastComponent {
            existingBranch = b
        } else {
            existingBranch = nil
        }

        if currentBranch == existingBranch {
            // Same branch — update child in place
            switch self {
            case .first(let view):
                if let child = node.children.first {
                    graph.updateNode(child, from: view)
                }
            case .second(let view):
                if let child = node.children.first {
                    graph.updateNode(child, from: view)
                }
            }
        } else {
            // Branch flipped — rebuild child
            graph.changed = true
            node.children.removeAll()
            switch self {
            case .first(let view):
                let childNode = graph.constructNode(for: view, id: node.id.appending(.conditional(true)))
                childNode.parent = node
                node.children = [childNode]
            case .second(let view):
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
        for element in data {
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
        for element in data {
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
