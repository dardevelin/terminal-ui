/// A column-aligned data table with precomputed rendering.
/// Renders the entire table as a single Text node — zero layout overhead.
///
/// Usage:
/// ```
/// Table(processes, columns: [
///     TableColumn("Name", width: 20) { $0.name },
///     TableColumn("Status", width: 10, alignment: .center) { $0.status },
///     TableColumn("CPU", width: 8, alignment: .right) { "\($0.cpu)%" },
/// ])
/// ```

public struct TableColumn<Row> {
    public let title: String
    public let width: Int
    public let alignment: ColumnAlignment
    public let content: (Row) -> String

    public enum ColumnAlignment {
        case left, center, right
    }

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

public struct Table<Data: RandomAccessCollection>: TerminalView
    where Data.Element: Identifiable
{
    public let data: Data
    public let columns: [TableColumn<Data.Element>]
    public let separator: String
    public let showHeader: Bool

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
