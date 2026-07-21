/// A view carrying a selection tag, produced by `.tag(_:)`.
///
/// The tag rides in the static type rather than in the render graph. That is
/// the whole design: recovering it is a typed protocol witness instead of an
/// `AnyHashable` downcast, and selection identity stays in the `Binding` where
/// it already lives, so there is no graph state to keep in sync across
/// reconciliation.
///
/// Rendering is pass-through — a tag changes what a `Picker` understands the
/// view to *mean*, never how it draws. Outside a selection container the tag
/// is simply unread, which is why `.tag()` is safe to leave on a view.
public struct TaggedView<Tag: Hashable, Content: TerminalView>: TerminalView {
    public let tag: Tag
    public let content: Content

    public init(tag: Tag, content: Content) {
        self.tag = tag
        self.content = content
    }

    public var body: some TerminalView { content }
}

extension TerminalView {
    /// Tag this view with a value a selection container can match against.
    ///
    /// Mirrors SwiftUI's `.tag(_:)`: a general view modifier, not a
    /// `Picker`-private descriptor. Keeping it general is what lets ordinary
    /// `@TerminalViewBuilder` content — including `ForEach` and `if`/`else` —
    /// supply a picker's options without a bespoke builder:
    ///
    /// ```swift
    /// Picker("Theme", selection: $theme) {
    ///     ForEach(Theme.allCases) { Text($0.title).tag($0) }
    /// }
    /// ```
    public func tag<Tag: Hashable>(_ tag: Tag) -> TaggedView<Tag, Self> {
        TaggedView(tag: tag, content: self)
    }
}

/// Type-erased read side of `TaggedView`, so traversal can ask any value
/// whether it carries a tag without knowing its generic parameters.
protocol _TaggedViewProtocol {
    var pickerTag: any Hashable { get }
    var taggedContent: Any { get }
}

extension TaggedView: _TaggedViewProtocol {
    var pickerTag: any Hashable { tag }
    var taggedContent: Any { content }
}

/// One selectable option recovered from a picker's content.
public struct PickerOption<Value: Hashable>: Equatable {
    /// The tag this option commits when chosen.
    public let value: Value
    /// The rendered label. Extracted from `Text` content where possible so
    /// styles that draw a plain row (segmented, collapsed dropdown) have a
    /// string to lay out without re-rendering the tagged subtree.
    public let title: String

    public init(value: Value, title: String) {
        self.value = value
        self.title = title
    }
}

/// Recovers a picker's options from ordinary view-builder content.
public enum PickerOptions {

    /// Walk `content` and collect every option tagged with `Value`.
    ///
    /// Traversal mirrors the graph's own dispatch and ends by evaluating a
    /// view's `body`, so any construct the builder can express resolves —
    /// see `childViews(of:)`.
    ///
    /// A tag of a different type belongs to some other selection container and
    /// is skipped rather than coerced — coercing would let a mistyped tag
    /// present as a silently missing row.
    static func collect<Value: Hashable>(
        from content: Any,
        as valueType: Value.Type
    ) -> [PickerOption<Value>] {
        var options: [PickerOption<Value>] = []
        var seen: Set<Value> = []
        // Only the first duplicate is ever reported, so this holds one value
        // rather than collecting every occurrence into an array the release
        // build would allocate and never read.
        var firstDuplicate: Value?
        walk(content, into: &options, seen: &seen, firstDuplicate: &firstDuplicate)

        #if DEBUG
        if let first = firstDuplicate {
            DebugStream.shared.emitWarning(
                .pickerDuplicateTags,
                message: """
                    Picker has more than one option tagged \(first). The first \
                    declaration wins and later duplicates are dropped, so the \
                    extra rows would be unreachable. Give each option a \
                    distinct tag.
                    """
            )
        }
        #endif

        return options
    }

    private static func walk<Value: Hashable>(
        _ value: Any,
        into options: inout [PickerOption<Value>],
        seen: inout Set<Value>,
        firstDuplicate: inout Value?
    ) {
        if let tagged = value as? any _TaggedViewProtocol {
            // A tag of the wrong type is not this picker's business, but the
            // subtree beneath it may still hold nested options.
            if let match = tagged.pickerTag as? Value {
                if seen.insert(match).inserted {
                    options.append(
                        PickerOption(value: match, title: title(of: tagged.taggedContent))
                    )
                } else {
                    if firstDuplicate == nil { firstDuplicate = match }
                }
                return
            }
            walk(tagged.taggedContent, into: &options, seen: &seen, firstDuplicate: &firstDuplicate)
            return
        }

        for child in childViews(of: value) {
            walk(child, into: &options, seen: &seen, firstDuplicate: &firstDuplicate)
        }
    }

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
    private static func childViews(of value: Any) -> [Any] {
        // Containers whose children are built lazily or hidden in an enum
        // payload state their own expansion.
        if let source = value as? any _OptionContentSource {
            return source.optionSourceChildren()
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
            return composite.optionBodyChildren()
        }
        return []
    }

    /// Best-effort label for an option row: the first `Text` found beneath it.
    private static func title(of content: Any) -> String {
        if let text = content as? Text { return text.content }
        for child in childViews(of: content) {
            let nested = title(of: child)
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
protocol _OptionContentSource {
    func optionSourceChildren() -> [Any]
}

extension ForEach: _OptionContentSource {
    func optionSourceChildren() -> [Any] { data.map(content) }
}

extension ForEachWithID: _OptionContentSource {
    func optionSourceChildren() -> [Any] { data.map(content) }
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
    func optionBodyChildren() -> [Any] {
        guard Body.self != Never.self else { return [] }
        return [body]
    }
}

extension ConditionalView: _OptionContentSource {
    /// Only the taken branch contributes — the untaken one is not on screen
    /// and must not be selectable.
    func optionSourceChildren() -> [Any] {
        switch self {
        case .first(let view): [view]
        case .second(let view): [view]
        }
    }
}
