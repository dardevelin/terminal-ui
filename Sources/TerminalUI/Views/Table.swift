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
        case left, center, right
    }

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

/// A column-aligned data table with precomputed rendering.
///
/// Renders a header row, a `─` rule beneath it, and one line per element,
/// each cell padded/truncated to its ``TableColumn`` width. The entire
/// table is precomputed into a single ``Text`` node — one graph node, one
/// measurement, zero per-cell layout overhead — which is why it stays cheap
/// at hundreds of rows.
///
/// `Table` is display-only: no scrolling, no selection, no focus. When rows
/// need a cursor and keyboard navigation, use ``List`` (formatting each row
/// into aligned columns yourself); when data nests, use ``TreeView``. Sort
/// or window the data before passing it in.
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
    }

    /// Precomputed as single multi-line Text — one node, one measurement.
    public var body: some TerminalView {
        if data.isEmpty {
            _EmptyPlaceholder("— no rows —")
        } else {
            Text(renderTable())
        }
    }

    func renderTable() -> String {
        var lines: [String] = []

        if showHeader {
            // Header
            lines.append(formatRow(columns.map(\.title), bold: false))
            // Separator
            let sep = columns.map { col in
                String(repeating: "─", count: col.width)
            }.joined(separator: separator)
            lines.append(sep)
        }

        // Data rows
        for element in data {
            let values = columns.map { col in col.content(element) }
            lines.append(formatRow(values, bold: false))
        }

        return lines.joined(separator: "\n")
    }

    func formatRow(_ values: [String], bold: Bool) -> String {
        var cells: [String] = []
        for (i, col) in columns.enumerated() {
            let value = i < values.count ? values[i] : ""
            cells.append(alignText(value, width: col.width, alignment: col.alignment))
        }
        return cells.joined(separator: separator)
    }

    func alignText(_ text: String, width: Int, alignment: TableColumn<Data.Element>.ColumnAlignment) -> String {
        let truncated = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        let pad = max(0, width - truncated.count)

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
