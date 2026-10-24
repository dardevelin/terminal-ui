/// A view that opens a menu where it is clicked with the secondary button;
/// see `TerminalView.contextMenu(menuItems:)`.
struct ContextMenuHost<Content: TerminalView, MenuItems: TerminalView>: TerminalView {
    let content: Content
    let menuItems: MenuItems

    /// The cell the menu opened from; nil while it is closed.
    @TerminalState private var anchor: Point? = nil

    var body: some TerminalView {
        let anchor = $anchor
        // A value until it is presented: its body, and the theme it reads,
        // run only while the menu is open.
        let menu = ContextMenuPanel(items: menuItems, close: { anchor.wrappedValue = nil })
        return ModifiedView(
            content: content.onSecondaryClick { press in
                anchor.wrappedValue = Point(x: press.x, y: press.y)
            },
            modifier: ModalModifier(
                isPresented: anchor.wrappedValue != nil, content: menu,
                placement: .anchored(anchor.wrappedValue ?? Point(x: 0, y: 0)),
                dismissal: { anchor.wrappedValue = nil }))
    }
}

/// An open context menu: its items in a bordered column, closed by Escape.
struct ContextMenuPanel<MenuItems: TerminalView>: TerminalView {
    let items: MenuItems
    let close: () -> Void

    @TerminalEnvironment(\.theme) private var theme

    var body: some TerminalView {
        let close = close
        return VStack(spacing: 0) { items }
            .padding(.horizontal, 1)
            .border(.rounded, color: theme.borderActive)
            .background(theme.background)
            .onKeyPress { event in
                guard event.key == .escape else { return .ignored }
                close()
                return .handled
            }
    }
}

extension TerminalView {
    /// Open a menu of `menuItems` where this view is clicked with the
    /// secondary button — SwiftUI's `contextMenu(menuItems:)`.
    ///
    /// ```swift
    /// Text(file.path)
    ///     .contextMenu {
    ///         Button("Open") { open(file) }
    ///         Button("Ask about it") { ask(about: file) }
    ///     }
    /// ```
    ///
    /// The menu opens at the cell clicked, moved in as far as it must to
    /// stay on the screen, and holds the keyboard while it is open: focus
    /// moves to its first item, and the arrows and Tab move between them.
    /// Choosing an item — Enter, Space or a click — runs it and closes the
    /// menu; Escape, or a press anywhere outside it, closes it alone.
    public func contextMenu<MenuItems: TerminalView>(
        @TerminalViewBuilder menuItems: () -> MenuItems
    ) -> some TerminalView {
        ContextMenuHost(content: self, menuItems: menuItems())
    }
}
