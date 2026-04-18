import Observation

/// A scrollable, selectable list with keyboard navigation.
/// Virtualizes rendering — only visible items are rendered.
/// The visibleCount is the total height budget including scroll indicators.
///
/// Usage:
/// ```
/// @TerminalState var selection: Int? = nil
/// @TerminalState var scroll: Int = 0
/// List(items, selection: $selection, scroll: $scroll, visibleCount: 20) { item in
///     Text(item.name)
/// }
/// ```
public struct List<Data: RandomAccessCollection, Content: TerminalView>: TerminalView
    where Data.Element: Identifiable
{
    public let data: Data
    public let selection: Binding<Data.Element.ID?>?
    public let scroll: Binding<Int>?
    /// Explicit visible-item cap. `nil` (default) fits to container height;
    /// set to pin the height cheaply for nested layouts.
    public let visibleCount: Int?
    public let content: (Data.Element) -> Content

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
        GeometryReader { size in
            if self.data.isEmpty {
                _EmptyPlaceholder()
            } else {
                self.renderList(visibleCount: self.visibleCount ?? max(1, size.height))
            }
        }
    }

    private func renderList(visibleCount: Int) -> some TerminalView {
        let elements = Array(data)
        let total = elements.count
        let selectedID = selection?.get()
        let selectedIndex = selectedID.flatMap { id in elements.firstIndex(where: { $0.id == id }) } ?? 0

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

        let slice = elements.dropFirst(scrollOffset).prefix(itemLines)

        return VStack {
            if hasUpIndicator {
                Text("  ▲ \(scrollOffset) more")
                    .foreground(.gray)
            }

            ForEach(Array(slice.enumerated().map { (offset, element) in
                ListItem(
                    index: scrollOffset + offset,
                    element: element,
                    isSelected: element.id == selectedID
                )
            })) { item in
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
            let elements = Array(data)
            let total = elements.count
            guard total > 0 else { return }
            let hasUpInd = (scroll?.get() ?? 0) > 0
            let rowOffset = hasUpInd ? relY - 1 : relY
            let itemIndex = (scroll?.get() ?? 0) + rowOffset
            if itemIndex >= 0 && itemIndex < total {
                sel.set(elements[itemIndex].id)
            }
        }
        .onKeyPress { [selection, visibleCount] event in
            guard let sel = selection else { return .ignored }
            let elements = Array(data)
            let total = elements.count
            guard total > 0 else { return .ignored }

            let currentIdx = sel.get().flatMap { id in
                elements.firstIndex(where: { $0.id == id })
            } ?? 0

            switch event.key {
            case .up:
                let newIdx = max(0, currentIdx - 1)
                sel.set(elements[newIdx].id)
                return .handled

            case .down:
                let newIdx = min(total - 1, currentIdx + 1)
                sel.set(elements[newIdx].id)
                return .handled

            case .pageUp:
                let newIdx = max(0, currentIdx - visibleCount)
                sel.set(elements[newIdx].id)
                return .handled

            case .pageDown:
                let newIdx = min(total - 1, currentIdx + visibleCount)
                sel.set(elements[newIdx].id)
                return .handled

            case .home:
                sel.set(elements.first?.id)
                return .handled

            case .end:
                sel.set(elements.last?.id)
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
