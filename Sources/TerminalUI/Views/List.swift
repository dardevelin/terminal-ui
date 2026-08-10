import Observation

/// A scrollable, selectable list of rows with keyboard and mouse navigation.
///
/// Renders one row per element with a `▸` cursor on the selected row, plus
/// gray `▲ N more` / `▼ N more` indicator lines when content extends past
/// the viewport. Rendering is virtualized — only the visible window is
/// materialized, so a 100k-row list costs the same as a 20-row one. Arrows,
/// PageUp/PageDown, Home/End move the selection; clicking a row selects it.
///
/// Sizing: with an explicit `visibleCount` the list measures exactly that
/// many rows (the budget includes the indicator lines) and composes cheaply
/// in nested layouts. Without it, the list sizes to whatever height its
/// container gives it — which also makes it greedy in stack layout, the way
/// any size-reading view has to be.
///
/// Siblings: ``Table`` for column-aligned, non-interactive data; ``TreeView``
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
    /// Explicit visible-item cap. `nil` (default) fits to container height;
    /// set to pin the height cheaply for nested layouts.
    public let visibleCount: Int?
    /// Builds the row view for one element.
    public let content: (Data.Element) -> Content

    /// Creates a list over an `Identifiable` collection.
    ///
    /// - Parameters:
    ///   - data: Rows, identified by `Element.ID`.
    ///   - selection: Selected-element ID binding; `nil` for a display-only list.
    ///   - scroll: First-visible-row binding; `nil` for internal management.
    ///   - visibleCount: Total height budget in rows, including the
    ///     `▲`/`▼` indicator lines; `nil` fits to the container.
    ///   - content: Row builder, called only for visible elements.
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

    public var body: some TerminalView {
        // An explicit `visibleCount` is a declared size: the list is exactly
        // that many rows and measures as such. Only a size-driven list needs
        // the GeometryReader — which also makes it greedy in stack layout,
        // the way a size-reading view has to be.
        if let declaredCount = visibleCount {
            if data.isEmpty {
                _EmptyPlaceholder()
            } else {
                renderList(visibleCount: declaredCount)
            }
        } else {
            GeometryReader { size in
                if self.data.isEmpty {
                    _EmptyPlaceholder()
                } else {
                    self.renderList(visibleCount: max(1, size.height))
                }
            }
        }
    }

    private func renderList(visibleCount: Int) -> some TerminalView {
        // Materialize ONLY the visible window. `data` is a
        // RandomAccessCollection, so .count and integer-offset indexing
        // are O(1); we never need to walk every element. The selected-
        // index lookup uses firstIndex(where:) on the lazy view, which
        // short-circuits on first match.
        let total = data.count
        let selectedID = selection?.get()
        let selectedIndex: Int = {
            guard let id = selectedID else { return 0 }
            // Walk from start; stops at first match. Bounded by total
            // only when the selected element is at the end.
            for (i, element) in data.enumerated() where element.id == id {
                return i
            }
            return 0
        }()

        // Get stored scroll offset or compute from scratch
        var scrollOffset = scroll?.get() ?? 0

        // Adjust scroll offset only if selection is outside visible window
        let adjusted = adjustScrollOffset(scrollOffset: scrollOffset, selectedIndex: selectedIndex, total: total, visibleCount: visibleCount)
        scrollOffset = adjusted

        // Write back adjusted offset
        scroll?.set(scrollOffset)

        // How many lines are used by scroll indicators (within the budget)
        let hasUpIndicator = scrollOffset > 0
        let hasDownIndicator = (scrollOffset + visibleCount) < total
        let indicatorLines = (hasUpIndicator ? 1 : 0) + (hasDownIndicator ? 1 : 0)
        let itemLines = max(1, visibleCount - indicatorLines)

        // Materialize only the visible window. RandomAccessCollection's
        // O(1) integer-offset index makes this constant-time per item;
        // the loop walks only `windowSize` elements regardless of total.
        let windowSize = min(itemLines, max(0, total - scrollOffset))
        let visibleItems: [(Int, Data.Element)] = (0..<windowSize).map { offset in
            let absoluteIndex = scrollOffset + offset
            let idx = data.index(data.startIndex, offsetBy: absoluteIndex)
            return (absoluteIndex, data[idx])
        }

        return VStack {
            if hasUpIndicator {
                Text("  ▲ \(scrollOffset) more")
                    .foreground(.gray)
            }

            ForEach(visibleItems.map { (absoluteIndex, element) in
                ListItem(
                    index: absoluteIndex,
                    element: element,
                    isSelected: element.id == selectedID
                )
            }) { item in
                HStack {
                    Text(item.isSelected ? "▸ " : "  ")
                        .foreground(item.isSelected ? .cyan : .gray)
                    content(item.element)
                }
                .foreground(item.isSelected ? .white : .default)
            }

            if hasDownIndicator {
                let remaining = total - scrollOffset - itemLines
                Text("  ▼ \(remaining) more")
                    .foreground(.gray)
            }
        }
        .focusable()
        .onClick { [selection] _, relY in
            guard let sel = selection else { return }
            let total = data.count
            guard total > 0 else { return }
            let hasUpInd = (scroll?.get() ?? 0) > 0
            let rowOffset = hasUpInd ? relY - 1 : relY
            let itemIndex = (scroll?.get() ?? 0) + rowOffset
            if itemIndex >= 0 && itemIndex < total {
                let idx = data.index(data.startIndex, offsetBy: itemIndex)
                sel.set(data[idx].id)
            }
        }
        .onKeyPress { [selection, visibleCount] event in
            guard let sel = selection else { return .ignored }
            let total = data.count
            guard total > 0 else { return .ignored }

            // firstIndex(where:) walks until match — short-circuits on
            // first hit; bounded by total only when the selection is
            // at the end. No full materialization.
            let currentIdx: Int = {
                guard let id = sel.get() else { return 0 }
                for (i, element) in data.enumerated() where element.id == id {
                    return i
                }
                return 0
            }()

            // Helper: O(1) element access at a given absolute index.
            func element(at absoluteIndex: Int) -> Data.Element {
                data[data.index(data.startIndex, offsetBy: absoluteIndex)]
            }

            switch event.key {
            case .up:
                let newIdx = max(0, currentIdx - 1)
                sel.set(element(at: newIdx).id)
                return .handled

            case .down:
                let newIdx = min(total - 1, currentIdx + 1)
                sel.set(element(at: newIdx).id)
                return .handled

            case .pageUp:
                let newIdx = max(0, currentIdx - visibleCount)
                sel.set(element(at: newIdx).id)
                return .handled

            case .pageDown:
                let newIdx = min(total - 1, currentIdx + visibleCount)
                sel.set(element(at: newIdx).id)
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

    /// Adjust scroll offset so the selected item is visible.
    /// Only moves the window when selection goes outside it — does not jump.
    func adjustScrollOffset(scrollOffset: Int, selectedIndex: Int, total: Int, visibleCount: Int) -> Int {
        guard total > visibleCount else { return 0 }

        var offset = scrollOffset

        // Compute visible item range for current offset
        let hasUp = offset > 0
        let hasDown = (offset + visibleCount) < total
        let topIndicator = hasUp ? 1 : 0
        let bottomIndicator = hasDown ? 1 : 0
        let itemLines = visibleCount - topIndicator - bottomIndicator

        let firstVisible = offset
        let lastVisible = offset + itemLines - 1

        // Selection below viewport — scroll down
        if selectedIndex > lastVisible {
            // Put selection at the bottom of the visible items
            // Account for indicators: we'll have ▲ (scrolled) and maybe ▼
            let needsDown = (selectedIndex < total - 1)
            let downRes = needsDown ? 1 : 0
            let upRes = 1  // we're scrolled, so always ▲
            let items = visibleCount - upRes - downRes
            offset = selectedIndex - items + 1
        }

        // Selection above viewport — scroll up
        if selectedIndex < firstVisible {
            // Put selection at the top of the visible items
            if selectedIndex == 0 {
                offset = 0  // No ▲ indicator needed
            } else {
                offset = selectedIndex  // ▲ will show, selection is first item
            }
        }

        // Clamp
        let maxOffset = total - (visibleCount - 1)  // at least 1 indicator or items
        offset = max(0, min(maxOffset, offset))
        return offset
    }
}

struct ListItem<Element: Identifiable>: Identifiable {
    let index: Int
    let element: Element
    let isSelected: Bool
    var id: Element.ID { element.id }
}
