/// Flexible empty space that fills the parent stack's free axis.
///
/// Inside an `HStack`, a `Spacer` consumes remaining horizontal space.
/// Inside a `VStack`, a `Spacer` consumes remaining vertical space.
/// Siblings split slack equally when multiple spacers are present.
///
/// ```swift
/// HStack {
///     Text("left")
///     Spacer()
///     Text("right")
/// }
/// ```
public struct Spacer: TerminalView {
    public init() {}
    public var body: Never { fatalError() }
}
