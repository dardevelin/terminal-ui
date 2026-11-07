/// The window of a ``List`` or ``TreeView``: which rows are drawn, chosen by
/// their heights in the pass that knows the width.
///
/// A row's height depends on its width — text wraps — and only layout knows
/// the width, so the window cannot be chosen in `body`. The view hands the
/// graph its rows instead; the graph builds and measures them where the
/// width is known (`AttributeGraph.buildRowWindow`) and asks this for the
/// window over those heights.
///
/// Type-erased so the graph needs no element type: the closures capture the
/// list's data and bindings.
struct _ListWindow: TerminalView, _GraphRowWindow {
    /// The `visibleCount` the list was given, or nil when its container's
    /// height decides.
    let declaredLines: Int?
    let rowCount: Int
    /// The window for this frame's state, over rows `height` measures.
    let choose: (_ lines: Int, _ height: (Int) -> Int) -> RowWindow
    /// The list drawn for a window: `VStack { ▲?; ForEach(rows); ▼? }`.
    let draw: (_ window: RowWindow, _ rows: [Int]) -> any TerminalView
    /// Where the rows the window held are among this frame's rows — see
    /// `RowWindowing.rows(holding:heldAt:total:key:mayHold:)`.
    let relocate: (_ keys: [AnyHashable], _ earlier: [Int]) -> [Int]
    /// What drawing a window changes in the list's state, if anything.
    let settle: (_ window: RowWindow) -> (() -> Void)?

    func window(lines: Int, height: (Int) -> Int) -> RowWindow {
        choose(lines, height)
    }

    func content(for window: RowWindow, rows: [Int]) -> any TerminalView {
        draw(window, rows)
    }

    func rows(holding keys: [AnyHashable], heldAt earlier: [Int]) -> [Int] {
        relocate(keys, earlier)
    }

    func commit(for window: RowWindow) -> (() -> Void)? {
        settle(window)
    }

    var body: Never { fatalError("_ListWindow is built by the graph's layout pass; body is never called") }
}
