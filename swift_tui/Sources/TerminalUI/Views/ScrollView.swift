/// A view that scrolls its content along a single axis.
///
/// Measures inner content at unlimited size in the scroll axis, then clips
/// to the available viewport. Scroll offset auto-adjusts to keep the
/// keyboard-focused child visible (scroll-to-focused).
///
/// Usage:
/// ```swift
/// ScrollView(.horizontal) {
///     HStack {
///         ForEach(items) { item in
///             Text(item.name)
///         }
///     }
/// }
/// ```
public struct ScrollView<Content: TerminalView>: TerminalView {
    public let axes: ScrollAxis
    public let content: Content

    public init(_ axes: ScrollAxis = .vertical, @TerminalViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    public var body: Never { fatalError() }
}

/// Scroll direction — horizontal or vertical.
/// Separate from layout axis to avoid name collision with TerminalUI.Axis if one exists.
public enum ScrollAxis: Sendable, Equatable {
    case horizontal
    case vertical
}
