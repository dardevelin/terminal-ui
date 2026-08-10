/// A button that triggers an action on Enter/Space when focused.
///
/// Renders as `[ label ]` and joins the Tab order through the framework's
/// `.focusable` machinery: Tab (or a click) focuses it, and Enter, Space, or
/// a click on the focused button fires `action`. Highlights when
/// keyboard-focused, shows underline on mouse hover. A `.disabled()`
/// ancestor paints the label gray and takes the button out of the Tab
/// order. Reach for ``Toggle`` when the press should flip persistent on/off
/// state, or ``NavigationLink`` when it should push a screen — a `Button`
/// is a one-shot action.
///
/// Usage:
/// ```swift
/// Button("Submit") {
///     handleSubmit()
/// }
/// ```
///
/// Two buttons side by side, writing into an `@Observable` model the way
/// the Storybook does:
/// ```swift
/// VStack {
///     Button("OK") { model.message = "OK clicked" }
///     Button("Cancel") { model.message = "Cancel clicked" }
///     Text("→ \(model.message)").foreground(.gray)
/// }
/// ```
public struct Button: TerminalView {
    /// The text drawn inside the `[ ]` chrome.
    public let label: String
    /// Runs on Enter, Space, or a click while the button is focused.
    public let action: () -> Void

    /// Read at body-eval time. When false (a `.disabled()` ancestor
    /// has run), the label paints in `.gray` so users see the button
    /// is non-interactive. Pairs with the behavioral half of
    /// `.disabled()` (handler gating + focus skip).
    @TerminalEnvironment(\.isEnabled) var isEnabled

    /// Creates a button.
    ///
    /// - Parameters:
    ///   - label: Text drawn inside the `[ ]` chrome.
    ///   - action: Called when the focused button is activated.
    public init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some TerminalView {
        Text("[ \(label) ]")
            .foreground(isEnabled ? .default : .gray)
            .focusable()
            .onKeyPress { event in
                // `.activate` is synthesized by FocusEngine when the
                // user clicks a focused Button (no .onClick handler);
                // treat it identically to Enter / Space so click-to-
                // fire keeps working without misinterpreting clicks
                // on text-input siblings as newline keypresses.
                if event.key == .enter
                    || event.key == .character(" ")
                    || event.key == .activate
                {
                    action()
                    return .handled
                }
                return .ignored
            }
    }
}
