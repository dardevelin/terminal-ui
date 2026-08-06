// A view wrapped with a modifier
public struct ModifiedView<Content: TerminalView, Modifier: ViewModifier>: TerminalView {
    public let content: Content
    public let modifier: Modifier

    public var body: Never { fatalError() }
}

public protocol ViewModifier {
    associatedtype ModifierType
}

// Foreground color
public struct ForegroundModifier: ViewModifier {
    public typealias ModifierType = Color
    public let color: Color
}

// Background color
public struct BackgroundModifier: ViewModifier {
    public typealias ModifierType = Color
    public let color: Color
}

// Bold
public struct BoldModifier: ViewModifier {
    public typealias ModifierType = Bool
}

// Italic
public struct ItalicModifier: ViewModifier {
    public typealias ModifierType = Bool
}

// Underline
public struct UnderlineModifier: ViewModifier {
    public typealias ModifierType = Bool
}

// Padding
public struct PaddingModifier: ViewModifier {
    public typealias ModifierType = Int
    public let amount: Int
}

// Border
public struct BorderModifier: ViewModifier {
    public typealias ModifierType = BorderStyle
    public let style: BorderStyle
}

// Frame
//
// `width` / `height` stay as `Int?` since SwiftUI doesn't accept
// `.infinity` in those slots either ("fixed size or no constraint").
// `minWidth` / `maxWidth` / `minHeight` / `maxHeight` are
// `FrameDimension?` so callers can write `.frame(maxWidth: .infinity)`
// to opt into flex distribution along that axis. `FrameDimension`'s
// `ExpressibleByIntegerLiteral` conformance keeps existing
// `.frame(maxWidth: 40)` call sites working unchanged.
public struct FrameModifier: ViewModifier {
    public typealias ModifierType = (Int?, Int?)
    public let width: Int?
    public let height: Int?
    public var minWidth: FrameDimension?
    public var maxWidth: FrameDimension?
    public var minHeight: FrameDimension?
    public var maxHeight: FrameDimension?
    /// Where the content sits when the frame is bigger than it is. Without
    /// this a view smaller than its frame had no stated placement rule and
    /// simply drew from the top-left corner.
    public var alignment: Alignment = .topLeading
}

// Explicit identity
public struct IDModifier: ViewModifier {
    public typealias ModifierType = AnyHashable
    public let id: AnyHashable
}

// Chainable modifier methods on all TerminalViews
extension TerminalView {
    public func foreground(_ color: Color) -> ModifiedView<Self, ForegroundModifier> {
        ModifiedView(content: self, modifier: ForegroundModifier(color: color))
    }

    public func background(_ color: Color) -> ModifiedView<Self, BackgroundModifier> {
        ModifiedView(content: self, modifier: BackgroundModifier(color: color))
    }

    public func bold() -> ModifiedView<Self, BoldModifier> {
        ModifiedView(content: self, modifier: BoldModifier())
    }

    public func italic() -> ModifiedView<Self, ItalicModifier> {
        ModifiedView(content: self, modifier: ItalicModifier())
    }

    public func underline() -> ModifiedView<Self, UnderlineModifier> {
        ModifiedView(content: self, modifier: UnderlineModifier())
    }

    public func padding(_ amount: Int = 1) -> ModifiedView<Self, PaddingModifier> {
        ModifiedView(content: self, modifier: PaddingModifier(amount: amount))
    }

    public func border(_ style: BorderStyle = .rounded) -> ModifiedView<Self, BorderModifier> {
        ModifiedView(content: self, modifier: BorderModifier(style: style))
    }

    /// - Parameter alignment: where the content sits inside the frame when
    ///   the frame is the larger of the two. `.topLeading` by default, as
    ///   everywhere else in this framework — SwiftUI centres, and changing
    ///   that here would move every view already written against a frame.
    public func frame(width: Int? = nil, height: Int? = nil,
                      alignment: Alignment = .topLeading) -> ModifiedView<Self, FrameModifier> {
        ModifiedView(content: self, modifier: FrameModifier(
            width: width, height: height, alignment: alignment
        ))
    }

    public func frame(minWidth: FrameDimension? = nil, maxWidth: FrameDimension? = nil,
                      minHeight: FrameDimension? = nil, maxHeight: FrameDimension? = nil,
                      alignment: Alignment = .topLeading) -> ModifiedView<Self, FrameModifier> {
        ModifiedView(content: self, modifier: FrameModifier(
            width: nil, height: nil,
            minWidth: minWidth, maxWidth: maxWidth,
            minHeight: minHeight, maxHeight: maxHeight,
            alignment: alignment
        ))
    }

    public func id<ID: Hashable>(_ id: ID) -> ModifiedView<Self, IDModifier> {
        ModifiedView(content: self, modifier: IDModifier(id: AnyHashable(id)))
    }
}
