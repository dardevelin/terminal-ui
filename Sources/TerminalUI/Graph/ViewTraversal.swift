/// Walks a tree of *view values* — the structures a `@TerminalViewBuilder`
/// produces, before the graph turns them into nodes.
///
/// Three unrelated features need this: `Picker` recovering tagged options,
/// `Form` measuring its label column, and `Section` deciding whether it is
/// empty. It lives here rather than beside any one of them because a change to
/// the traversal is a change to all three.

enum ViewTree {
/// The child views of `value`, or an empty list when it is a leaf.
///
/// This mirrors `AttributeGraph.constructNode`'s dispatch: try each
/// container witness, and fall back to **evaluating the view's `body`**.
/// That last step is what makes the traversal general — a user-written
/// view, a modifier, or any container the graph understands all resolve,
/// instead of only the handful this file could name. Enumerating
/// container types by hand silently dropped options inside a
/// `ScrollView`, behind any modifier applied after `.tag()`, and in every
/// composite view's body.
///
/// Returning `[]` for a leaf — rather than the value itself, as
/// `extractChildren` does — is what makes the recursion terminate.
static func children(of value: Any) -> [Any] {
    // Containers whose children are built lazily or hidden in an enum
    // payload state their own expansion.
    if let source = value as? any _ViewTreeChildren {
        return source.treeChildren()
    }
    if let stack = value as? any _GraphVStack { return stack.graphChildren() }
    if let stack = value as? any _GraphHStack { return stack.graphChildren() }
    if let stack = value as? any _GraphZStack { return stack.graphChildren() }
    if let scroll = value as? any _GraphScrollView { return [scroll.graphChild()] }
    // A modifier wraps exactly one content view. Reaching it through the
    // protocol keeps `.tag()` composable with every modifier, present and
    // future, rather than only those this file happens to know.
    if let modified = value as? any _ModifiedContentSource {
        return [modified.modifiedContent]
    }

    // A bare builder tuple, which is not itself a view.
    let flattened = extractChildren(from: value)
    if flattened.count != 1 || type(of: flattened[0]) != type(of: value) {
        return flattened
    }

    // Not a container the graph knows: evaluate its body, exactly as
    // `constructComposite` does. Views with `Body == Never` are true
    // leaves and stop here.
    if let composite = value as? any TerminalView {
        return composite.bodyChildren()
    }
    return []
}

    /// The first non-empty `Text` beneath `value`, as a plain string.
    ///
    /// Used wherever a label has to be measured or reprinted without
    /// re-rendering its subtree — a picker's segment titles, a form's label
    /// column, a section's header.
    static func firstText(in value: Any) -> String {
        if let text = value as? Text { return text.content }
        for child in children(of: value) {
            let nested = firstText(in: child)
            if !nested.isEmpty { return nested }
        }
        return ""
    }
}

/// Expands a container the generic `extractChildren` flattening cannot open.
///
/// `ForEach` builds its elements lazily at node construction and
/// `ConditionalView` is an enum whose payload Mirror does not surface as a
/// child — both have dedicated graph protocols for the same reason. Option
/// collection needs them as plain values, so each states here how it unfolds
/// rather than leaving the walker to special-case types it does not own.
protocol _ViewTreeChildren {
    func treeChildren() -> [Any]
}

extension ForEach: _ViewTreeChildren {
    func treeChildren() -> [Any] { data.map(content) }
}

extension ForEachWithID: _ViewTreeChildren {
    func treeChildren() -> [Any] { data.map(content) }
}

/// Reads the content a modifier wraps, without knowing either generic
/// parameter. `ModifiedView` is the single modifier representation in the
/// framework, so one conformance covers every `.foreground`, `.padding`,
/// `.focusable` and so on — including modifiers added later.
protocol _ModifiedContentSource {
    var modifiedContent: Any { get }
}

extension ModifiedView: _ModifiedContentSource {
    var modifiedContent: Any { content }
}

extension TerminalView {
    /// This view's `body` as traversable children, or `[]` for a primitive.
    ///
    /// Primitives declare `Body == Never` and would trap on `body`, which is
    /// the same guard `AttributeGraph.constructComposite` applies before
    /// evaluating.
    ///
    /// Evaluation happens outside a graph node, so `@TerminalState` reads in
    /// the body see their initial values. That is correct here: a body whose
    /// *option set* depends on view-local mutable state has no stable identity
    /// for selection to bind to.
    func bodyChildren() -> [Any] {
        guard Body.self != Never.self else { return [] }
        return [body]
    }
}

extension ConditionalView: _ViewTreeChildren {
    /// Only the taken branch contributes — the untaken one is not on screen
    /// and must not be selectable.
    func treeChildren() -> [Any] {
        switch self {
        case .first(let view): [view]
        case .second(let view): [view]
        }
    }
}
