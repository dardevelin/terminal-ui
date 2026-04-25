/// Type-erasure for `OnChangeModifier<Value>` so the graph's modifier
/// dispatch can pattern-match without naming the value type. The graph
/// stores the last seen value as `Any`; this protocol lets the modifier
/// compare current-vs-stored and decide whether to fire.
public protocol _OnChangeModifierProtocol {
    /// If the previously stored value differs from the current value, fire
    /// the action and return the new value to store. If they match, return
    /// `current` unchanged. `previous == nil` means "never observed before"
    /// — by SwiftUI convention, that does NOT fire the action; only changes
    /// after the initial render do.
    func compareAndFire(previous: Any?) -> Any
}

/// View modifier that calls a closure when a value changes.
public struct OnChangeModifier<Value: Equatable>: ViewModifier, _OnChangeModifierProtocol {
    public typealias ModifierType = Value
    public let value: Value
    public let action: (Value, Value) -> Void

    public func compareAndFire(previous: Any?) -> Any {
        guard let prev = previous as? Value else {
            // First observation — record the value but do not fire. Mirrors
            // SwiftUI's `onChange(of:)` semantics: only mutations from this
            // initial value trigger the action.
            return value
        }
        if prev != value {
            action(prev, value)
        }
        return value
    }
}

/// View modifier that calls a closure when the view first appears.
public struct OnAppearModifier: ViewModifier {
    public typealias ModifierType = Bool
    public let action: () -> Void
}

/// View modifier that calls a closure when the view disappears.
public struct OnDisappearModifier: ViewModifier {
    public typealias ModifierType = Bool
    public let action: () -> Void
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
}
