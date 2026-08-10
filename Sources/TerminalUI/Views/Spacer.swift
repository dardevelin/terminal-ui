/// Flexible empty space that fills the parent stack's free axis.
///
/// Inside an `HStack`, a `Spacer` consumes remaining horizontal space.
/// Inside a `VStack`, a `Spacer` consumes remaining vertical space.
/// Siblings split slack equally when multiple spacers are present.
///
/// A `Spacer` claims cells but paints nothing — whatever is beneath the
/// stack shows through. It is the elastic counterpart to the stacks'
/// `spacing:` parameter: `spacing` is a fixed gap between every pair of
/// children, a `Spacer` is a targeted push that absorbs however many
/// cells are left over. One `Spacer` right-aligns what follows it;
/// bracketing a child with two centers it; a trailing `Spacer` in a
/// ``VStack`` pins content to the top of a taller container.
///
/// ```swift
/// HStack {
///     Text("left")
///     Spacer()
///     Text("right")
/// }
/// ```
public struct Spacer: TerminalView {
    /// Creates a spacer; the axis it stretches on comes from the enclosing
    /// stack.
    public init() {}
    public var body: Never { fatalError() }
}
