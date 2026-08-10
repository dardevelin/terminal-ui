// Connect existing view types to the attribute graph.

// MARK: - TupleView unpacking
//
// `@TerminalViewBuilder` produces `TupleView<(V0, V1, ...)>` wrapping a
// tuple. The framework needs the individual children for layout, focus,
// and reconciliation, so containers call `extractChildren(from:)` to
// flatten the wrapper.
//
// Dispatch story (cheap → expensive):
//
// 1. **Explicit protocol path.** `TupleView` conforms to
//    `_TupleViewProtocol`; `extractChildren` invokes its `children()`
//    method directly. No reflection.
// 2. **Mirror fallback.** Raw tuples (e.g. nested result builders that
//    surface a tuple value without the `TupleView` wrapper) walk a
//    `Mirror` to enumerate elements. Pays the runtime-reflection cost
//    every frame the container re-evaluates.
// 3. **Single view.** Anything else returns `[value]` and is treated
//    as one child.
//
// Cost-bearing audience:
//
// - `extractChildren` is called only from the built-in container
//   conformances of `_GraphVStack` / `_GraphHStack` / `_GraphZStack`
//   (`TupleView`, `VStack`, `HStack`, `ZStack` extensions in this
//   file). User-defined composite views never enter this function
//   directly — their bodies become `.viewBody` nodes whose children
//   are extracted via the protocol of whatever container *those*
//   bodies return.
// - The Mirror fallback at step 2 fires for raw tuple values inside
//   a built-in container's `content`, so a user nesting two-stage
//   result builders inside a `VStack` can pay it. App authors who
//   write a custom container and want to participate in the graph's
//   per-child reconciliation must conform their container to
//   `_GraphVStack` (or sibling) and provide an explicit
//   `graphChildren()` that does NOT route through Mirror.
//
// Replacing the Mirror fallback with parameter packs would let us
// type-erase the children list without reflection, but the rewrite
// has reverted once already, so the cost is documented here as the
// stable fall-back rather than removed.

/// Flatten a `@TerminalViewBuilder` tuple value into its individual
/// child views for the attribute graph. See the file-header comment
/// for the dispatch story and which call paths pay the Mirror cost.
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
    /// The packed sibling views as an erased array, in declaration order.
    /// Graph plumbing — reconciliation flattens the tuple through this;
    /// a non-tuple `Content` (single view) yields a one-element array.
    public func children() -> [Any] {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .tuple {
            return mirror.children.map(\.value)
        }
        return [value]
    }
}

extension TupleView: _GraphVStack {
    /// TupleView is a synthetic grouping from the `@TerminalViewBuilder`
    /// result builder — several sibling views packaged into a single
    /// `Content` associatedtype. It's NOT a user-written VStack even
    /// though the graph represents it as one for layout convenience.
    /// `structuralVStack` opts the construction into
    /// `LayoutInfo.isStructural = true` so focus navigation and
    /// measurement routing treat it as transparent.
    var isStructuralVStack: Bool { true }

    func graphChildren() -> [Any] {
        extractChildren(from: value)
    }
}

// MARK: - VStack

extension VStack: _GraphVStack {
    func graphChildren() -> [Any] {
        extractChildren(from: content)
    }
    var layoutSpacing: Int { spacing }
    var layoutAlignment: Alignment {
        Alignment(horizontal: alignment, vertical: .top)
    }
}

// MARK: - HStack

extension HStack: _GraphHStack {
    func graphChildren() -> [Any] {
        extractChildren(from: content)
    }
    var layoutSpacing: Int { spacing }
    var layoutAlignment: Alignment {
        Alignment(horizontal: .leading, vertical: alignment)
    }
}

// MARK: - ScrollView

extension ScrollView: _GraphScrollView {
    var scrollAxis: ScrollAxis { axes }

    func graphChild() -> Any { content }
}

// MARK: - SplitView

extension SplitView: _GraphSplitView {}

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
        case let frm as FrameModifier: .frame(width: frm.width, height: frm.height, minWidth: frm.minWidth, maxWidth: frm.maxWidth, minHeight: frm.minHeight, maxHeight: frm.maxHeight, alignment: frm.alignment)
        case let flex as FlexibleModifier: .flexible(axes: flex.axes, grow: flex.grow)
        case let idm as IDModifier: .explicitID(idm.id)
        case let ovl as any _OverlayModifierProtocol: .overlay(alignment: ovl.overlayAlignment)
        case let bg as any _BackgroundViewModifierProtocol: .backgroundView(alignment: bg.backgroundAlignment)
        case let modal as any _ModalModifierProtocol: .modal(isPresented: modal.modalIsPresented)
        case is FocusableModifier: .focusable
        case let scope as FocusScopeModifier: .focusScope(scope.id)
        case is OnKeyPressModifier: .onKeyPress
        case is OnAppearModifier: .onAppear
        case is any _OnChangeModifierProtocol: .onChange
        case is OnDisappearModifier: .onDisappear
        case is any _TaskModifierProtocol: .task
        case is OnClickModifier: .onClick
        case is OnHoverModifier: .onHover
        case is OnPasteModifier: .onPaste
        case let env as any _AnyEnvironmentModifier: .environment(env.apply(to:))
        case let actions as ActionsModifier: .actions(actions.scope)
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
        // Register focus-related modifiers (onKeyPress, etc.). The handler is
        // stamped on the node too, so a cached update that skips this path
        // still has it for `rebuildIndex` to re-register.
        FocusGraphIntegration.registerIfNeeded(modifier: modifier, node: node)
        return node
    }

    func updateChild(_ child: AttributeNode, graph: AttributeGraph) {
        graph.updateNode(child, from: content)
        // Re-register on every update since handlers are cleared each frame
        FocusGraphIntegration.registerIfNeeded(modifier: modifier, node: child)
    }

    func fireLifecycle(on node: AttributeNode) {
        // Lifecycle dispatch operates on the modifier node itself — this is
        // where `didAppear`, `lastObservedValue`, and `onDisappearAction`
        // live. Called on initial construct AND every update so onChange
        // can compare current vs stored value.
        FocusGraphIntegration.fireLifecycleIfNeeded(modifier: modifier, node: node)
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
            // Branch flipped — rebuild child and invalidate ancestor
            // measurements. The new branch may have a different intrinsic
            // height (e.g. TextInput's validation row appears when the
            // validator returns an error), and without walking up here
            // the parent's `cachedHeight` stays at the pre-flip value —
            // the harness exposed this as a missing "missing @" row.
            graph.changed = true
            // Fire onDisappear on the outgoing branch's subtree before
            // dropping it. Without this, an .onDisappear inside
            // a conditional that flips wouldn't fire.
            for old in node.children {
                graph.fireDisappear(on: old)
            }
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
            node.markDirty()
        }
    }
}

// MARK: - ZStack

extension ZStack: _GraphZStack {
    func graphChildren() -> [Any] {
        extractChildren(from: content)
    }
    var layoutAlignment: Alignment { alignment }
}

// MARK: - ForEach

extension ForEach: _GraphForEach {
    func constructForEachNode(id: NodeID, graph: AttributeGraph) -> AttributeNode {
        // ForEach is a structural layout — transparent to focus navigation
        // + measurement routing (`isStructural: true`).
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .vstack, isStructural: true)))
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
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .vstack, isStructural: true)))
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
