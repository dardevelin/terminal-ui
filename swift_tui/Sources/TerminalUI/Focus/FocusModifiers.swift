/// Modifier that marks a view as focusable.
/// When focused, it renders with a focus ring and receives key events.
public struct FocusableModifier: ViewModifier {
    public typealias ModifierType = Bool
}

/// Modifier that groups focusable descendants into a named scope.
///
/// Arrow keys navigate within the scope — they won't move focus out of it.
/// Tab/Shift+Tab ignore scopes and traverse all focusables in document order,
/// which matches the SwiftUI convention (Tab = major sections, arrows = local).
public struct FocusScopeModifier: ViewModifier {
    public typealias ModifierType = String
    public let id: String
}

/// Modifier that attaches a key event handler to a view.
/// The handler is invoked when this view (or its focusable ancestor) is focused
/// and a key event is received.
public struct OnKeyPressModifier: ViewModifier {
    public typealias ModifierType = KeyEventResult
    public let handler: (KeyEvent) -> KeyEventResult
}

/// Modifier that attaches a click handler to a view.
/// Receives coordinates relative to the view's rect origin.
public struct OnClickModifier: ViewModifier {
    public typealias ModifierType = Void
    public let handler: (_ relativeX: Int, _ relativeY: Int) -> Void
}

// MARK: - View Extensions

extension TerminalView {
    /// Mark this view as focusable — it can receive focus via Tab/Shift+Tab
    /// and will show a focus ring when focused.
    public func focusable() -> ModifiedView<Self, FocusableModifier> {
        ModifiedView(content: self, modifier: FocusableModifier())
    }

    /// Attach a key event handler. When this view is focused (or its focusable
    /// ancestor is), key events are routed here first.
    public func onKeyPress(_ handler: @escaping (KeyEvent) -> KeyEventResult) -> ModifiedView<Self, OnKeyPressModifier> {
        ModifiedView(content: self, modifier: OnKeyPressModifier(handler: handler))
    }

    /// Attach a click handler. When this view is clicked, receives coordinates
    /// relative to the view's rect origin.
    public func onClick(_ handler: @escaping (_ relativeX: Int, _ relativeY: Int) -> Void) -> ModifiedView<Self, OnClickModifier> {
        ModifiedView(content: self, modifier: OnClickModifier(handler: handler))
    }

    /// Group focusable descendants into a named scope. Arrow-key
    /// navigation is clamped within the scope; Tab still crosses scopes.
    public func focusScope(_ id: String) -> ModifiedView<Self, FocusScopeModifier> {
        ModifiedView(content: self, modifier: FocusScopeModifier(id: id))
    }
}
