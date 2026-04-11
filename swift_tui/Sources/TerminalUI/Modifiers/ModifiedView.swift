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
}
