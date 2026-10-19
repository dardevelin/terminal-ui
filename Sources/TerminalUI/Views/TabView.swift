/// A descriptor for a single tab — holds a label and a content builder closure.
/// Used with ``TabView`` to define tabbed content.
///
/// `Tab` is declarative data, not a view: it renders nothing on its own
/// and only means something inside a ``TabView`` builder block, where
/// ``TabBuilder`` collects it.
///
/// Usage:
/// ```swift
/// TabView {
///     Tab("First") { Text("first page content") }
///     Tab("Second") { Text("second page content") }
///     Tab("Third") { Text("third page content") }
/// }
/// ```
public struct Tab<Content: TerminalView> {
    /// The text shown in the tab bar. Rendered with one cell of padding
    /// each side; its width counts toward tab-bar overflow.
    public let label: String
    /// The pane shown while this tab is selected.
    public let content: Content

    /// Creates a tab descriptor for a ``TabView`` block.
    ///
    /// - Parameters:
    ///   - label: the tab-bar text. Keep it short — long labels push
    ///     siblings into overflow (`<` / `>`) sooner.
    ///   - content: the pane to show while this tab is selected.
    public init(_ label: String, @TerminalViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
}

/// Storage for a type-erased tab — extracts the label
/// and keeps the content as an existential for graph integration.
///
/// Exists because a `TabView`'s tabs hold heterogeneous content types;
/// erasing each ``Tab`` to a descriptor lets ``TabBuilder`` collect them
/// into one flat array. Normally produced by the builder — construct one
/// directly only when assembling tabs dynamically outside a builder block
/// (e.g. mapping a runtime collection into tabs).
public struct TabDescriptor {
    /// The text shown in the tab bar.
    public let label: String
    /// The tab's pane, type-erased for storage alongside other tabs.
    public let content: any TerminalView

    /// Creates a type-erased descriptor directly — the escape hatch for
    /// assembling tabs from runtime data outside a builder block.
    ///
    /// - Parameters:
    ///   - label: the tab-bar text.
    ///   - content: the pane to show while this tab is selected.
    public init(label: String, content: any TerminalView) {
        self.label = label
        self.content = content
    }
}

/// Result builder that collects ``Tab`` instances into a flat array of
/// ``TabDescriptor``s. Accepts `Tab` values of differing content types in
/// one block — the erasure happens here, per expression.
@resultBuilder
public struct TabBuilder {
    /// Concatenates the block's per-expression descriptor lists in source
    /// order.
    public static func buildBlock(_ tabs: [TabDescriptor]...) -> [TabDescriptor] {
        tabs.flatMap { $0 }
    }

    /// Accepts an already-erased ``TabDescriptor`` expression.
    public static func buildExpression(_ tab: TabDescriptor) -> [TabDescriptor] {
        [tab]
    }

    /// Accepts a typed ``Tab`` expression, erasing its content here so
    /// tabs of different content types coexist in one block.
    public static func buildExpression<C: TerminalView>(_ tab: Tab<C>) -> [TabDescriptor] {
        [TabDescriptor(label: tab.label, content: tab.content)]
    }
}

/// A tabbed container that shows a horizontal tab bar with switchable content panes.
///
/// Features:
/// - Tab bar with active tab highlighted (bold + underline) and inactive tabs dimmed
/// - Keyboard navigation: left/right arrows when tab bar is focused,
///   Home/End for first/last, digit keys 1-9 (plain or with Ctrl)
/// - Mouse: click on any tab label to switch
/// - Overflow indicators (< >) when tabs exceed available width; the
///   selected tab stays visible, centered among what fits
///
/// The tab bar occupies one terminal row, a ``Divider`` sits beneath it,
/// and the selected pane fills the rest of the container. Only the
/// selected pane exists in the layout graph — switching tabs rebuilds the
/// content subtree, so inactive panes cost nothing per frame. Reach for
/// `TabView` when panes are alternatives sharing one region; use
/// ``SplitView`` when they should be visible side by side.
///
/// Usage with builder pattern (selection managed internally):
/// ```swift
/// TabView {
///     Tab("First") { Text("first page content") }
///     Tab("Second") { Text("second page content") }
///     Tab("Third") { Text("third page content") }
/// }
/// ```
///
/// Usage with selection binding, for driving or observing the selected
/// index from app state:
/// ```swift
/// @TerminalState var tab = 0
/// TabView(selection: $tab) {
///     Tab("First") { Text("first page content") }
///     Tab("Second") { Text("second page content") }
/// }
/// ```
public struct TabView: TerminalView {
    let tabs: [TabDescriptor]
    let selectionBinding: Binding<Int>?

    @TerminalState var internalSelection = 0

    /// Create a TabView with automatic internal selection management.
    ///
    /// - Parameter content: the tabs, declared with ``Tab`` (or raw
    ///   ``TabDescriptor`` values), in bar order.
    public init(@TabBuilder content: () -> [TabDescriptor]) {
        self.tabs = content()
        self.selectionBinding = nil
    }

    /// Create a TabView with an external selection binding.
    ///
    /// - Parameters:
    ///   - selection: binding to the selected tab index. Out-of-range
    ///     values are clamped when read, so a stale index cannot crash
    ///     after tabs change count.
    ///   - content: the tabs, declared with ``Tab`` (or raw
    ///     ``TabDescriptor`` values), in bar order.
    public init(selection: Binding<Int>, @TabBuilder content: () -> [TabDescriptor]) {
        self.tabs = content()
        self.selectionBinding = selection
    }

    /// The currently selected index — reads from binding or internal state.
    var selectedIndex: Int {
        let raw = selectionBinding?.get() ?? internalSelection
        guard !tabs.isEmpty else { return 0 }
        return max(0, min(tabs.count - 1, raw))
    }

    public var body: some TerminalView {
        let selected = selectedIndex
        let tabCount = tabs.count
        let selBinding = selectionBinding
        let internalBinding = $internalSelection

        VStack {
            // Tab bar
            TabBar(
                tabs: tabs,
                selected: selected,
                onSelect: { [selBinding, internalBinding, tabCount] index in
                    guard tabCount > 0 else { return }
                    let clamped = max(0, min(tabCount - 1, index))
                    if let binding = selBinding {
                        binding.set(clamped)
                    } else {
                        internalBinding.set(clamped)
                    }
                }
            )

            Divider()

            // Active tab content — uses _TabContentRelay for type erasure
            if tabCount > 0 {
                _TabContentRelay(view: tabs[selected].content)
            }
        }
    }
}

// MARK: - Tab Bar (internal composite view)

/// The horizontal tab bar — renders labels, handles focus/click/keyboard.
/// Separated as its own view so GeometryReader scoping works correctly.
struct TabBar: TerminalView {
    let tabs: [TabDescriptor]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some TerminalView {
        WidthReader { width in
            // Build tab label spans with overflow handling
            let barData = Self.computeTabBar(
                tabs: tabs,
                selected: selected,
                availableWidth: width
            )

            HStack {
                // Left overflow indicator
                if barData.hasLeftOverflow {
                    Text(TextSpan("< ", foreground: .gray))
                }

                // Tab labels as styled spans
                Text(spans: barData.spans)

                // Right overflow indicator
                if barData.hasRightOverflow {
                    Text(TextSpan(" >", foreground: .gray))
                }

                Spacer()
            }
            .focusable()
            .onClick { relX, _ in
                for region in barData.hitRegions {
                    if relX >= region.startX && relX < region.endX {
                        onSelect(region.tabIndex)
                        return
                    }
                }
            }
            .onKeyPress { event in
                Self.handleKeyPress(
                    event: event,
                    selected: selected,
                    tabCount: tabs.count,
                    onSelect: onSelect
                )
            }
        }
        // The reader exists to learn the bar's WIDTH; the bar is one row by
        // declaration. Without this bound, a GeometryReader's stack-flex
        // greediness makes the bar the flexible child of TabView's column
        // and every tab's content gets shoved to the bottom.
        .frame(height: 1)
    }

    // MARK: - Tab Bar Layout

    /// Computed tab bar data — label spans and hit regions for click handling.
    struct TabBarData {
        let spans: [TextSpan]
        let hitRegions: [HitRegion]
        let hasLeftOverflow: Bool
        let hasRightOverflow: Bool
    }

    struct HitRegion {
        let startX: Int
        let endX: Int
        let tabIndex: Int
    }

    /// Compute which tabs are visible, build styled spans, and record hit regions.
    static func computeTabBar(
        tabs: [TabDescriptor],
        selected: Int,
        availableWidth: Int
    ) -> TabBarData {
        let tabCount = tabs.count
        guard tabCount > 0 else {
            return TabBarData(spans: [], hitRegions: [], hasLeftOverflow: false, hasRightOverflow: false)
        }

        let separator = " | "
        let separatorWidth = separator.count
        let overflowWidth = 2 // "< " or " >"

        // Each tab label is rendered as: " Label " (1 char padding each side)
        let labelWidths: [Int] = tabs.map { $0.label.count + 2 }
        let totalWidth = labelWidths.reduce(0, +) + max(0, tabCount - 1) * separatorWidth

        // If everything fits, show all tabs
        if totalWidth <= availableWidth {
            return buildFullBar(tabs: tabs, selected: selected, separator: separator, labelWidths: labelWidths)
        }

        // Overflow mode — center the selected tab and expand outward
        return buildOverflowBar(
            tabs: tabs,
            selected: selected,
            separator: separator,
            labelWidths: labelWidths,
            separatorWidth: separatorWidth,
            availableWidth: availableWidth,
            overflowWidth: overflowWidth
        )
    }

    /// Build the bar when all tabs fit.
    static func buildFullBar(
        tabs: [TabDescriptor],
        selected: Int,
        separator: String,
        labelWidths: [Int]
    ) -> TabBarData {
        var spans: [TextSpan] = []
        var hitRegions: [HitRegion] = []
        var x = 0

        for (i, tab) in tabs.enumerated() {
            let label = " \(tab.label) "
            if i == selected {
                spans.append(TextSpan(label, foreground: .white, bold: true, underline: true))
            } else {
                spans.append(TextSpan(label, foreground: .gray))
            }
            hitRegions.append(HitRegion(startX: x, endX: x + labelWidths[i], tabIndex: i))
            x += labelWidths[i]

            if i < tabs.count - 1 {
                spans.append(TextSpan(separator, foreground: .ansi256(240)))
                x += separator.count
            }
        }

        return TabBarData(spans: spans, hitRegions: hitRegions, hasLeftOverflow: false, hasRightOverflow: false)
    }

    /// Build the bar in overflow mode — show tabs centered around the selected one.
    static func buildOverflowBar(
        tabs: [TabDescriptor],
        selected: Int,
        separator: String,
        labelWidths: [Int],
        separatorWidth: Int,
        availableWidth: Int,
        overflowWidth: Int
    ) -> TabBarData {
        let tabCount = tabs.count

        // Start from the selected tab and expand outward
        var firstVisible = selected
        var lastVisible = selected
        var widthUsed = labelWidths[selected]

        // Expand right
        while lastVisible < tabCount - 1 {
            let nextWidth = separatorWidth + labelWidths[lastVisible + 1]
            let leftOverhead = firstVisible > 0 ? overflowWidth : 0
            let rightOverhead = (lastVisible + 1 < tabCount - 1) ? overflowWidth : 0
            if widthUsed + nextWidth + leftOverhead + rightOverhead <= availableWidth {
                lastVisible += 1
                widthUsed += nextWidth
            } else {
                break
            }
        }

        // Expand left
        while firstVisible > 0 {
            let prevWidth = separatorWidth + labelWidths[firstVisible - 1]
            let leftOverhead = (firstVisible - 1 > 0) ? overflowWidth : 0
            let rightOverhead = lastVisible < tabCount - 1 ? overflowWidth : 0
            if widthUsed + prevWidth + leftOverhead + rightOverhead <= availableWidth {
                firstVisible -= 1
                widthUsed += prevWidth
            } else {
                break
            }
        }

        let hasLeft = firstVisible > 0
        let hasRight = lastVisible < tabCount - 1

        var spans: [TextSpan] = []
        var hitRegions: [HitRegion] = []
        var x = hasLeft ? overflowWidth : 0

        for i in firstVisible...lastVisible {
            let label = " \(tabs[i].label) "
            if i == selected {
                spans.append(TextSpan(label, foreground: .white, bold: true, underline: true))
            } else {
                spans.append(TextSpan(label, foreground: .gray))
            }
            hitRegions.append(HitRegion(startX: x, endX: x + labelWidths[i], tabIndex: i))
            x += labelWidths[i]

            if i < lastVisible {
                spans.append(TextSpan(separator, foreground: .ansi256(240)))
                x += separator.count
            }
        }

        return TabBarData(spans: spans, hitRegions: hitRegions, hasLeftOverflow: hasLeft, hasRightOverflow: hasRight)
    }

    // MARK: - Keyboard Navigation

    static func handleKeyPress(
        event: KeyEvent,
        selected: Int,
        tabCount: Int,
        onSelect: (Int) -> Void
    ) -> KeyEventResult {
        guard tabCount > 0 else { return .ignored }

        switch event.key {
        case .left:
            if selected > 0 {
                onSelect(selected - 1)
                return .handled
            }
            return .ignored

        case .right:
            if selected < tabCount - 1 {
                onSelect(selected + 1)
                return .handled
            }
            return .ignored

        case .home:
            onSelect(0)
            return .handled

        case .end:
            onSelect(tabCount - 1)
            return .handled

        case .character(let c) where event.modifiers.contains(.ctrl):
            // Ctrl+1 through Ctrl+9
            if let digit = c.wholeNumberValue, digit >= 1, digit <= 9 {
                let index = digit - 1
                if index < tabCount {
                    onSelect(index)
                    return .handled
                }
            }
            return .ignored

        case .character(let c):
            // Plain digit keys 1-9 when tab bar is focused
            if let digit = c.wholeNumberValue, digit >= 1, digit <= 9 {
                let index = digit - 1
                if index < tabCount {
                    onSelect(index)
                    return .handled
                }
            }
            return .ignored

        default:
            return .ignored
        }
    }
}

// MARK: - Tab Content Relay

/// A primitive view that bridges type-erased tab content into the attribute graph.
/// Behaves as a VStack with a single child — the graph constructs/updates
/// the wrapped existential view through `_GraphVStack` conformance.
///
/// When the selected tab changes, the graph detects the child type mismatch
/// during `updateLayoutChildren` and rebuilds the subtree.
struct _TabContentRelay: TerminalView {
    let view: any TerminalView

    var body: Never { fatalError() }
}

extension _TabContentRelay: _GraphVStack {
    func graphChildren() -> [Any] {
        [view]
    }
}
