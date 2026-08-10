// Alert vocabulary — the semantic layer over the raw `.modal` effect.
//
// SwiftUI collects alert buttons with a `ViewBuilder` and reads their roles
// through private introspection. There is no equivalent hook here, and the
// alert genuinely needs to inspect its actions before rendering: to choose
// which one takes initial focus, to find the cancel action Escape fires, and
// to count `.default`s for the duplicate warning. A view is opaque to all
// three. `AlertAction` is therefore a plain inspectable value, collected by a
// result builder so the call site still reads like SwiftUI's.

/// The semantic weight of an alert action, mirroring SwiftUI's `ButtonRole`.
///
/// Role drives three behaviours, not just colour: `.default` is activated by
/// Return and takes initial focus, `.cancel` is what Escape fires, and
/// `.destructive` renders in the theme's error colour and is never focused
/// first (Apple HIG, Alerts: keep the destructive button away from the one
/// people are most likely to press by reflex).
public enum ButtonRole: Sendable, Equatable {
    /// The affirmative action — takes initial focus, fired by Return.
    case `default`
    /// The dismissing action — fired by Escape.
    case cancel
    /// An irreversible action — error-colored, never focused first.
    case destructive
}

/// One button in an alert or confirmation dialog.
public struct AlertAction: Sendable {
    /// The button's visible text.
    public let label: String
    /// Semantic weight driving focus, Return/Escape mapping, and color.
    public let role: ButtonRole
    /// Runs when the button is activated, after the alert dismisses.
    public let action: @Sendable () -> Void

    /// Creates an alert button; the default role and empty action make a
    /// bare `AlertAction("OK")` a complete dismiss button.
    public init(
        _ label: String,
        role: ButtonRole = .default,
        action: @Sendable @escaping () -> Void = {}
    ) {
        self.label = label
        self.role = role
        self.action = action
    }
}

/// Collects `AlertAction`s so an alert's actions read like a SwiftUI
/// `ViewBuilder` body — including `if` / `if-else` / `for` forms.
@resultBuilder
public enum AlertActionBuilder {
    /// Concatenates the block's per-expression action lists in source
    /// order.
    public static func buildBlock(_ components: [AlertAction]...) -> [AlertAction] {
        components.flatMap { $0 }
    }

    /// Accepts a single ``AlertAction`` expression.
    public static func buildExpression(_ expression: AlertAction) -> [AlertAction] {
        [expression]
    }

    /// Accepts a prebuilt action array (e.g. from a helper function).
    public static func buildExpression(_ expression: [AlertAction]) -> [AlertAction] {
        expression
    }

    /// `if` without `else`: `nil` contributes no action.
    public static func buildOptional(_ component: [AlertAction]?) -> [AlertAction] {
        component ?? []
    }

    /// The `if` branch of an `if`/`else`.
    public static func buildEither(first component: [AlertAction]) -> [AlertAction] {
        component
    }

    /// The `else` branch of an `if`/`else`.
    public static func buildEither(second component: [AlertAction]) -> [AlertAction] {
        component
    }

    /// Flattens `for` loop iterations into one action list.
    public static func buildArray(_ components: [[AlertAction]]) -> [AlertAction] {
        components.flatMap { $0 }
    }
}
