/// Customizable colors and marker glyphs for ``TreeView`` appearance.
///
/// Every knob has a sensible default, so most trees pass no style at all.
/// A colour the style leaves unset is a ``Theme`` role, read where the tree
/// is drawn; one it states wins over the theme. Reading an unset colour
/// gives the stock theme's, which is what the property held before it
/// followed the theme. Mutate a copy to rebrand the markers or highlight
/// colors:
///
/// ```swift
/// var style = TreeViewStyle()
/// style.selectedBackground = .ansi256(238)
/// style.connectorColor = .blue
/// TreeView(roots, children: \.children, style: style) { node in
///     Text(node.name)
/// }
/// ```
public struct TreeViewStyle: Sendable {
    /// Color of expand/collapse arrow on unselected rows; unset, the
    /// theme's ``Theme/foregroundMuted``.
    public var arrowColor: Color {
        get { arrowColor(in: DefaultTheme()) }
        set { statedArrowColor = newValue }
    }
    /// Color of expand/collapse arrow on the selected row; unset, the
    /// theme's ``Theme/accent``.
    public var selectedArrowColor: Color {
        get { selectedArrowColor(in: DefaultTheme()) }
        set { statedSelectedArrowColor = newValue }
    }
    /// Color of tree connector lines (├── └── │); unset, the theme's
    /// ``Theme/separator``.
    public var connectorColor: Color {
        get { connectorColor(in: DefaultTheme()) }
        set { statedConnectorColor = newValue }
    }
    /// Foreground color for the selected row's text; unset, the theme's
    /// ``Theme/foregroundEmphasis``.
    public var selectedForeground: Color {
        get { selectedForeground(in: DefaultTheme()) }
        set { statedSelectedForeground = newValue }
    }
    /// Background color for the selected row (nil = no background highlight)
    public var selectedBackground: Color? = nil
    /// Character for expanded node indicator
    public var expandedArrow: Character = "\u{25BE}"   // ▾
    /// Character for collapsed node indicator
    public var collapsedArrow: Character = "\u{25B8}"  // ▸
    /// Prefix shown before the selected row
    public var selectionPrefix: String = "\u{25B8} "   // "▸ "
    /// Prefix shown before unselected rows (for alignment)
    public var unselectedPrefix: String = "  "

    /// The stock style — every colour the theme's, `▾`/`▸` markers, no
    /// selected-row background.
    public static let `default` = TreeViewStyle()

    /// Creates the default style; mutate the copy's properties to
    /// customize individual knobs.
    public init() {}

    // The colours a caller stated. A `Color` with a literal default could not
    // tell "the stock colour" from "the theme's"; the properties stay `Color`
    // so code that reads them compiles, and become `Color?` in a major
    // release, as `MarkdownStyle`'s are.
    private var statedArrowColor: Color?
    private var statedSelectedArrowColor: Color?
    private var statedConnectorColor: Color?
    private var statedSelectedForeground: Color?

    func arrowColor(in theme: any Theme) -> Color { statedArrowColor ?? theme.foregroundMuted }
    func selectedArrowColor(in theme: any Theme) -> Color { statedSelectedArrowColor ?? theme.accent }
    func connectorColor(in theme: any Theme) -> Color { statedConnectorColor ?? theme.separator }
    func selectedForeground(in theme: any Theme) -> Color { statedSelectedForeground ?? theme.foregroundEmphasis }
}

/// A hierarchical tree with expandable nodes, box-drawing connectors, and
/// keyboard/mouse navigation.
///
/// Draws each row with `├──`/`└──` branch connectors, `│` continuation
/// lines for open ancestor levels, and a `▾`/`▸` disclosure arrow on nodes
/// that have children. Arrows move the cursor (right expands, left
/// collapses or jumps to the parent), Enter/Space toggles, clicking a row
/// selects and toggles it. Root items start expanded; collapsed branches
/// contribute no rows and their children are never computed.
///
/// Works with any element that exposes optional children of the same
/// collection type via a key path — `nil` children marks a leaf. Expansion
/// state lives inside the view; the optional `selection` binding surfaces
/// the current row's ID to the app.
///
/// Sizing follows ``List``: an explicit `visibleCount` pins the height to
/// exactly that many rows (indicator lines included); `nil` fits to the
/// container, which makes the tree greedy in stack layout. Reach for
/// ``List`` when data is flat, ``Table`` when it's flat *and* columnar.
///
/// ```swift
/// // A file browser pane, as the GitClient example wires it:
/// TreeView(
///     rows,
///     children: \.children,
///     selection: Binding(get: { state.selectedPath },
///                        set: { state.selectedPath = $0 })
/// ) { row in
///     Text(row.label)
/// }
/// ```
public struct TreeView<Data: RandomAccessCollection, Content: TerminalView>: TerminalView
    where Data.Element: Identifiable, Data.Element.ID: Sendable
{
    /// Root items of the tree.
    public let data: Data
    /// Key path to an element's children; `nil` children marks a leaf.
    public let childrenKeyPath: KeyPath<Data.Element, Data?>
    /// Two-way selected-node ID. The tree also tracks its own row cursor;
    /// this binding mirrors it outward so the app can react to selection.
    public let selection: Binding<Data.Element.ID?>?
    /// Cap on visible rows. `nil` (default) fits to container height.
    public let visibleCount: Int?
    /// Colors and marker glyphs; see ``TreeViewStyle``.
    public let style: TreeViewStyle
    /// Builds the row view for one node (connectors and arrows are drawn
    /// by the tree; this is just the label).
    public let content: (Data.Element) -> Content

    @TerminalState var expandedIDs: Set<AnyHashableID> = []
    @TerminalState var selectedIndex: Int = 0
    @TerminalState var scrollOffset: Int = 0
    @TerminalState var initialized: Bool = false
    /// The selected row the window last moved to show. The window follows
    /// the selection only when it changes, so the wheel can scroll the tree
    /// without the next frame pulling it back.
    @TerminalState var followedIndex: Int? = nil
    @TerminalEnvironment(\.theme) private var theme

    /// Creates a tree over hierarchical data.
    ///
    /// - Parameters:
    ///   - data: Root items.
    ///   - children: Key path to an element's children (`nil` = leaf).
    ///   - selection: Selected-node ID binding; `nil` keeps selection internal.
    ///   - visibleCount: Height budget in rows including `▲`/`▼` indicator
    ///     lines; `nil` fits to the container.
    ///   - style: Colors and marker glyphs (default `TreeViewStyle.default`).
    ///   - content: Row label builder, called only for visible nodes.
    public init(
        _ data: Data,
        children: KeyPath<Data.Element, Data?>,
        selection: Binding<Data.Element.ID?>? = nil,
        visibleCount: Int? = nil,
        style: TreeViewStyle = .default,
        @TerminalViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.childrenKeyPath = children
        self.selection = selection
        self.visibleCount = visibleCount
        self.style = style
        self.content = content
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        // Capture bindings here — `body` is evaluated with this view's
        // node set as `GraphContext.currentNode`, so `$expandedIDs` etc.
        // resolve to slots on the TreeView's own node. If we projected
        // them inside the `GeometryReader { … }` closure (which runs at
        // GR-rebuild time with a different `currentNode`), the slots
        // would be created on whatever node happened to be current
        // during the rebuild and state would not persist across frames.
        let expandedBinding = $expandedIDs
        let selectedIdxBinding = $selectedIndex
        let scrollBinding = $scrollOffset
        let initBinding = $initialized
        let followedBinding = $followedIndex
        let theme = theme
        // An explicit `visibleCount` is a declared size — no GeometryReader,
        // so the tree measures fixed instead of greedily filling its stack.
        if let declaredCount = visibleCount {
            renderTree(
                visibleCount: declaredCount,
                theme: theme,
                expandedBinding: expandedBinding,
                selectedIdxBinding: selectedIdxBinding,
                scrollBinding: scrollBinding,
                initBinding: initBinding,
                followedBinding: followedBinding
            )
        } else {
            GeometryReader { size in
                self.renderTree(
                    visibleCount: max(1, size.height),
                    theme: theme,
                    expandedBinding: expandedBinding,
                    selectedIdxBinding: selectedIdxBinding,
                    scrollBinding: scrollBinding,
                    initBinding: initBinding,
                    followedBinding: followedBinding
                )
            }
        }
    }

    private func renderTree(
        visibleCount: Int,
        theme: any Theme,
        expandedBinding: Binding<Set<AnyHashableID>>,
        selectedIdxBinding: Binding<Int>,
        scrollBinding: Binding<Int>,
        initBinding: Binding<Bool>,
        followedBinding: Binding<Int?>
    ) -> some TerminalView {
        // Auto-expand root items on first render
        let _ = {
            if !initBinding.get() {
                initBinding.set(true)
                var initial = expandedBinding.get()
                for item in data {
                    initial.insert(AnyHashableID(item.id))
                }
                expandedBinding.set(initial)
            }
        }()

        // Flatten visible tree
        let expanded = expandedBinding.get()
        let rows = TreeViewHelpers.flattenedRows(data: data, childrenKeyPath: childrenKeyPath, expandedIDs: expanded)
        let total = rows.count
        // The offset that shows the last row at the bottom: the farthest the
        // wheel may take the window.
        let maxOffset = TreeViewHelpers.adjustScroll(scrollOffset: 0, selectedIndex: max(0, total - 1),
                                                     total: total, visibleCount: visibleCount)

        // Sync selectedIndex bounds and scroll (side effects, not views)
        let currentIndex = min(max(selectedIdxBinding.get(), 0), max(total - 1, 0))
        let adjustedOffset: Int = {
            if currentIndex != selectedIdxBinding.get() {
                selectedIdxBinding.set(currentIndex)
            }
            if let sel = selection, total > 0 {
                sel.set(rows[currentIndex].item.id)
            }
            var offset = min(max(0, scrollBinding.get()), maxOffset)
            if followedBinding.get() != currentIndex {
                offset = TreeViewHelpers.adjustScroll(
                    scrollOffset: offset,
                    selectedIndex: currentIndex,
                    total: total,
                    visibleCount: visibleCount
                )
                followedBinding.set(currentIndex)
            }
            if offset != scrollBinding.get() {
                scrollBinding.set(offset)
            }
            return offset
        }()

        // Compute visible slice
        let hasUpIndicator = adjustedOffset > 0
        let hasDownIndicator = (adjustedOffset + visibleCount) < total
        let indicatorLines = (hasUpIndicator ? 1 : 0) + (hasDownIndicator ? 1 : 0)
        let itemLines = max(1, visibleCount - indicatorLines)
        let slice = rows.dropFirst(adjustedOffset).prefix(itemLines)

        return VStack {
            if hasUpIndicator {
                Text("  \u{25B2} \(adjustedOffset) more")
                    .foreground(theme.foregroundMuted)
            }

            ForEach(Array(slice)) { row in
                treeRow(row, isSelected: row.flatIndex == currentIndex, expandedIDs: expanded, theme: theme)
            }

            if hasDownIndicator {
                let remaining = total - adjustedOffset - itemLines
                Text("  \u{25BC} \(remaining) more")
                    .foreground(theme.foregroundMuted)
            }
        }
        .frame(minHeight: FrameDimension(visibleCount))
        .focusable()
        // The wheel scrolls the window and leaves the selection alone.
        .onScrollWheel { key in
            let current = scrollBinding.get()
            let next: Int
            switch key {
            case .up: next = max(0, current - 1)
            case .down: next = min(maxOffset, current + 1)
            default: return false
            }
            guard next != current else { return false }
            scrollBinding.set(next)
            return true
        }
        .onClick { [selection, expandedBinding, selectedIdxBinding, scrollBinding] _, relY in
            let expanded = expandedBinding.get()
            let rows = TreeViewHelpers.flattenedRows(data: data, childrenKeyPath: childrenKeyPath, expandedIDs: expanded)
            let total = rows.count
            guard total > 0 else { return }
            let offset = scrollBinding.get()
            let hasUpInd = offset > 0
            let rowOffset = hasUpInd ? relY - 1 : relY
            let itemIndex = offset + rowOffset
            guard itemIndex >= 0 && itemIndex < total else { return }

            selectedIdxBinding.set(itemIndex)
            selection?.set(rows[itemIndex].item.id)
            TreeViewHelpers.toggleExpand(rows[itemIndex].item, childrenKeyPath: childrenKeyPath, expandedBinding: expandedBinding)
        }
        .onKeyPress { [selection, expandedBinding, selectedIdxBinding] event in
            let expanded = expandedBinding.get()
            let rows = TreeViewHelpers.flattenedRows(data: data, childrenKeyPath: childrenKeyPath, expandedIDs: expanded)
            let total = rows.count
            guard total > 0, !event.isModifiedNavigation else { return .ignored }

            let idx = selectedIdxBinding.get()

            switch event.key {
            case .up:
                let newIdx = max(0, idx - 1)
                selectedIdxBinding.set(newIdx)
                TreeViewHelpers.syncSelection(selection: selection, rows: rows, index: newIdx)
                return .handled

            case .down:
                let newIdx = min(total - 1, idx + 1)
                selectedIdxBinding.set(newIdx)
                TreeViewHelpers.syncSelection(selection: selection, rows: rows, index: newIdx)
                return .handled

            case .right:
                guard idx < total else { return .handled }
                let row = rows[idx]
                if TreeViewHelpers.hasChildren(row.item, childrenKeyPath: childrenKeyPath)
                    && !expanded.contains(AnyHashableID(row.item.id))
                {
                    var ids = expanded
                    ids.insert(AnyHashableID(row.item.id))
                    expandedBinding.set(ids)
                }
                return .handled

            case .left:
                guard idx < total else { return .handled }
                let row = rows[idx]
                if TreeViewHelpers.hasChildren(row.item, childrenKeyPath: childrenKeyPath)
                    && expanded.contains(AnyHashableID(row.item.id))
                {
                    var ids = expanded
                    ids.remove(AnyHashableID(row.item.id))
                    expandedBinding.set(ids)
                } else if let parentID = row.parentID {
                    if let parentIdx = rows.firstIndex(where: { AnyHashableID($0.item.id) == parentID }) {
                        selectedIdxBinding.set(parentIdx)
                        TreeViewHelpers.syncSelection(selection: selection, rows: rows, index: parentIdx)
                    }
                }
                return .handled

            case .enter, .character(" "):
                guard idx < total else { return .handled }
                TreeViewHelpers.toggleExpand(rows[idx].item, childrenKeyPath: childrenKeyPath, expandedBinding: expandedBinding)
                return .handled

            case .pageUp:
                let newIdx = max(0, idx - visibleCount)
                selectedIdxBinding.set(newIdx)
                TreeViewHelpers.syncSelection(selection: selection, rows: rows, index: newIdx)
                return .handled

            case .pageDown:
                let newIdx = min(total - 1, idx + visibleCount)
                selectedIdxBinding.set(newIdx)
                TreeViewHelpers.syncSelection(selection: selection, rows: rows, index: newIdx)
                return .handled

            case .home:
                selectedIdxBinding.set(0)
                TreeViewHelpers.syncSelection(selection: selection, rows: rows, index: 0)
                return .handled

            case .end:
                let last = total - 1
                selectedIdxBinding.set(last)
                TreeViewHelpers.syncSelection(selection: selection, rows: rows, index: last)
                return .handled

            default:
                return .ignored
            }
        }
    }

    // MARK: - Tree Row Rendering

    private func treeRow(
        _ row: FlatRow<Data.Element>,
        isSelected: Bool,
        expandedIDs: Set<AnyHashableID>,
        theme: any Theme
    ) -> some TerminalView {
        let connectorSpans = TreeViewHelpers.buildConnectorSpans(row, color: style.connectorColor(in: theme))
        let indicatorSpan = TreeViewHelpers.expandIndicatorSpan(
            row,
            childrenKeyPath: childrenKeyPath,
            expandedIDs: expandedIDs,
            style: style,
            theme: theme,
            isSelected: isSelected
        )

        return HStack {
            Text(spans: connectorSpans + [indicatorSpan])
            content(row.item)
        }
        .foreground(isSelected ? style.selectedForeground(in: theme) : theme.foreground)
        .background(orInherit: isSelected ? style.selectedBackground : nil)
    }
}

// MARK: - Static Helpers

/// Namespace for static helper functions used by TreeView.
/// Extracted so closures can call them without capturing `self`.
enum TreeViewHelpers {

    static func flattenedRows<Data: RandomAccessCollection>(
        data: Data,
        childrenKeyPath: KeyPath<Data.Element, Data?>,
        expandedIDs: Set<AnyHashableID>
    ) -> [FlatRow<Data.Element>] where Data.Element: Identifiable, Data.Element.ID: Sendable {
        // Walk the source RandomAccessCollection in-place. RAC gives
        // O(1) .count and O(1) integer-offset indexing, so we never
        // need to materialize an Array just to enumerate it. The win
        // matters when callers pass lazy RACs that compute elements
        // on subscript — the old `Array(data)` evaluated every one.
        var result: [FlatRow<Data.Element>] = []
        let total = data.count
        let lastIndex = total - 1
        var offset = 0
        var idx = data.startIndex
        while offset < total {
            flattenNode(
                data[idx],
                depth: 0,
                isLast: offset == lastIndex,
                ancestorHasNext: [],
                parentID: nil,
                childrenKeyPath: childrenKeyPath,
                expandedIDs: expandedIDs,
                into: &result
            )
            offset += 1
            idx = data.index(after: idx)
        }
        return result
    }

    static func flattenNode<Data: RandomAccessCollection>(
        _ item: Data.Element,
        depth: Int,
        isLast: Bool,
        ancestorHasNext: [Bool],
        parentID: AnyHashableID?,
        childrenKeyPath: KeyPath<Data.Element, Data?>,
        expandedIDs: Set<AnyHashableID>,
        into result: inout [FlatRow<Data.Element>]
    ) where Data.Element: Identifiable, Data.Element.ID: Sendable {
        let flatIndex = result.count
        result.append(FlatRow(
            item: item,
            depth: depth,
            isLast: isLast,
            ancestorHasNext: ancestorHasNext,
            parentID: parentID,
            flatIndex: flatIndex
        ))

        // Short-circuit: collapsed branches contribute no rows and we
        // don't recurse into them.
        let itemID = AnyHashableID(item.id)
        guard expandedIDs.contains(itemID) else { return }
        guard let children = item[keyPath: childrenKeyPath] else { return }
        let childCount = children.count
        guard childCount > 0 else { return }

        // Build ancestorHasNext for children: current level contributes !isLast
        var childAncestorHasNext = ancestorHasNext
        childAncestorHasNext.append(!isLast)

        let lastChildIndex = childCount - 1
        var childOffset = 0
        var childIdx = children.startIndex
        while childOffset < childCount {
            flattenNode(
                children[childIdx],
                depth: depth + 1,
                isLast: childOffset == lastChildIndex,
                ancestorHasNext: childAncestorHasNext,
                parentID: itemID,
                childrenKeyPath: childrenKeyPath,
                expandedIDs: expandedIDs,
                into: &result
            )
            childOffset += 1
            childIdx = children.index(after: childIdx)
        }
    }

    // MARK: - Connectors

    static func buildConnectorSpans<Element: Identifiable>(_ row: FlatRow<Element>, color: Color) -> [TextSpan] {
        guard row.depth > 0 else { return [] }
        var spans: [TextSpan] = []

        // Vertical continuation lines for ancestor levels
        for level in 0..<(row.depth - 1) {
            if row.ancestorHasNext[level] {
                spans.append(TextSpan("\u{2502}   ", foreground: color))  // "│   "
            } else {
                spans.append(TextSpan("    "))
            }
        }

        // Branch connector for this node
        if row.isLast {
            spans.append(TextSpan("\u{2514}\u{2500}\u{2500} ", foreground: color))  // "└── "
        } else {
            spans.append(TextSpan("\u{251C}\u{2500}\u{2500} ", foreground: color))  // "├── "
        }

        return spans
    }

    static func expandIndicatorSpan<Data: RandomAccessCollection>(
        _ row: FlatRow<Data.Element>,
        childrenKeyPath: KeyPath<Data.Element, Data?>,
        expandedIDs: Set<AnyHashableID>,
        style: TreeViewStyle,
        theme: any Theme,
        isSelected: Bool
    ) -> TextSpan where Data.Element: Identifiable, Data.Element.ID: Sendable {
        let color = isSelected ? style.selectedArrowColor(in: theme) : style.arrowColor(in: theme)
        if hasChildren(row.item, childrenKeyPath: childrenKeyPath) {
            if expandedIDs.contains(AnyHashableID(row.item.id)) {
                return TextSpan("\(style.expandedArrow) ", foreground: color, bold: isSelected)
            } else {
                return TextSpan("\(style.collapsedArrow) ", foreground: color, bold: isSelected)
            }
        }
        // Leaf items: show arrow when selected, space when not
        if isSelected {
            return TextSpan("\(style.collapsedArrow) ", foreground: color, bold: true)
        }
        return TextSpan("  ")
    }

    // MARK: - Expand / Collapse

    static func hasChildren<Data: RandomAccessCollection>(
        _ item: Data.Element,
        childrenKeyPath: KeyPath<Data.Element, Data?>
    ) -> Bool where Data.Element: Identifiable, Data.Element.ID: Sendable {
        guard let children = item[keyPath: childrenKeyPath] else { return false }
        return !children.isEmpty
    }

    static func toggleExpand<Data: RandomAccessCollection>(
        _ item: Data.Element,
        childrenKeyPath: KeyPath<Data.Element, Data?>,
        expandedBinding: Binding<Set<AnyHashableID>>
    ) where Data.Element: Identifiable, Data.Element.ID: Sendable {
        guard hasChildren(item, childrenKeyPath: childrenKeyPath) else { return }
        var ids = expandedBinding.get()
        let key = AnyHashableID(item.id)
        if ids.contains(key) {
            ids.remove(key)
        } else {
            ids.insert(key)
        }
        expandedBinding.set(ids)
    }

    // MARK: - Selection

    static func syncSelection<Element: Identifiable>(
        selection: Binding<Element.ID?>?,
        rows: [FlatRow<Element>],
        index: Int
    ) {
        guard let sel = selection, index >= 0 && index < rows.count else { return }
        sel.set(rows[index].item.id)
    }

    // MARK: - Scroll

    static func adjustScroll(scrollOffset: Int, selectedIndex: Int, total: Int, visibleCount: Int) -> Int {
        guard total > visibleCount else { return 0 }

        var offset = scrollOffset

        let hasUp = offset > 0
        let hasDown = (offset + visibleCount) < total
        let topIndicator = hasUp ? 1 : 0
        let bottomIndicator = hasDown ? 1 : 0
        let itemLines = visibleCount - topIndicator - bottomIndicator

        let firstVisible = offset
        let lastVisible = offset + itemLines - 1

        // Selection below viewport
        if selectedIndex > lastVisible {
            let needsDown = (selectedIndex < total - 1)
            let downRes = needsDown ? 1 : 0
            let upRes = 1
            let items = visibleCount - upRes - downRes
            offset = selectedIndex - items + 1
        }

        // Selection above viewport
        if selectedIndex < firstVisible {
            if selectedIndex == 0 {
                offset = 0
            } else {
                offset = selectedIndex
            }
        }

        let maxOffset = total - (visibleCount - 1)
        offset = max(0, min(maxOffset, offset))
        return offset
    }
}

// MARK: - FlatRow

/// A single visible row in the flattened tree, carrying layout metadata.
struct FlatRow<Element: Identifiable>: Identifiable {
    let item: Element
    let depth: Int
    let isLast: Bool
    let ancestorHasNext: [Bool]
    let parentID: AnyHashableID?
    let flatIndex: Int

    var id: FlatRowID<Element.ID> {
        FlatRowID(itemID: item.id, flatIndex: flatIndex)
    }
}

/// Stable identity for flattened rows, combining the item ID with its
/// position to handle the same item appearing at different depths if
/// re-expanded.
struct FlatRowID<ItemID: Hashable>: Hashable {
    let itemID: ItemID
    let flatIndex: Int
}

// MARK: - AnyHashableID

/// Type-erased Hashable wrapper for heterogeneous ID storage in the expanded set.
struct AnyHashableID: Hashable, @unchecked Sendable {
    private let wrapped: AnyHashable

    init<ID: Hashable & Sendable>(_ id: ID) {
        self.wrapped = AnyHashable(id)
    }
}
