/// The basic building block of a TerminalUI interface — the terminal
/// counterpart of SwiftUI's `View`.
///
/// A view is an immutable value describing what to draw; the framework
/// reconciles successive values into a persistent attribute graph, so a
/// `body` re-evaluation is cheap and carries no identity of its own.
/// Compose views exactly as in SwiftUI:
///
/// ```swift
/// struct StatusRow: TerminalView {
///     let name: String
///     var body: some TerminalView {
///         HStack {
///             Text(name).bold()
///             Spacer()
///             Text("ok").foreground(.green)
///         }
///     }
/// }
/// ```
///
/// Sizes are terminal cells, not points: one cell per column, wide glyphs
/// (CJK, emoji) occupy two. Primitives the framework draws directly have
/// `Body == Never`; everything user-written returns `some TerminalView`.
public protocol TerminalView {
    /// The type of view produced by ``body``, inferred from its return type.
    associatedtype Body: TerminalView
    /// The view's content. Must be a pure function of the view's stored
    /// properties and observable state — the runtime re-evaluates it whenever
    /// that state changes, and reads through `@Observable` models are what
    /// register the dependency.
    @TerminalViewBuilder var body: Body { get }
}

/// `Never` conforms to `TerminalView` so primitive views can declare
/// `Body == Never` — the graph renders them directly and their `body` is
/// never evaluated.
extension Never: TerminalView {
    @_documentation(visibility: internal)
    public var body: Never { fatalError() }
}

/// The result builder behind every `body` and container closure — the
/// terminal counterpart of SwiftUI's `ViewBuilder`.
///
/// You never call its methods; the compiler does, translating multi-view
/// blocks into ``TupleView``, `if`/`else` into ``ConditionalView``, and an
/// empty block into ``EmptyView``. Annotate your own container closures with
/// `@TerminalViewBuilder` to accept the same declaration syntax.
@resultBuilder
public struct TerminalViewBuilder {
    /// An empty block produces ``EmptyView`` — zero cells, no layout effect.
    public static func buildBlock() -> EmptyView {
        EmptyView()
    }

    /// A single view passes through unwrapped, preserving its concrete type.
    public static func buildBlock<V: TerminalView>(_ view: V) -> V {
        view
    }

    /// Two or more sibling views pack into one ``TupleView``. Parameter-pack
    /// generic, so there is no arity ceiling.
    public static func buildBlock<each V: TerminalView>(_ views: repeat each V) -> TupleView<(repeat each V)> {
        TupleView((repeat each views))
    }

    /// `if` without `else`: the missing branch becomes ``EmptyView``, so the
    /// result type is stable whether or not the condition holds.
    public static func buildOptional<V: TerminalView>(_ view: V?) -> ConditionalView<V, EmptyView> {
        if let view {
            ConditionalView.first(view)
        } else {
            ConditionalView.second(EmptyView())
        }
    }

    /// The `if` branch of an `if`/`else`, preserved as
    /// ``ConditionalView/first(_:)`` so each branch keeps a stable graph
    /// identity.
    public static func buildEither<First: TerminalView, Second: TerminalView>(first: First) -> ConditionalView<First, Second> {
        .first(first)
    }

    /// The `else` branch of an `if`/`else`, preserved as
    /// ``ConditionalView/second(_:)``.
    public static func buildEither<First: TerminalView, Second: TerminalView>(second: Second) -> ConditionalView<First, Second> {
        .second(second)
    }
}

/// Several sibling views packaged into one value by ``TerminalViewBuilder``.
///
/// Produced whenever a builder block lists more than one view; the graph
/// flattens it back into individual children, so it never affects layout.
/// You don't create these directly — they only appear in inferred
/// `some TerminalView` types.
public struct TupleView<Content>: TerminalView {
    /// The packed tuple of sibling views, in declaration order.
    public let value: Content

    /// Wraps an already-formed tuple of views. Called by
    /// ``TerminalViewBuilder``'s variadic `buildBlock`, not by app code.
    public init(_ value: Content) {
        self.value = value
    }

    @_documentation(visibility: internal)
    public var body: Never { fatalError() }
}

/// One of two views, chosen by an `if`/`else` in a ``TerminalViewBuilder``
/// block.
///
/// Keeping both branch types in the generic signature is what gives each
/// branch a stable graph identity: switching branches replaces the subtree
/// (state resets, `onAppear` fires) rather than updating it in place.
public enum ConditionalView<First: TerminalView, Second: TerminalView>: TerminalView {
    /// The `if` branch (or the wrapped view of an `if` without `else`).
    case first(First)
    /// The `else` branch (or ``EmptyView`` for an `if` without `else`).
    case second(Second)

    @_documentation(visibility: internal)
    public var body: Never { fatalError() }
}

/// A view that draws nothing and takes no space.
///
/// Stacks skip it entirely — it contributes no cell and no spacing slot.
/// Mostly produced by ``TerminalViewBuilder`` for empty blocks and missing
/// `else` branches; write it yourself where a `TerminalView` is required but
/// there is nothing to show.
public struct EmptyView: TerminalView {
    /// Creates an empty view. Stateless — every instance is identical.
    public init() {}
    @_documentation(visibility: internal)
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
    /// The grouped children, passed through to layout unchanged.
    public let content: Content

    /// Creates a group; the builder's children flow into the enclosing
    /// container as if declared directly.
    public init(@TerminalViewBuilder content: () -> Content) {
        self.content = content()
    }

    @_documentation(visibility: internal)
    public var body: Content { content }
}
