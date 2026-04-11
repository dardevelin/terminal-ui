/// Overlay modifier — renders content on top of the base view's frame.
public struct OverlayModifier<Overlay: TerminalView>: ViewModifier {
    public typealias ModifierType = Overlay
    public let overlay: Overlay
}

/// Background modifier — renders content behind the base view's frame.
public struct BackgroundViewModifier<Background: TerminalView>: ViewModifier {
    public typealias ModifierType = Background
    public let background: Background
}

/// Modal modifier — floating panel over entire screen.
/// Dims the background and centers content.
public struct ModalModifier<ModalContent: TerminalView>: ViewModifier {
    public typealias ModifierType = Bool
    public let isPresented: Bool
    public let content: ModalContent
}

extension TerminalView {
    /// Render additional content on top of this view's frame.
    public func overlay<V: TerminalView>(@TerminalViewBuilder content: () -> V) -> ModifiedView<Self, OverlayModifier<V>> {
        ModifiedView(content: self, modifier: OverlayModifier(overlay: content()))
    }

    /// Render additional content behind this view's frame.
    public func backgroundView<V: TerminalView>(@TerminalViewBuilder content: () -> V) -> ModifiedView<Self, BackgroundViewModifier<V>> {
        ModifiedView(content: self, modifier: BackgroundViewModifier(background: content()))
    }

    /// Present a floating modal over the entire screen when isPresented is true.
    public func modal<V: TerminalView>(isPresented: Bool, @TerminalViewBuilder content: () -> V) -> ModifiedView<Self, ModalModifier<V>> {
        ModifiedView(content: self, modifier: ModalModifier(isPresented: isPresented, content: content()))
    }
}
