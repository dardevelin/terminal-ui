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
                        PickerOption(value: match, title: ViewTree.firstText(in: tagged.taggedContent))
                    )
                } else {
                    if firstDuplicate == nil { firstDuplicate = match }
                }
                return
            }
            walk(tagged.taggedContent, into: &options, seen: &seen, firstDuplicate: &firstDuplicate)
            return
        }

        for child in ViewTree.children(of: value) {
            walk(child, into: &options, seen: &seen, firstDuplicate: &firstDuplicate)
        }
    }



}
