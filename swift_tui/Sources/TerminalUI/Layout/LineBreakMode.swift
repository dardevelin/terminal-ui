// Line-break behaviour for text-input components.
//
// Per Apple HIG `apple-hig/components/text-fields.md` §"Adjust line
// breaks according to field needs":
//
//   "Default behavior: System clips text extending beyond field
//    bounds. Alternatives: Wrap text to new line at character or
//    word level; truncate with ellipsis at beginning, middle, or
//    end."
//
// `LineBreakMode` is the SwiftUI-style enum that exposes those
// alternatives as a public knob. Apply via `.lineBreakMode(_:)` on
// any view — the value lands in `EnvironmentValues.lineBreakMode`
// and propagates to descendants. Today consumed by `TextInput` (the
// HIG "text field" component); future consumers (TextArea, Text) can
// opt in by reading `@TerminalEnvironment(\.lineBreakMode)`.

public enum LineBreakMode: Sendable, Equatable, CaseIterable {
    /// Clip text at the right edge of the field. Default — matches
    /// HIG's "System clips text extending beyond field bounds."
    case byClipping
    /// Soft-wrap at character boundaries. Word-unaware; faster than
    /// `.byWordWrapping` but produces mid-word splits.
    case byCharWrapping
    /// Soft-wrap at whitespace boundaries via `TextLayout.wrapWords`.
    /// Words longer than the wrap width hard-break at character level
    /// so they remain visible.
    case byWordWrapping
    /// Truncate with ellipsis (`…`) at the head — leading characters
    /// dropped, ellipsis prepended, tail preserved.
    case byTruncatingHead
    /// Truncate with ellipsis in the middle — head and tail
    /// preserved.
    case byTruncatingMiddle
    /// Truncate with ellipsis at the tail — head preserved, ellipsis
    /// appended.
    case byTruncatingTail

    /// Apply a single-line truncation/clip mode to `s`, fitting into
    /// `width` cells. For wrap modes (`.byCharWrapping`,
    /// `.byWordWrapping`) returns the FIRST chunk only — call
    /// `wrap(_:width:)` to get all chunks.
    ///
    /// Strings already fitting within `width` are returned unchanged
    /// regardless of mode.
    public func apply(to s: String, width: Int) -> String {
        guard width > 0 else { return s }
        if s.count <= width { return s }
        switch self {
        case .byClipping:
            return String(s.prefix(width))
        case .byCharWrapping, .byWordWrapping:
            return wrap(s, width: width).first ?? ""
        case .byTruncatingHead:
            // Ellipsis(1) + tail(width-1) — preserves the END of the
            // string, useful for paths like "…/long/path/file".
            let tail = s.suffix(max(0, width - 1))
            return "…" + tail
        case .byTruncatingMiddle:
            // Symmetric split around an ellipsis. With odd `width-1`,
            // the head gets the extra character.
            let room = width - 1
            let headLen = (room + 1) / 2
            let tailLen = room - headLen
            let head = s.prefix(headLen)
            let tail = s.suffix(tailLen)
            return String(head) + "…" + String(tail)
        case .byTruncatingTail:
            // Head(width-1) + ellipsis(1).
            let head = s.prefix(max(0, width - 1))
            return String(head) + "…"
        }
    }

    /// Multi-row wrap. Defined for the wrap modes; for non-wrap
    /// modes returns `[apply(to: s, width: width)]` so callers can
    /// uniformly produce a row list.
    public func wrap(_ s: String, width: Int) -> [String] {
        guard width > 0 else { return [s] }
        switch self {
        case .byClipping, .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail:
            return [apply(to: s, width: width)]
        case .byCharWrapping:
            return TextLayout.charStrideChunks(s, width: width)
        case .byWordWrapping:
            return TextLayout.wrapWords(s, width: width)
        }
    }
}

extension TerminalView {
    /// Set the line-break mode for descendant text-input views.
    /// Default is `.byClipping` (HIG default for text fields).
    /// Wraps `.environment(\.lineBreakMode, mode)` for ergonomics.
    public func lineBreakMode(_ mode: LineBreakMode) -> some TerminalView {
        environment(\.lineBreakMode, mode)
    }
}
