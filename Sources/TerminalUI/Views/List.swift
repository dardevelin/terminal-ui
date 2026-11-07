import Observation

/// A scrollable, selectable list of rows with keyboard and mouse navigation.
///
/// Renders one row per element with a `▸` cursor on the selected row, plus
/// gray `▲ N more` / `▼ N more` indicator lines when content extends past
/// the viewport. A row may be any number of lines tall — wrapped text, a
/// title over a detail — and is measured at the width the list is laid out
/// at. Rows are drawn whole while they fit; one taller than the whole list
/// is drawn from its top and cut off. Rendering is virtualized — only the
/// rows around the visible window are materialized, so a 100k-row list
/// costs the same as a 20-row one. Arrows, PageUp/PageDown (by the rows
/// drawn), Home/End move the selection; clicking any line of a row selects
/// it.
///
/// Sizing: with an explicit `visibleCount` the list takes at most that many
/// lines (the budget includes the indicator lines) and composes cheaply in
/// nested layouts. Without it, the list sizes to whatever height its
/// container gives it — which also makes it greedy in stack layout, the way
/// any size-reading view has to be.
///
/// Siblings: ``Table`` for column-aligned rows, selectable or not; ``TreeView``
/// when rows nest and expand/collapse; ``ForEach`` when you just need rows
/// with no scrolling or selection.
///
/// ```swift
/// // Bindings bridge to an @Observable model, as the example apps wire them:
/// List(state.processes,
///      selection: Binding(get: { state.selectedProcessID },
///                         set: { state.selectedProcessID = $0 }),
///      scroll: Binding(get: { state.processListScroll },
///                      set: { state.processListScroll = $0 }),
///      visibleCount: 25) { proc in
///     Text(proc.name).foreground(proc.cpu > 80 ? .red : .default)
/// }
/// ```
public struct List<Data: RandomAccessCollection, Content: TerminalView>: TerminalView
    where Data.Element: Identifiable
{
    /// The collection driving the rows.
    public let data: Data
    /// Two-way selected-element ID. `nil` disables selection entirely —
    /// the list still scrolls but draws no cursor.
    public let selection: Binding<Data.Element.ID?>?
    /// Two-way scroll offset (index of the first visible row). Pass a
    /// binding to persist scroll position across parent rebuilds or to
    /// drive it programmatically; `nil` lets the list manage it internally.
    public let scroll: Binding<Int>?
    /// Height budget in lines, the `▲`/`▼` indicator lines included.
    /// `nil` (default) fits to container height; set to pin the height
    /// cheaply for nested layouts.
    public let visibleCount: Int?
    /// Builds the row view for one element.
    public let content: (Data.Element) -> Content

    /// Creates a list over an `Identifiable` collection.
    ///
    /// - Parameters:
    ///   - data: Rows, identified by `Element.ID`.
    ///   - selection: Selected-element ID binding; `nil` for a display-only list.
    ///   - scroll: First-visible-row binding; `nil` for internal management.
    ///   - visibleCount: Total height budget in lines, including the
    ///     `▲`/`▼` indicator lines; `nil` fits to the container.
    ///   - content: Row builder, called only for the rows in and beside the
    ///     visible window.
    public init(
        _ data: Data,
        selection: Binding<Data.Element.ID?>? = nil,
        scroll: Binding<Int>? = nil,
        visibleCount: Int? = nil,
        @TerminalViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.selection = selection
        self.scroll = scroll
        self.visibleCount = visibleCount
        self.content = content
    }

    @TerminalEnvironment(\.theme) private var theme
    /// The offset a list given no `scroll` binding keeps for itself, so its
    /// window stays where it was between frames instead of being worked out
    /// from the top each time.
    @TerminalState private var ownScroll = 0
    /// The selected index the window last moved to show. The window follows
    /// the selection only when it changes, so the wheel can scroll the list
    /// without the next frame pulling it back to where the selection is.
    @TerminalState private var followedSelection: Int? = nil

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        // Projected here, in `body`: inside the window's closures they would
        // capture whichever node the layout pass happened to be building.
        let scroll = self.scroll ?? $ownScroll
        let followed = $followedSelection
        // An explicit `visibleCount` is a declared size: the list is that
        // many lines and measures as such. Only a size-driven list is told
        // its height — which also makes it greedy in stack layout, the way a
        // size-reading view has to be.
        //
        // Empty, it is still one Tab stop, as SwiftUI's is: a list whose
        // rows arrive later — read from disk, from git — is focused when its
        // screen opens, and focus is there when they come.
        if data.isEmpty {
            if visibleCount != nil {
                _EmptyPlaceholder().focusable()
            } else {
                GeometryReader { _ in _EmptyPlaceholder().focusable() }
            }
        } else {
            window(scroll: scroll, followed: followed, theme: theme)
        }
    }

    /// The list's rows, chosen in the layout pass by how tall each is at the
    /// width the list is laid out at.
    private func window(scroll: Binding<Int>, followed: Binding<Int?>, theme: any Theme) -> _ListWindow {
        // `data` is a RandomAccessCollection, so `.count` and offset
        // indexing are O(1); finding the selection walks only as far as it.
        let total = data.count
        let selectedID = selection?.get()
        let selectedIndex = selectedID.flatMap { id in data.firstIndex { $0.id == id } }
            .map { data.distance(from: data.startIndex, to: $0) } ?? 0
        return _ListWindow(
            declaredLines: visibleCount,
            rowCount: total,
            choose: { lines, height in
                // A selection that moved brings the window to it; one that
                // did not leaves the window wherever the wheel put it.
                RowWindowing.window(total: total, lines: lines, offset: scroll.get(),
                                    following: followed.get() != selectedIndex ? selectedIndex : nil,
                                    height: height)
            },
            draw: { window, rows in
                renderList(window, rows: rows, selectedID: selectedID, scroll: scroll, theme: theme)
            },
            settle: { window in
                // Written only when it moved: a write notifies its observers
                // whether or not the value changed, and an unconditional one
                // redrew an idle list every frame.
                let readOffset = scroll.get()
                let readFollowed = followed.get()
                let offsetMoved = readOffset != window.offset
                let followMoved = readFollowed != selectedIndex
                guard offsetMoved || followMoved else { return nil }
                return {
                    if offsetMoved, scroll.get() == readOffset { scroll.set(window.offset) }
                    if followMoved, followed.get() == readFollowed { followed.set(selectedIndex) }
                }
            })
    }

    private func element(at absoluteIndex: Int) -> Data.Element {
        data[data.index(data.startIndex, offsetBy: absoluteIndex)]
    }

    private func renderList(_ window: RowWindow, rows: [Int], selectedID: Data.Element.ID?,
                            scroll: Binding<Int>, theme: any Theme) -> any TerminalView {
        // Only the rows asked for are materialized — the window, and the
        // rows around it the graph measures — whatever the list's length.
        let items = rows.map { index in
            let element = element(at: index)
            return ListItem(index: index, element: element, isSelected: element.id == selectedID)
        }
        // The offset this window was drawn from. Until it is written back,
        // the binding still holds what it was worked out from, and the wheel
        // starts from where the rows are drawn instead.
        let drawnFrom = scroll.get()
        let wheel = WheelStart()

        return VStack {
            if window.showsUp {
                Text("  ▲ \(window.hiddenAbove) more")
                    .foreground(theme.foregroundMuted)
            }

            ForEach(items) { item in
                HStack {
                    Text(item.isSelected ? "▸ " : "  ")
                        .foreground(item.isSelected ? theme.accent : theme.foregroundMuted)
                    content(item.element)
                }
                .foreground(item.isSelected ? theme.foregroundEmphasis : theme.foreground)
                // Each row takes its own clicks, so a row is found by where
                // it is drawn rather than by counting lines from the top: a
                // row may be several lines tall.
                .onClick { [selection] _, _ in selection?.set(item.element.id) }
            }

            if window.showsDown {
                Text("  ▼ \(window.hiddenBelow) more")
                    .foreground(theme.foregroundMuted)
            }
        }
        .focusable()
        // The wheel scrolls the window and leaves the selection alone, as a
        // list under a trackpad does; the arrows move the selection.
        .onScrollWheel { key in
            let current = !wheel.moved && scroll.get() == drawnFrom ? window.offset : scroll.get()
            let next: Int
            switch key {
            case .up: next = max(0, current - 1)
            case .down: next = max(current, min(window.wheelLimit, current + 1))
            default: return false
            }
            guard next != current else { return false }
            wheel.moved = true
            scroll.set(next)
            return true
        }
        .onKeyPress { [selection, data] event in
            guard let sel = selection else { return .ignored }
            let total = data.count
            guard total > 0 else { return .ignored }

            // firstIndex(where:) walks until match — short-circuits on
            // first hit; bounded by total only when the selection is
            // at the end. No full materialization.
            let currentIdx = sel.get().flatMap { id in data.firstIndex { $0.id == id } }
                .map { data.distance(from: data.startIndex, to: $0) } ?? 0

            func element(at absoluteIndex: Int) -> Data.Element {
                data[data.index(data.startIndex, offsetBy: absoluteIndex)]
            }

            guard !event.isModifiedNavigation else { return .ignored }
            switch event.key {
            case .up:
                sel.set(element(at: max(0, currentIdx - 1)).id)
                return .handled

            case .down:
                sel.set(element(at: min(total - 1, currentIdx + 1)).id)
                return .handled

            // A page is the rows the window drew, however many lines each
            // took — a line count would skip rows taller than one unseen.
            case .pageUp:
                sel.set(element(at: max(0, currentIdx - max(1, window.shown))).id)
                return .handled

            case .pageDown:
                sel.set(element(at: min(total - 1, currentIdx + max(1, window.shown))).id)
                return .handled

            case .home:
                sel.set(data.first?.id)
                return .handled

            case .end:
                sel.set(data.last?.id)
                return .handled

            default:
                return .ignored
            }
        }
    }
}

/// Whether a wheel handler has moved its list since the window it belongs
/// to was drawn — after that, the binding holds where it put the list.
final class WheelStart {
    var moved = false
}

struct ListItem<Element: Identifiable>: Identifiable {
    let index: Int
    let element: Element
    let isSelected: Bool
    var id: Element.ID { element.id }
}
