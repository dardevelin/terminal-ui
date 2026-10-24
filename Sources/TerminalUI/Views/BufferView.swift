/// Renders an externally-populated ``CellBuffer`` into the view's
/// allocated rect. The view's natural size is the buffer's
/// dimensions; content larger than the rect is truncated to the rect
/// (no scrolling — compose with ``ScrollView`` if you need that).
///
/// SwiftUI analog: `Image(decorative: cgImage)` — the view is a
/// pass-through for a fully-formed raster, no interaction.
///
/// Use cases:
/// - PTY preview pane (terminal-in-terminal, vt100 emulator output)
/// - Pre-rasterized syntax-highlighted code blocks
/// - Image-to-cell renderers (kitty graphics fallback)
/// - Any content the app builds in its own `CellBuffer` and wants
///   to splice into the view tree
///
/// Unlike ``ScrollView``'s internal blit, BufferView paints `.empty`
/// source cells through to the destination — the user's buffer is
/// authoritative content, including blanks.
///
/// ```swift
/// var preview = CellBuffer(width: 80, height: 24)
/// // … populate preview from PTY bytes …
/// BufferView(preview)
///     .border(.single)
///     .frame(width: 80, height: 24)
/// ```
public struct BufferView: TerminalView {
    /// The cells to splice into the frame, blitted verbatim.
    public let buffer: CellBuffer

    /// Creates a view over a prerendered buffer.
    ///
    /// - Parameter buffer: A fully-formed cell grid; the view takes a
    ///   value copy, so later mutations require passing a new buffer.
    public init(_ buffer: CellBuffer) {
        self.buffer = buffer
    }

    @_documentation(visibility: internal)
    public var body: Never { fatalError() }
}
