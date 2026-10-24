/// Overlay modifier — renders content on top of the base view's frame.
public struct OverlayModifier<Overlay: TerminalView>: ViewModifier {
    @_documentation(visibility: internal)
    public typealias ModifierType = Overlay
    /// The view drawn over the base view's cells.
    public let overlay: Overlay
    /// Where the overlay sits inside the base view's frame. The corner cases
    /// are the reason this exists: badges, close buttons, corner indicators.
    public var alignment: Alignment = .topLeading
}

/// Background modifier — renders content behind the base view's frame.
public struct BackgroundViewModifier<Background: TerminalView>: ViewModifier {
    /// Where the background sits inside the base view's frame.
    public var alignment: Alignment = .topLeading
    @_documentation(visibility: internal)
    public typealias ModifierType = Background
    /// The view drawn behind the base view's cells.
    public let background: Background
}

/// Modal modifier — floating panel over entire screen.
/// Dims the background and centers content.
public struct ModalModifier<ModalContent: TerminalView>: ViewModifier {
    @_documentation(visibility: internal)
    public typealias ModifierType = Bool
    /// Whether the modal is shown this frame; `false` renders the base
    /// view alone.
    public let isPresented: Bool
    /// The panel content, centered over the dimmed screen while presented.
    public let content: ModalContent
    /// Centred for `.modal`, along the trailing edge for `.inspector`.
    var placement = PresentationPlacement.centered
}

extension TerminalView {
    /// Render additional content on top of this view's frame.
    public func overlay<V: TerminalView>(
        alignment: Alignment = .topLeading,
        @TerminalViewBuilder content: () -> V
    ) -> ModifiedView<Self, OverlayModifier<V>> {
        ModifiedView(content: self, modifier: OverlayModifier(overlay: content(), alignment: alignment))
    }

    /// Render additional content behind this view's frame.
    public func backgroundView<V: TerminalView>(
        alignment: Alignment = .topLeading,
        @TerminalViewBuilder content: () -> V
    ) -> ModifiedView<Self, BackgroundViewModifier<V>> {
        ModifiedView(content: self, modifier: BackgroundViewModifier(alignment: alignment, background: content()))
    }

    /// Present a floating modal over the entire screen when isPresented is true.
    public func modal<V: TerminalView>(isPresented: Bool, @TerminalViewBuilder content: () -> V) -> ModifiedView<Self, ModalModifier<V>> {
        ModifiedView(content: self, modifier: ModalModifier(isPresented: isPresented, content: content()))
    }

    /// Present a panel along this view's trailing edge while `isPresented`
    /// is true, this view's full height and as wide as `content`, beside
    /// what it presents over rather than over a dimmed screen — a review, a
    /// detail, a set of properties to edit. Declare it on the part of the
    /// screen it should cover: on the whole app it covers every row; on the
    /// area above a footer, the footer stays in view. Give the content a
    /// width with `.frame(width:)`.
    ///
    /// Unlike SwiftUI's inspector it holds the keyboard while it is up, as
    /// a dialog does: focus moves into it, Tab stays inside, a click beside
    /// it does not reach what it covers, and focus goes back where it was
    /// when it closes. Nothing closes it but the binding; bind Escape in its
    /// content to set it false.
    ///
    /// SwiftUI parity: `View.inspector(isPresented:content:)`.
    public func inspector<V: TerminalView>(
        isPresented: Binding<Bool>,
        @TerminalViewBuilder content: () -> V
    ) -> ModifiedView<Self, ModalModifier<V>> {
        ModifiedView(content: self, modifier: ModalModifier(
            isPresented: isPresented.wrappedValue, content: content(), placement: .trailing))
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
