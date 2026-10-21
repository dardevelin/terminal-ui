import TerminalUI

// Image renderer protocol + strategy enum. Concrete
// renderers (HalfBlockRenderer here, a Kitty-protocol renderer
// later) plug into ImageRenderingPipeline and dispatch by
// detected GraphicsProtocol.

/// Renders an `ImageBuffer` into a destination `CellBuffer` rect.
/// One implementation per `GraphicsProtocol`.
public protocol ImageRenderer: Sendable {
    var supportedProtocol: GraphicsProtocol { get }
    func render(_ image: ImageBuffer, in rect: Rect, into buffer: inout CellBuffer)
}

/// Strategy for picking which renderer to use. `.automatic`
/// descends the ladder by detected capability; the others force a
/// specific tier or fall to placeholder text.
public enum ImageRenderStrategy: Sendable, Equatable {
    /// Descend ladder: kitty → iterm2 → sixel → halfBlock → asciiArt → placeholder.
    case automatic
    /// Use kitty if available; otherwise placeholder.
    case kittyOnly
    /// Force half-block regardless of capability.
    case halfBlock
    /// Force ASCII-art regardless of capability.
    case asciiArt
    /// Render the supplied text as fallback (used in CI logs / non-TTY targets).
    case placeholder(String)
}
