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

    /// Present an alert over this view while `isPresented` is true.
    ///
    /// ```swift
    /// .alert("Delete file?", isPresented: $showAlert, message: "This cannot be undone.") {
    ///     AlertAction("Delete", role: .destructive) { delete() }
    ///     AlertAction("Cancel", role: .cancel) { }
    /// }
    /// ```
    ///
    /// Escape always dismisses, firing the `.cancel` action when one is
    /// declared. Return activates the focused action, which starts on the
    /// `.default` one. Any action dismisses the alert after running.
    ///
    /// The binding is written by the framework on dismissal, so callers do
    /// not have to clear it inside every action closure.
    public func alert(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        @AlertActionBuilder actions: () -> [AlertAction]
    ) -> some TerminalView {
        present(title, isPresented: isPresented, message: message,
                layout: .row, actions: actions())
    }

    /// Present a confirmation dialog over this view while `isPresented` is
    /// true. Identical to `alert(_:isPresented:message:actions:)` except that
    /// the actions stack vertically, matching SwiftUI's action-sheet shape.
    public func confirmationDialog(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        @AlertActionBuilder actions: () -> [AlertAction]
    ) -> some TerminalView {
        present(title, isPresented: isPresented, message: message,
                layout: .stack, actions: actions())
    }

    private func present(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String?,
        layout: AlertLayout,
        actions: [AlertAction]
    ) -> some TerminalView {
        modal(isPresented: isPresented.wrappedValue) {
            AlertPresentation(
                title: title,
                message: message,
                actions: actions,
                layout: layout,
                isPresented: isPresented
            )
        }
    }
}
