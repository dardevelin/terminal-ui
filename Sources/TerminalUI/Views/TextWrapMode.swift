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
public enum TextWrapMode: Sendable, Equatable {
    /// Overflowing lines continue on the next row; measurement counts the
    /// extra rows. The default.
    case wrap
    /// One row per logical line, clipped at the container width — for
    /// fixed-geometry content whose height must not inflate.
    case none
}

extension TerminalView {
    /// Control how enclosed `Text` handles overflow past its container width.
    /// Default is `.wrap`. Use `.none` for fixed-geometry content like dot
    /// matrices or ASCII art where row inflation would break parent layout.
    public func wrap(_ mode: TextWrapMode)
        -> ModifiedView<Self, EnvironmentModifier<TextWrapMode>> {
        environment(\.textWrap, mode)
    }
}
