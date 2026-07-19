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
    case `default`
    case cancel
    case destructive
}

/// One button in an alert or confirmation dialog.
public struct AlertAction: Sendable {
    public let label: String
    public let role: ButtonRole
    public let action: @Sendable () -> Void

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
    public static func buildBlock(_ components: [AlertAction]...) -> [AlertAction] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ expression: AlertAction) -> [AlertAction] {
        [expression]
    }

    public static func buildExpression(_ expression: [AlertAction]) -> [AlertAction] {
        expression
    }

    public static func buildOptional(_ component: [AlertAction]?) -> [AlertAction] {
        component ?? []
    }

    public static func buildEither(first component: [AlertAction]) -> [AlertAction] {
        component
    }

    public static func buildEither(second component: [AlertAction]) -> [AlertAction] {
        component
    }

    public static func buildArray(_ components: [[AlertAction]]) -> [AlertAction] {
        components.flatMap { $0 }
    }
}
