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
public struct FrameModifier: ViewModifier {
    public typealias ModifierType = (Int?, Int?)
    public let width: Int?
    public let height: Int?
    public var minWidth: Int?
    public var maxWidth: Int?
    public var minHeight: Int?
    public var maxHeight: Int?
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

    public func frame(width: Int? = nil, height: Int? = nil) -> ModifiedView<Self, FrameModifier> {
        ModifiedView(content: self, modifier: FrameModifier(width: width, height: height))
    }

    public func frame(minWidth: Int? = nil, maxWidth: Int? = nil, minHeight: Int? = nil, maxHeight: Int? = nil) -> ModifiedView<Self, FrameModifier> {
        ModifiedView(content: self, modifier: FrameModifier(
            width: nil, height: nil,
            minWidth: minWidth, maxWidth: maxWidth,
            minHeight: minHeight, maxHeight: maxHeight
        ))
    }

    public func id<ID: Hashable>(_ id: ID) -> ModifiedView<Self, IDModifier> {
        ModifiedView(content: self, modifier: IDModifier(id: AnyHashable(id)))
    }
}
