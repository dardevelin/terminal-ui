/// Environment values propagated down the view tree.
/// Views read values with @TerminalEnvironment, parents set them with .environment().
///
/// Usage:
/// ```
/// struct MyView: TerminalView {
///     @TerminalEnvironment(\.theme) var theme
///     var body: some TerminalView {
///         Text("hello").foreground(theme.accent)
///     }
/// }
///
/// // Set from parent:
/// MyView().environment(\.theme, CustomTheme())
/// ```

/// Storage for all environment values — passed down during rendering.
public struct EnvironmentValues: @unchecked Sendable {
    public var theme: any Theme = DefaultTheme()
    public var terminalSize: TerminalSize = TerminalSize(cols: 80, rows: 24)
    public var colorSupport: ColorSupport = .trueColor
    public var isFocused: Bool = false
    public var focusedID: AnyHashable? = nil

    public init() {}
}

/// Property wrapper to read environment values.
@propertyWrapper
public struct TerminalEnvironment<Value> {
    private let keyPath: KeyPath<EnvironmentValues, Value>

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        self.keyPath = keyPath
    }

    public var wrappedValue: Value {
        let env = GraphContext.currentEnvironment ?? EnvironmentValues()
        return env[keyPath: keyPath]
    }
}

/// Modifier that sets an environment value for a subtree.
public struct EnvironmentModifier<Value>: ViewModifier {
    public typealias ModifierType = Value
    public let keyPath: WritableKeyPath<EnvironmentValues, Value>
    public let value: Value
}

extension TerminalView {
    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> ModifiedView<Self, EnvironmentModifier<V>> {
        ModifiedView(content: self, modifier: EnvironmentModifier(keyPath: keyPath, value: value))
    }
}
