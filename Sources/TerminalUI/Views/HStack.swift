/// Stacks its children horizontally, left to right.
///
/// Children are laid out in declaration order. `Spacer` children expand
/// to fill remaining horizontal space; siblings split slack equally.
///
/// ```swift
/// HStack {
///     Text("left")
///     Spacer()
///     Text("right")
/// }
/// ```
public struct HStack<Content: TerminalView>: TerminalView {
    public let content: Content
    public let alignment: VerticalAlignment
    public let spacing: Int

    /// - Parameters:
    ///   - alignment: where shorter children sit down the stack. Defaults to
    ///     `.top` rather than SwiftUI's `.center`, for the reason `VStack`
    ///     documents: existing layouts were written against top alignment.
    ///   - spacing: blank cells between children, none by default.
    ///   - content: the children, left to right.
    public init(
        alignment: VerticalAlignment = .top,
        spacing: Int = 0,
        @TerminalViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.alignment = alignment
        self.spacing = max(0, spacing)
    }

    public var body: Never { fatalError() }
}
