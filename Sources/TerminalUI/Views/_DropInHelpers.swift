/// Shared helpers for the drop-in component sprint.
///
/// Used by List, TreeView, Table, TextArea, PromptInput and other core views
/// to share three cross-cutting concerns:
///
/// 1. Container-sized defaults — components store `Int?` for `visibleCount`,
///    `visibleHeight`, `width`, etc. When `nil`, read the container dimension
///    from the graph's proposed size (GeometryReader convention).
/// 2. Row padding — space-fill a rendered row string to a target width so
///    shrunk content overwrites any stale cells left by the previous frame
///    (the "shrunk-content bleed" failure mode).
/// 3. Empty-state placeholder — one shared visual for `Component([]).body`
///    so every core collection-like view has the same fallback.

// MARK: - Container-sized defaults

/// Resolve an optional axis budget against the proposed container dimension.
///
/// Core components expose `visibleCount: Int?` / `visibleHeight: Int?` / `width: Int?`
/// and call this helper during `body` to pick the actual value. The caller's
/// explicit value always wins; `nil` falls back to the container axis; both
/// missing falls back to a reasonable default so the component is still usable
/// outside a sized container.
///
/// The `fallback` argument exists because some components (Sparkline, HeatMap)
/// want a non-zero default even when no container info is available — e.g. a
/// Sparkline in a `Text` row should render at some width rather than zero.
@inlinable
func resolveAxis(_ requested: Int?, container: Int?, fallback: Int) -> Int {
    if let requested { return max(1, requested) }
    if let container, container > 0 { return container }
    return fallback
}

// MARK: - Row padding

/// Pad a rendered row's display text to `width` columns with trailing spaces.
///
/// Delta compositing only writes cells that differ from the previous frame;
/// when a row's new content is shorter than its previous content, cells to
/// the right of the new content keep the old glyphs ("stale bleed"). Padding
/// every row to the container width means the shrunk tail is explicitly
/// rewritten as spaces, clearing the old cells.
///
/// Callers that track display width separately (e.g. because of ANSI styling
/// or double-width glyphs) should pass the already-computed `displayWidth`
/// instead of relying on `text.count`.
@inlinable
func padToWidth(_ text: String, width: Int, displayWidth: Int? = nil) -> String {
    guard width > 0 else { return text }
    let used = displayWidth ?? text.count
    let need = width - used
    if need <= 0 { return text }
    return text + String(repeating: " ", count: need)
}

// MARK: - Empty placeholder

/// Shared empty-state view for core collection components.
///
/// Consumed by `List([])`, `Table(rows: [])`, and other views that render zero
/// items by default. Uniform look means users don't need to wire their own
/// "nothing here" branch for the common case. Components can still swap it
/// for a custom view — this is the default fallback only.
public struct _EmptyPlaceholder: TerminalView {
    public let text: String

    public init(_ text: String = "— empty —") {
        self.text = text
    }

    public var body: some TerminalView {
        Text(text).foreground(.gray)
    }
}
