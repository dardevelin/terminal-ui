import Observation

/// The attribute graph — persistent DAG of typed nodes.
/// Owns the root node, manages reconciliation, tracks dirty state.
/// First frame: builds from scratch. Subsequent frames: updates in place.
public final class AttributeGraph {
    public var root: AttributeNode?
    public var hasDirtyNodes: Bool = false

    public init() {}

    // MARK: - Public API

    /// Build or update the graph from a view tree.
    /// Returns true if any node values actually changed.
    @discardableResult
    public func update<V: TerminalView>(from view: V) -> Bool {
        if let existing = root {
            changed = false
            updateNode(existing, from: view)
            // Clear dirty AFTER update — Observation may set it again
            // for the next state change during re-evaluation
            hasDirtyNodes = false
            return changed
        } else {
            root = constructNode(for: view, id: .root)
            hasDirtyNodes = false
            return true
        }
    }

    /// Tracks whether any values changed during update
    private var changed = false

    // MARK: - Body Evaluation with Observation

    /// Evaluate a composite view's body with observation tracking.
    /// Sets GraphContext so @TerminalState can connect to storage.
    /// Uses withObservationTracking so state access creates dependency edges.
    func evaluateBody<V: TerminalView>(node: AttributeNode, view: V) {
        // Set context so @TerminalState finds this node's storage
        let prevNode = GraphContext.currentNode
        let prevGraph = GraphContext.currentGraph
        GraphContext.currentNode = node
        GraphContext.currentGraph = self

        // Evaluate body with observation tracking
        nonisolated(unsafe) let capturedNode = node
        nonisolated(unsafe) let capturedGraph = self
        let body: V.Body = withObservationTracking {
            view.body
        } onChange: {
            capturedNode.markDirty()
            capturedGraph.hasDirtyNodes = true
        }

        // Restore context
        GraphContext.currentNode = prevNode
        GraphContext.currentGraph = prevGraph

        // Update or create child from body result
        if let child = node.children.first {
            updateNode(child, from: body)
        } else {
            let childNode = constructNode(for: body, id: node.id.appending(.index(0)))
            childNode.parent = node
            node.children = [childNode]
        }

        // If the body produced different output, mark changed
        if node.isDirty {
            changed = true
            node.isDirty = false
        }
    }

    // MARK: - In-Place Update

    /// Update an existing node with a new view value.
    /// If the structure matches, update values in place (zero allocation).
    /// If structure changed, rebuild the subtree.
    func updateNode<V: TerminalView>(_ node: AttributeNode, from view: V) {
        // Try to update primitives in place
        if updatePrimitive(node, from: view) {
            return
        }

        // Layout containers — update children in place
        if let vstack = view as? any _GraphVStack {
            if case .layout(let info) = node.kind, info.kind == .vstack {
                updateLayoutChildren(node, from: vstack.graphChildren())
                return
            }
        }
        if let hstack = view as? any _GraphHStack {
            if case .layout(let info) = node.kind, info.kind == .hstack {
                updateLayoutChildren(node, from: hstack.graphChildren())
                return
            }
        }

        // Modifiers — update effect + child
        if let modified = view as? any _GraphModified {
            if case .modifier = node.kind {
                node.kind = .modifier(modified.graphEffect())
                if let child = node.children.first {
                    modified.updateChild(child, graph: self)
                }
                return
            }
        }

        // Conditional — check if branch changed
        if let cond = view as? any _GraphConditional {
            cond.updateConditionalNode(node, graph: self)
            return
        }

        // Composite view — re-evaluate body with observation tracking
        if !(V.Body.self == Never.self) {
            evaluateBody(node: node, view: view)
            return
        }
    }

    /// Update primitive values in place — no allocation.
    /// Only sets `changed` if the value actually differs.
    func updatePrimitive<V: TerminalView>(_ node: AttributeNode, from view: V) -> Bool {
        if let text = view as? Text {
            if case .primitive(.text(let old)) = node.kind {
                if old != text.content {
                    node.kind = .primitive(.text(text.content))
                    changed = true
                }
                return true
            }
        }
        if view is Spacer {
            if case .primitive(.spacer) = node.kind { return true }
        }
        if let bar = view as? ProgressBar {
            if case .primitive(.progressBar(let oldVal, _, _, _)) = node.kind {
                if oldVal != bar.value {
                    node.kind = .primitive(.progressBar(
                        value: bar.value, label: bar.label, filled: bar.filled, empty: bar.empty
                    ))
                    changed = true
                }
                return true
            }
        }
        if let spinner = view as? Spinner {
            if case .primitive(.spinner(let oldFrame, _)) = node.kind {
                if oldFrame != spinner.frame {
                    node.kind = .primitive(.spinner(frame: spinner.frame, style: spinner.style))
                    changed = true
                }
                return true
            }
        }
        if view is EmptyView {
            if case .primitive(.empty) = node.kind { return true }
        }
        return false
    }

    /// Update layout container children in place.
    func updateLayoutChildren(_ node: AttributeNode, from newChildren: [Any]) {
        if node.children.count == newChildren.count {
            // Same count — update each child in place
            for (i, newChild) in newChildren.enumerated() {
                updateAnyView(node.children[i], from: newChild)
            }
        } else {
            // Child count changed — rebuild children
            node.children.removeAll(keepingCapacity: true)
            for (i, child) in newChildren.enumerated() {
                let childID = node.id.appending(.index(i))
                let childNode = constructAnyView(child, id: childID)
                childNode.parent = node
                node.children.append(childNode)
            }
        }
    }

    /// Type-erased update — opens the existential to call the generic version.
    func updateAnyView(_ node: AttributeNode, from view: Any) {
        if let tv = view as? any TerminalView {
            updateAnyTerminalView(node, from: tv)
        }
    }

    func updateAnyTerminalView<V: TerminalView>(_ node: AttributeNode, from view: V) {
        updateNode(node, from: view)
    }

    // MARK: - Initial Construction (first frame only)

    func constructNode<V: TerminalView>(for view: V, id: NodeID) -> AttributeNode {
        if let node = constructPrimitive(for: view, id: id) {
            return node
        }
        if let vstack = view as? any _GraphVStack {
            return constructVStack(vstack, id: id)
        }
        if let hstack = view as? any _GraphHStack {
            return constructHStack(hstack, id: id)
        }
        if let modified = view as? any _GraphModified {
            return constructModifier(modified, id: id)
        }
        if let cond = view as? any _GraphConditional {
            return cond.constructConditionalNode(id: id, graph: self)
        }
        return constructComposite(view, id: id)
    }

    func constructPrimitive<V: TerminalView>(for view: V, id: NodeID) -> AttributeNode? {
        if let text = view as? Text {
            return AttributeNode(id: id, kind: .primitive(.text(text.content)))
        }
        if view is Spacer {
            return AttributeNode(id: id, kind: .primitive(.spacer))
        }
        if let bar = view as? ProgressBar {
            return AttributeNode(id: id, kind: .primitive(
                .progressBar(value: bar.value, label: bar.label, filled: bar.filled, empty: bar.empty)
            ))
        }
        if let spinner = view as? Spinner {
            return AttributeNode(id: id, kind: .primitive(.spinner(frame: spinner.frame, style: spinner.style)))
        }
        if view is EmptyView {
            return AttributeNode(id: id, kind: .primitive(.empty))
        }
        return nil
    }

    func constructVStack(_ vstack: any _GraphVStack, id: NodeID) -> AttributeNode {
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .vstack)))
        let children = vstack.graphChildren()
        for (i, child) in children.enumerated() {
            let childID = id.appending(.index(i))
            let childNode = constructAnyView(child, id: childID)
            childNode.parent = node
            node.children.append(childNode)
        }
        return node
    }

    func constructHStack(_ hstack: any _GraphHStack, id: NodeID) -> AttributeNode {
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .hstack)))
        let children = hstack.graphChildren()
        for (i, child) in children.enumerated() {
            let childID = id.appending(.index(i))
            let childNode = constructAnyView(child, id: childID)
            childNode.parent = node
            node.children.append(childNode)
        }
        return node
    }

    func constructModifier(_ modified: any _GraphModified, id: NodeID) -> AttributeNode {
        let effect = modified.graphEffect()
        let node = AttributeNode(id: id, kind: .modifier(effect))
        let childID = id.appending(.index(0))
        let childNode = modified.constructChildNode(id: childID, graph: self)
        childNode.parent = node
        node.children.append(childNode)
        return node
    }

    func constructComposite<V: TerminalView>(_ view: V, id: NodeID) -> AttributeNode {
        guard !(V.Body.self == Never.self) else {
            return AttributeNode(id: id, kind: .primitive(.empty))
        }
        let info = ViewBodyInfo(viewTypeName: String(describing: V.self))
        let node = AttributeNode(id: id, kind: .viewBody(info))

        // Set context and evaluate with observation
        let prevNode = GraphContext.currentNode
        let prevGraph = GraphContext.currentGraph
        GraphContext.currentNode = node
        GraphContext.currentGraph = self

        nonisolated(unsafe) let capturedNode2 = node
        nonisolated(unsafe) let capturedGraph2 = self
        let body: V.Body = withObservationTracking {
            view.body
        } onChange: {
            capturedNode2.markDirty()
            capturedGraph2.hasDirtyNodes = true
        }

        GraphContext.currentNode = prevNode
        GraphContext.currentGraph = prevGraph

        let childID = id.appending(.index(0))
        let childNode = constructNode(for: body, id: childID)
        childNode.parent = node
        node.children.append(childNode)
        node.isDirty = false
        return node
    }

    func constructAnyView(_ view: Any, id: NodeID) -> AttributeNode {
        if let tv = view as? any TerminalView {
            return constructAnyTerminalView(tv, id: id)
        }
        return AttributeNode(id: id, kind: .primitive(.empty))
    }

    func constructAnyTerminalView<V: TerminalView>(_ view: V, id: NodeID) -> AttributeNode {
        constructNode(for: view, id: id)
    }
}

// MARK: - Protocols for graph construction

protocol _GraphVStack {
    func graphChildren() -> [Any]
}

protocol _GraphHStack {
    func graphChildren() -> [Any]
}

protocol _GraphModified {
    func graphEffect() -> ModifierEffect
    func constructChildNode(id: NodeID, graph: AttributeGraph) -> AttributeNode
    func updateChild(_ child: AttributeNode, graph: AttributeGraph)
}

protocol _GraphConditional {
    func constructConditionalNode(id: NodeID, graph: AttributeGraph) -> AttributeNode
    func updateConditionalNode(_ node: AttributeNode, graph: AttributeGraph)
}
