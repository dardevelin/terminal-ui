/// Hit testing — map (x,y) screen coordinates to graph nodes.
///
/// After rendering, every node has a resolved rect (set by GraphRenderer).
/// Hit test walks the graph depth-first, children in reverse order
/// (last child = highest z-order, matching render order where last
/// child paints on top). Returns the deepest node containing the point.
///
/// Modal occlusion: while a presentation is up, the one drawn on top owns
/// the screen, wherever in the tree it was declared. A point inside its
/// content searches only that content; a point in the dimmed area around it
/// is consumed by the modal node — no passthrough to what lies underneath.

public enum HitTest {

    /// Find the deepest node at the given screen coordinate.
    /// Returns the node and its full ancestor chain.
    public static func nodeAt(x: Int, y: Int, root: AttributeNode?) -> HitResult? {
        guard let root else { return nil }
        let topmost = Presentations(in: root).topmost
        guard let scope = Presentations.pointerScope(x: x, y: y, root: root, topmost: topmost) else {
            // The dim around the dialog on top, which its modal owns.
            return topmost?.parent.map { HitResult(node: $0, path: $0.ancestors + [$0]) }
        }
        var path = scope.ancestors
        return search(x: x, y: y, node: scope, path: &path).map { HitResult(node: $0, path: path) }
    }

    private static func search(x: Int, y: Int, node: AttributeNode, path: inout [AttributeNode]) -> AttributeNode? {
        guard node.rect.contains(x: x, y: y) else { return nil }

        path.append(node)

        // Search children in reverse order (last child = highest z-order)
        for child in node.children.reversed() {
            if let found = search(x: x, y: y, node: child, path: &path) {
                return found
            }
        }

        // No child contains the point — this node owns it
        return node
    }
}

/// What a hit-test at a cell position found: the deepest node whose rect
/// contains the point, plus how the walk got there.
public struct HitResult {
    /// The deepest node at the hit point
    public let node: AttributeNode
    /// Ancestor chain from root to the hit node
    public let path: [AttributeNode]

    /// Formatted description of declared modifiers on this node
    public var declaredValues: [(String, String)] {
        var values: [(String, String)] = []

        switch node.kind {
        case .primitive(let content):
            switch content {
            case .text(let spans):
                values.append(("type", "Text"))
                let s = spans.map(\.text).joined()
                values.append(("content", s.count > 30 ? String(s.prefix(30)) + "..." : s))
            case .spacer:
                values.append(("type", "Spacer"))
            case .divider:
                values.append(("type", "Divider"))
            case .progressBar(let v, _, _, _):
                values.append(("type", "ProgressBar"))
                values.append(("value", "\(Int(v * 100))%"))
            case .spinner(let f, _):
                values.append(("type", "Spinner"))
                values.append(("frame", "\(f)"))
            case .empty:
                values.append(("type", "Empty"))
            case .cellBuffer(let buf):
                values.append(("type", "BufferView"))
                values.append(("size", "\(buf.width)x\(buf.height)"))
            }

        case .layout(let info):
            switch info.kind {
            case .vstack: values.append(("type", "VStack"))
            case .hstack: values.append(("type", "HStack"))
            case .zstack: values.append(("type", "ZStack"))
            case .scroll(let axis):
                values.append(("type", axis == .horizontal ? "ScrollView(H)" : "ScrollView(V)"))
            case .split(let axis):
                values.append(("type", axis == .horizontal ? "SplitView(H)" : "SplitView(V)"))
            }
            values.append(("children", "\(node.children.count)"))

        case .modifier(let effect):
            switch effect {
            case .foreground(let c): values.append(("modifier", "foreground(\(c))"))
            case .background(let c): values.append(("modifier", "background(\(c.groundDescription))"))
            case .bold: values.append(("modifier", "bold"))
            case .italic: values.append(("modifier", "italic"))
            case .underline: values.append(("modifier", "underline"))
            case .padding(let n): values.append(("modifier", "padding(\(n))"))
            case .border(let s, _, _): values.append(("modifier", "border(\(s))"))
            case .frame(let w, let h, _, _, _, _, _): values.append(("modifier", "frame(\(w ?? 0)x\(h ?? 0))"))
            case .flexible(let axes, let grow): values.append(("modifier", "flexible(axes:\(axes.rawValue),grow:\(grow))"))
            case .explicitID(let id): values.append(("modifier", "id(\(id))"))
            case .overlay: values.append(("modifier", "overlay"))
            case .backgroundView: values.append(("modifier", "backgroundView"))
            case .modal(let p): values.append(("modifier", "modal(\(p))"))
            case .focusable: values.append(("modifier", "focusable"))
            case .focusScope(let id): values.append(("modifier", "focusScope(\(id))"))
            case .prefersDefaultFocus(let prefers): values.append(("modifier", "prefersDefaultFocus(\(prefers))"))
            case .onKeyPress: values.append(("modifier", "onKeyPress"))
            case .onAppear: values.append(("modifier", "onAppear"))
            case .onChange: values.append(("modifier", "onChange"))
            case .onDisappear: values.append(("modifier", "onDisappear"))
            case .task: values.append(("modifier", "task"))
            case .onClick: values.append(("modifier", "onClick"))
            case .onHover: values.append(("modifier", "onHover"))
            case .onPaste: values.append(("modifier", "onPaste"))
            case .environment: values.append(("modifier", "environment"))
            case .actions(let scope): values.append(("modifier", "actions(bound:\(scope.boundActions.count))"))
            }

        case .viewBody(let info):
            values.append(("type", info.viewTypeName))
        }

        return values
    }

    /// Resolved rect from layout
    public var resolvedRect: (x: Int, y: Int, width: Int, height: Int) {
        (node.rect.x, node.rect.y, node.rect.width, node.rect.height)
    }

    /// Full modifier chain from root to this node
    public var modifierChain: [String] {
        path.compactMap { ancestor in
            if case .modifier(let effect) = ancestor.kind {
                switch effect {
                case .foreground(let c): return "fg(\(c))"
                case .background(let c): return "bg(\(c.groundDescription))"
                case .bold: return "bold"
                case .italic: return "italic"
                case .underline: return "underline"
                case .padding(let n): return "pad(\(n))"
                case .border: return "border"
                case .frame(let w, let h, _, _, _, _, _): return "frame(\(w ?? 0)x\(h ?? 0))"
                case .flexible(let axes, let grow): return "flexible(axes:\(axes.rawValue),grow:\(grow))"
                case .explicitID(_): return "id"
                case .overlay: return "overlay"
                case .backgroundView: return "bgView"
                case .modal(_): return "modal"
                case .focusable: return "focusable"
                case .focusScope(let id): return "focusScope(\(id))"
                case .prefersDefaultFocus(let prefers): return "prefersDefaultFocus(\(prefers))"
                case .onKeyPress: return "onKeyPress"
                case .onAppear: return "onAppear"
                case .onChange: return "onChange"
                case .onDisappear: return "onDisappear"
                case .task: return "task"
                case .onClick: return "onClick"
                case .onHover: return "onHover"
                case .onPaste: return "onPaste"
                case .environment: return "environment"
                case .actions(let scope): return "actions(\(scope.boundActions.count))"
                }
            }
            return nil
        }
    }
}
