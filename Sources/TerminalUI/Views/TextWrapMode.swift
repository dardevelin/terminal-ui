/// How `Text` handles logical lines that exceed the container's width.
///
/// Default `.wrap` matches typical text-flow expectations: a long line
/// continues on the next row, consuming additional vertical cells. Measurement
/// counts wrapped rows so the parent layout reserves enough height.
///
/// `.none` disables wrap entirely: logical lines render on a single row each
/// and are clipped to the container width (via rect enforcement). The
/// measurement side reports only the newline-separated row count. Intended
/// for structurally sized content — dot-matrix glyphs, Morse code, ASCII art,
/// pre-formatted tables — where a measurer that inflates height from wrap
/// rounding would starve siblings downstream of a VStack Spacer.
///
/// Set via `.wrap(.none)` on any view; the setting propagates to descendants
/// through the environment.
/// `.truncate` keeps one row per logical line like `.none`, but marks the
/// elision with `…` instead of cutting silently. Dense chrome — a sidebar of
/// file paths, a status row's trailing detail, a header's metadata — wants
/// this: wrapping would push the layout around as content changes, and
/// clipping leaves the reader unable to tell a full value from a cut one.
public enum TextWrapMode: Sendable, Equatable {
    /// Overflowing lines continue on the next row; measurement counts the
    /// extra rows. The default.
    case wrap
    /// One row per logical line, clipped at the container width — for
    /// fixed-geometry content whose height must not inflate.
    case none
    /// One row per logical line, shortened to fit with an `…` at `edge`.
    case truncate(TextTruncationEdge)
}

/// Which part of an over-long line gives way to the ellipsis.
///
/// Pick by what the reader needs to keep: `.tail` preserves the beginning
/// (labels, sentences), `.head` the end (file paths, where the basename
/// identifies the item), `.middle` both ends (identifiers with a meaningful
/// prefix *and* suffix).
public enum TextTruncationEdge: Sendable, Equatable, CaseIterable {
    /// Drop the start, keep the end: `…/Rendering/Compositor.swift`.
    case head
    /// Drop the centre, keep both ends: `Sources/…/Compositor.swift`.
    case middle
    /// Drop the end, keep the start: `Sources/TerminalUI/Rende…`.
    case tail

    /// The equivalent single-line ``LineBreakMode``, so string truncation
    /// runs through the one display-width-aware implementation rather than
    /// a second copy of the same cell arithmetic.
    var lineBreakMode: LineBreakMode {
        switch self {
        case .head: .byTruncatingHead
        case .middle: .byTruncatingMiddle
        case .tail: .byTruncatingTail
        }
    }
}

extension TerminalView {
    /// Control how enclosed `Text` handles overflow past its container width.
    /// Default is `.wrap`. Use `.none` for fixed-geometry content like dot
    /// matrices or ASCII art where row inflation would break parent layout,
    /// and `.truncate(_:)` for single-row chrome that should show it was cut.
    ///
    /// ```swift
    /// Text(path).wrap(.truncate(.head))   // …/Rendering/Compositor.swift
    /// ```
    public func wrap(_ mode: TextWrapMode)
        -> ModifiedView<Self, EnvironmentModifier<TextWrapMode>> {
        environment(\.textWrap, mode)
    }
}
