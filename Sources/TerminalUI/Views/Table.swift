/// One column of a ``Table``: a header title, a fixed width, and a closure
/// mapping each row to its cell string.
///
/// Widths are in terminal cells; a cell value longer than `width` is
/// truncated with a trailing `…`. Alignment pads within the column —
/// `.right` suits numbers, `.left` (the default) suits names.
///
/// ```swift
/// TableColumn("CPU%", width: 8, alignment: .right) {
///     String(format: "%.1f", $0.cpu)
/// }
/// ```
public struct TableColumn<Row> {
    /// Header text shown when the table's `showHeader` is true.
    public let title: String
    /// Column width in terminal cells; longer values truncate with `…`.
    public let width: Int
    /// How the cell string is padded within `width`.
    public let alignment: ColumnAlignment
    /// Maps a row to this column's cell string.
    public let content: (Row) -> String

    /// Horizontal placement of a cell's text within its column width.
    public enum ColumnAlignment {
        /// Pad on the right — text starts at the column's left edge.
        case left
        /// Pad both sides evenly.
        case center
        /// Pad on the left — text ends at the column's right edge.
        case right
    }

    /// Creates a column definition.
    ///
    /// - Parameters:
    ///   - title: Header text.
    ///   - width: Column width in cells (default 15).
    ///   - alignment: Cell text placement (default `.left`).
    ///   - content: Row-to-string projection for this column.
    public init(
        _ title: String,
        width: Int = 15,
        alignment: ColumnAlignment = .left,
        content: @escaping (Row) -> String
    ) {
        self.title = title
        self.width = width
        self.alignment = alignment
        self.content = content
    }
}

/// A column-aligned data table, display-only or with rows to select.
///
/// Renders a header row, a `─` rule beneath it, and one line per element,
/// each cell padded/truncated to its ``TableColumn`` width.
///
/// Given no selection, `Table` is display-only — no scrolling, no
/// selection, no focus — and the entire table is precomputed into a single
/// ``Text`` node: one graph node, one measurement, zero per-cell layout
/// overhead, which is why it stays cheap at hundreds of rows. Sort or
/// window the data before passing it in.
///
/// Given a `selection` binding, the rows are a ``List``'s: a `▸` cursor on
/// the selected row, the arrows, PageUp/PageDown and Home/End to move it, a
/// click to select a row, the wheel to scroll, and only the visible window
/// built, under a header and rule that stay put. The table is then one Tab
/// stop, empty or not. `visibleCount` sizes the rows as it does a list's,
/// the header aside. When data nests, use ``TreeView``.
///
/// ```swift
/// Table(
///     Array(state.processes.sorted { $0.cpu > $1.cpu }.prefix(20)),
///     columns: [
///         TableColumn("Process", width: 22) { $0.name },
///         TableColumn("PID", width: 8, alignment: .right) { "\($0.pid)" },
///         TableColumn("CPU%", width: 8, alignment: .right) {
///             String(format: "%.1f", $0.cpu)
///         },
///     ]
/// )
///
/// // The same rows, to pick one from:
/// Table(state.processes,
///       selection: Binding(get: { state.selectedPID },
///                          set: { state.selectedPID = $0 }),
///       visibleCount: 10,
///       columns: [
///           TableColumn("Process", width: 22) { $0.name },
///           TableColumn("PID", width: 8, alignment: .right) { "\($0.pid)" },
///       ])
/// ```
public struct Table<Data: RandomAccessCollection>: TerminalView
    where Data.Element: Identifiable
{
    /// The rows, rendered top to bottom in collection order.
    public let data: Data
    /// Column definitions, rendered left to right.
    public let columns: [TableColumn<Data.Element>]
    /// String placed between adjacent columns (default a single space).
    public let separator: String
    /// Whether to render the header row and its `─` rule.
    public let showHeader: Bool
    /// Two-way selected-row ID. `nil` for a display-only table, which
    /// takes no focus and draws no cursor.
    public let selection: Binding<Data.Element.ID?>?
    /// Two-way scroll offset of a selectable table (index of the first
    /// visible row). `nil` lets the table manage it internally.
    public let scroll: Binding<Int>?
    /// Height budget of a selectable table's rows, the `▲`/`▼` indicator
    /// lines included and the header and rule not. `nil` fits the rows to
    /// the room the container leaves under the header.
    public let visibleCount: Int?

    /// Creates a display-only table over a row collection.
    ///
    /// - Parameters:
    ///   - data: Rows to render.
    ///   - columns: Column definitions applied to every row.
    ///   - separator: Inter-column string (default `" "`).
    ///   - showHeader: Render header + rule (default `true`).
    public init(
        _ data: Data,
        columns: [TableColumn<Data.Element>],
        separator: String = " ",
        showHeader: Bool = true
    ) {
        self.data = data
        self.columns = columns
        self.separator = separator
        self.showHeader = showHeader
        self.selection = nil
        self.scroll = nil
        self.visibleCount = nil
    }

    /// Creates a table whose rows a reader can select, by keyboard or by
    /// mouse.
    ///
    /// The rows behave as a ``List``'s do — a `▸` cursor on the selected
    /// row, arrows, PageUp/PageDown and Home/End to move it, a click to
    /// select a row, the wheel to scroll — under a header that stays put.
    ///
    /// - Parameters:
    ///   - data: Rows, identified by `Element.ID`.
    ///   - selection: Selected-row ID binding.
    ///   - scroll: First-visible-row binding; `nil` for internal management.
    ///   - visibleCount: Height budget in row lines, including the `▲`/`▼`
    ///     indicator lines but not the header; `nil` fits to the container.
    ///   - columns: Column definitions applied to every row.
    ///   - separator: Inter-column string (default `" "`).
    ///   - showHeader: Render header + rule (default `true`).
    public init(
        _ data: Data,
        selection: Binding<Data.Element.ID?>,
        scroll: Binding<Int>? = nil,
        visibleCount: Int? = nil,
        columns: [TableColumn<Data.Element>],
        separator: String = " ",
        showHeader: Bool = true
    ) {
        self.data = data
        self.columns = columns
        self.separator = separator
        self.showHeader = showHeader
        self.selection = selection
        self.scroll = scroll
        self.visibleCount = visibleCount
    }

    /// Display-only, precomputed as single multi-line Text — one node, one
    /// measurement. Selectable, a List of row lines under the header.
    @_documentation(visibility: internal)
    public var body: some TerminalView {
        if let selection {
            VStack(spacing: 0) {
                let header = headerLines(indent: ListRowMarker.width)
                if !header.isEmpty {
                    Text(header.joined(separator: "\n"))
                }
                List(data, selection: selection, scroll: scroll, visibleCount: visibleCount) { element in
                    Text(rowLine(element))
                }
            }
            // A row that wrapped would be two lines tall, and its cells
            // would slide out from under the header.
            .wrap(.none)
        } else if data.isEmpty {
            _EmptyPlaceholder("— no rows —")
        } else {
            Text(renderTable())
        }
    }

    func renderTable() -> String {
        (headerLines(indent: 0) + data.map(rowLine)).joined(separator: "\n")
    }

    /// The header and the `─` rule under it, each led by `indent` blanks —
    /// none when `showHeader` is false.
    func headerLines(indent: Int) -> [String] {
        guard showHeader else { return [] }
        let lead = String(repeating: " ", count: indent)
        let rule = columns.map { column in
            String(repeating: "─", count: column.width)
        }.joined(separator: separator)
        return [lead + formatRow(columns.map(\.title)), lead + rule]
    }

    /// One row's cells, each padded or cut to its column.
    func rowLine(_ element: Data.Element) -> String {
        formatRow(columns.map { column in column.content(element) })
    }

    func formatRow(_ values: [String]) -> String {
        var cells: [String] = []
        for (i, col) in columns.enumerated() {
            let value = i < values.count ? values[i] : ""
            cells.append(alignText(value, width: col.width, alignment: col.alignment))
        }
        return cells.joined(separator: separator)
    }

    func alignText(_ text: String, width: Int, alignment: TableColumn<Data.Element>.ColumnAlignment) -> String {
        // Measured in cells: a value of double-width glyphs is half as
        // many characters as the columns it fills.
        let truncated = width > 0 ? LineBreakMode.byTruncatingTail.apply(to: text, width: width) : ""
        let pad = max(0, width - truncated.displayWidth)

        switch alignment {
        case .left:
            return truncated + String(repeating: " ", count: pad)
        case .right:
            return String(repeating: " ", count: pad) + truncated
        case .center:
            let leftPad = pad / 2
            let rightPad = pad - leftPad
            return String(repeating: " ", count: leftPad) + truncated + String(repeating: " ", count: rightPad)
        }
    }
}
