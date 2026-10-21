import TerminalUI

// Dispatch ImageBuffer renders to the right
// ImageRenderer based on detected capabilities + strategy. The
// pipeline holds a registry of renderers keyed by GraphicsProtocol;
// renderers added later (Kitty) plug in alongside
// the half-block one shipped here.
//
// Strategy resolution descends the ladder from kitty (highest)
// down to halfBlock (universal floor) to asciiArt to placeholder.
// When the resolved protocol has no registered renderer, the
// ladder falls through to the next tier — graceful degradation
// even in unconfigured pipelines.

public final class ImageRenderingPipeline: Sendable {
    private let renderers: [GraphicsProtocol: any ImageRenderer]

    public init(renderers: [any ImageRenderer]) {
        var dict: [GraphicsProtocol: any ImageRenderer] = [:]
        for r in renderers {
            dict[r.supportedProtocol] = r
        }
        self.renderers = dict
    }

    /// Render `image` into `buffer` using the best renderer for
    /// the resolved protocol. `capabilities` defaults to the
    /// framework-level singleton; callers override for testing or
    /// per-pipeline customisation.
    @MainActor
    public func render(
        _ image: ImageBuffer,
        in rect: Rect,
        into buffer: inout CellBuffer,
        strategy: ImageRenderStrategy = .automatic,
        capabilities: TerminalCapabilities = Runtime.capabilities
    ) {
        // Resolve target protocol from strategy + capabilities,
        // then walk the ladder until a registered renderer is
        // found OR placeholder.
        let resolved = resolveProtocol(strategy: strategy, capabilities: capabilities)

        if case .placeholder(let text) = strategy {
            renderPlaceholder(text, in: rect, into: &buffer)
            return
        }

        // Strict strategies (.kittyOnly, .halfBlock, .asciiArt)
        // require an exact match — no fall-through. Falls to a
        // generic placeholder if the requested tier isn't
        // registered.
        if isStrict(strategy) {
            if let renderer = renderers[resolved] {
                renderer.render(image, in: rect, into: &buffer)
            } else {
                renderPlaceholder("[image]", in: rect, into: &buffer)
            }
            return
        }

        // .automatic: walk the ladder from the resolved protocol
        // down. Graceful degradation — if kitty isn't registered
        // but halfBlock is, halfBlock wins.
        for tier in ladder(from: resolved) {
            if let renderer = renderers[tier] {
                renderer.render(image, in: rect, into: &buffer)
                return
            }
        }
        renderPlaceholder("[image]", in: rect, into: &buffer)
    }

    /// Strict strategies require an exact-tier match; non-strict
    /// (.automatic) walks the ladder. The user's mental model:
    /// "I asked for kittyOnly; if you can't give me kitty, fall
    /// to placeholder, NOT to half-block."
    private func isStrict(_ strategy: ImageRenderStrategy) -> Bool {
        switch strategy {
        case .kittyOnly, .halfBlock, .asciiArt:
            return true
        case .automatic, .placeholder:
            return false
        }
    }

    // MARK: - Ladder

    /// Strategy → starting tier. `.automatic` defers to
    /// capabilities; the explicit cases pin a tier.
    @MainActor
    private func resolveProtocol(
        strategy: ImageRenderStrategy,
        capabilities: TerminalCapabilities
    ) -> GraphicsProtocol {
        switch strategy {
        case .automatic:
            return capabilities.graphics
        case .kittyOnly:
            return .kitty
        case .halfBlock:
            return .halfBlock
        case .asciiArt:
            return .asciiArt
        case .placeholder:
            // Handled by the placeholder branch in render(...);
            // the resolved protocol is unused.
            return .halfBlock
        }
    }

    /// Order from highest-fidelity to lowest. The ladder pipeline
    /// walks until it finds a registered renderer.
    private func ladder(from start: GraphicsProtocol) -> [GraphicsProtocol] {
        let order: [GraphicsProtocol] = [.kitty, .iterm2, .sixel, .halfBlock, .asciiArt]
        guard let startIndex = order.firstIndex(of: start) else { return order }
        return Array(order[startIndex...])
    }

    // MARK: - Placeholder

    /// Write `text` left-aligned into the rect's first row.
    /// Used when no renderer is registered for the resolved
    /// protocol or when strategy is `.placeholder(_)`.
    private func renderPlaceholder(_ text: String, in rect: Rect, into buffer: inout CellBuffer) {
        guard rect.width > 0, rect.height > 0 else { return }
        let chars = Array(text)
        let writableWidth = min(chars.count, rect.width)
        for index in 0..<writableWidth {
            let style = Style(foreground: .gray, background: nil, bold: false, italic: false, underline: false)
            buffer[rect.x + index, rect.y] = Cell(character: chars[index], style: style)
        }
    }
}
