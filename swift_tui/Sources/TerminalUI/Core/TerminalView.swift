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
