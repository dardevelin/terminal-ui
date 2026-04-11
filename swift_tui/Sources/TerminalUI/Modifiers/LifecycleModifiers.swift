/// View modifier that calls a closure when a value changes.
public struct OnChangeModifier<Value: Equatable>: ViewModifier {
    public typealias ModifierType = Value
    public let value: Value
    public let action: (Value, Value) -> Void
}

/// View modifier that calls a closure when the view first appears.
public struct OnAppearModifier: ViewModifier {
    public typealias ModifierType = Bool
    public let action: () -> Void
    public var didAppear = false
}

/// View modifier that calls a closure when the view disappears.
public struct OnDisappearModifier: ViewModifier {
    public typealias ModifierType = Bool
    public let action: () -> Void
}

/// View modifier for per-view key handling.
public struct OnKeyPressModifier: ViewModifier {
    public typealias ModifierType = Key
    public let key: Key?  // nil = any key
    public let action: (KeyEvent) -> Void
}

extension TerminalView {
    public func onChange<V: Equatable>(of value: V, perform action: @escaping (V, V) -> Void) -> ModifiedView<Self, OnChangeModifier<V>> {
        ModifiedView(content: self, modifier: OnChangeModifier(value: value, action: action))
    }

    public func onAppear(perform action: @escaping () -> Void) -> ModifiedView<Self, OnAppearModifier> {
        ModifiedView(content: self, modifier: OnAppearModifier(action: action))
    }

    public func onDisappear(perform action: @escaping () -> Void) -> ModifiedView<Self, OnDisappearModifier> {
        ModifiedView(content: self, modifier: OnDisappearModifier(action: action))
    }

    public func onKeyPress(_ key: Key? = nil, perform action: @escaping (KeyEvent) -> Void) -> ModifiedView<Self, OnKeyPressModifier> {
        ModifiedView(content: self, modifier: OnKeyPressModifier(key: key, action: action))
    }
}
