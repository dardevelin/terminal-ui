// The body of an `.alert` / `.confirmationDialog`, rendered inside the
// existing `.modal` effect.
//
// Dismissal rides the action system rather than a bespoke registry of open
// dialogs. `ActionDispatch.scopeChain` walks focused-node→root innermost
// first and appends the framework defaults last; focus containment keeps the
// focused node inside the topmost presented modal. An Escape binding attached
// here therefore shadows the framework's `app.dismissOrQuit` exactly while
// this alert is up, and an alert presented over another nests correctly with
// no extra bookkeeping — the focus chain already is the dialog stack.
//
// Return needs no binding at all: `Button` consumes Return for the focused
// node, so placing initial focus on the `.default` action makes Return
// activate it as a consequence of focus, matching the platform convention.

/// How an alert arranges its actions.
enum AlertLayout: Sendable {
    /// Side by side — the alert shape.
    case row
    /// Stacked and bottom-anchored — the confirmation-dialog / action-sheet
    /// shape, per SwiftUI's `confirmationDialog`.
    case stack
}

/// Dimensions of the dialog chrome. Terminal cells, not points: the alert is
/// sized in whole characters and centred by the modal effect.
private enum Metrics {
    /// Interior breathing room between the border and the content. One cell
    /// on each side reads as a dialog rather than a bare box, and keeps the
    /// title clear of the border glyphs.
    static let contentPadding = 1
    /// Blank cells between adjacent actions in `.row` layout, so two buttons
    /// do not visually merge into one wide control.
    static let actionGap = 2
}

/// Label used when an alert declares no actions. The alert still needs one
/// focusable way out; leaving the box empty would strand the user.
private let fallbackActionLabel = "OK"

struct AlertPresentation: TerminalView {
    let title: String
    let message: String?
    let actions: [AlertAction]
    let layout: AlertLayout
    let isPresented: Binding<Bool>

    @TerminalEnvironment(\.theme) private var theme

    /// Everything the body needs about the actions, resolved in one pass.
    ///
    /// `ordered` is never empty and is rotated so the action that should take
    /// focus comes first — focus adoption picks the first focusable inside a
    /// newly presented modal, so tree order is what selects the default
    /// button. `cancel` is what Escape fires; nil when the caller declared no
    /// `.cancel`, in which case Escape still dismisses with no side effect.
    private var plan: (ordered: [AlertAction], cancel: AlertAction?) {
        let base = actions.isEmpty
            ? [AlertAction(fallbackActionLabel, role: .cancel)]
            : actions

        // `.default` takes focus; failing that the first non-destructive
        // action. A destructive action is focused only when it is the sole
        // candidate, which the zero-action fallback prevents in practice.
        let focusIndex = base.firstIndex { $0.role == .default }
            ?? base.firstIndex { $0.role != .destructive }
            ?? 0

        var ordered = base
        if focusIndex != 0 {
            ordered = [base[focusIndex]] + base.enumerated()
                .filter { $0.offset != focusIndex }
                .map(\.element)
        }
        return (ordered, base.first { $0.role == .cancel })
    }

    /// Emit programmer-error diagnostics. Runtime warnings rather than
    /// compile-time constraints: both mistakes are legal Swift that only
    /// misbehaves once presented, and encoding them in the type system would
    /// contort the call site the parity work exists to keep familiar.
    private func validate() {
        #if DEBUG
        if actions.isEmpty {
            DebugStream.shared.emitWarning(
                .alertHasNoActions,
                message: "Alert \"\(title)\" declares no actions; rendering a \"\(fallbackActionLabel)\" button so it can be dismissed."
            )
        }
        let defaults = actions.filter { $0.role == .default }
        if defaults.count > 1 {
            DebugStream.shared.emitWarning(
                .alertMultipleDefaultActions,
                message: "Alert \"\(title)\" declares \(defaults.count) .default actions (\(defaults.map(\.label).joined(separator: ", "))); Return activates only the focused one. Give the others .cancel or .destructive."
            )
        }
        #endif
    }

    private func color(for role: ButtonRole) -> Color {
        switch role {
        case .destructive: return theme.error
        case .cancel, .default: return .default
        }
    }

    var body: some TerminalView {
        validate()
        // `Action.perform` is @Sendable but `Binding` holds plain closures, so
        // the dismissal is routed through a Sendable box. Dispatch only fires
        // actions from the main actor's input handling, which is what
        // `assumeIsolated` inside the box asserts.
        let dismiss = AlertDismissal(binding: isPresented, cancel: plan.cancel?.action)

        return VStack {
            Text(title).bold()
            if let message {
                Text(message).foreground(theme.muted)
            }
            actionsView
        }
        .padding(Metrics.contentPadding)
        .border(theme.border)
        .actions {
            Action(
                id: "alert.dismiss",
                title: .literal("Dismiss"),
                description: .literal("Close the dialog")
            ) {
                dismiss.cancelAndClose()
            }
            .bound(to: .keyboard(.escape, []))
        }
    }

    @TerminalViewBuilder
    private var actionsView: some TerminalView {
        let ordered = plan.ordered
        switch layout {
        case .row:
            HStack {
                ForEachWithID(Array(ordered.enumerated()), id: \.offset) { pair in
                    button(for: pair.element)
                    if pair.offset < ordered.count - 1 {
                        Text(String(repeating: " ", count: Metrics.actionGap))
                    }
                }
            }
        case .stack:
            VStack {
                ForEachWithID(Array(ordered.enumerated()), id: \.offset) { pair in
                    button(for: pair.element)
                }
            }
        }
    }

    private func button(for action: AlertAction) -> some TerminalView {
        let run = action.action
        let binding = isPresented
        return Button(action.label) {
            run()
            binding.wrappedValue = false
        }
        .foreground(color(for: action.role))
    }
}

/// Carries a dialog's dismissal across the `@Sendable` boundary that
/// `Action.perform` imposes.
///
/// `Binding` stores plain (non-Sendable) closures, so it cannot be captured
/// directly. Actions are only ever fired from the main actor while handling
/// input, which is the invariant `assumeIsolated` states — matching the
/// trampoline pattern the example apps already use for the same boundary.
private final class AlertDismissal: @unchecked Sendable {
    private let binding: Binding<Bool>
    private let cancel: (@Sendable () -> Void)?

    init(binding: Binding<Bool>, cancel: (@Sendable () -> Void)?) {
        self.binding = binding
        self.cancel = cancel
    }

    /// Escape: run the `.cancel` action if one was declared, then close.
    func cancelAndClose() {
        MainActor.assumeIsolated {
            cancel?()
            binding.wrappedValue = false
        }
    }

}
