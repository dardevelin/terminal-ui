public protocol TerminalView {
    associatedtype Body: TerminalView
    @TerminalViewBuilder var body: Body { get }
}

// Primitive views have Body == Never and render directly
extension Never: TerminalView {
    public var body: Never { fatalError() }
}

// Result builder for composing views
@resultBuilder
public struct TerminalViewBuilder {
    public static func buildBlock() -> EmptyView {
        EmptyView()
    }

    public static func buildBlock<V: TerminalView>(_ view: V) -> V {
        view
    }

    public static func buildBlock<each V: TerminalView>(_ views: repeat each V) -> TupleView<(repeat each V)> {
        TupleView((repeat each views))
    }

    public static func buildOptional<V: TerminalView>(_ view: V?) -> ConditionalView<V, EmptyView> {
        if let view {
            ConditionalView.first(view)
        } else {
            ConditionalView.second(EmptyView())
        }
    }

    public static func buildEither<First: TerminalView, Second: TerminalView>(first: First) -> ConditionalView<First, Second> {
        .first(first)
    }

    public static func buildEither<First: TerminalView, Second: TerminalView>(second: Second) -> ConditionalView<First, Second> {
        .second(second)
    }
}

// Container for multiple views from result builder
public struct TupleView<Content>: TerminalView {
    public let value: Content

    public init(_ value: Content) {
        self.value = value
    }

    public var body: Never { fatalError() }
}

// Conditional branching
public enum ConditionalView<First: TerminalView, Second: TerminalView>: TerminalView {
    case first(First)
    case second(Second)

    public var body: Never { fatalError() }
}

// Empty placeholder
public struct EmptyView: TerminalView {
    public init() {}
    public var body: Never { fatalError() }
}

/// A transparent container that groups multiple views without affecting layout.
///
/// `Group` has no visual representation of its own — it renders exactly like
/// its content would if the `Group` weren't there. The point is to provide a
/// single view on which to apply modifiers (`.wrap(.none)`, `.foreground(...)`,
/// environment sets) so they propagate to every descendant.
///
/// ```swift
/// Group {
///     Text("row 1")
///     Text("row 2")
/// }
/// .foreground(.cyan)   // both rows cyan
/// ```
///
/// Under if/else in a builder, `Group` collapses return-type differences when
/// combined with a modifier — apply the modifier once to the group rather than
/// to every branch of the switch.
public struct Group<Content: TerminalView>: TerminalView {
    public let content: Content

    public init(@TerminalViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Content { content }
}
