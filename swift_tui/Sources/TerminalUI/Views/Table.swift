/// A column-aligned data table.
///
/// Usage:
/// ```
/// Table(data, columns: [
///     TableColumn("Name", width: 20) { Text($0.name) },
///     TableColumn("Status", width: 10) { Text($0.status) },
/// ])
/// ```
import Foundation

public struct TableColumn<Row> {
    public let title: String
    public let width: Int
    public let content: (Row) -> String

    public init(_ title: String, width: Int = 15, content: @escaping (Row) -> String) {
        self.title = title
        self.width = width
        self.content = content
    }
}

public struct Table<Data: RandomAccessCollection>: TerminalView
    where Data.Element: Identifiable
{
    public let data: Data
    public let columns: [TableColumn<Data.Element>]

    public init(_ data: Data, columns: [TableColumn<Data.Element>]) {
        self.data = data
        self.columns = columns
    }

    public var body: some TerminalView {
        VStack {
            // Header row
            Text(headerLine())
                .bold()
            Divider()
            // Data rows
            ForEach(data.enumerated().map { IndexedItem(index: $0.offset, element: $0.element) }) { item in
                Text(rowLine(item.element))
            }
        }
    }

    func headerLine() -> String {
        columns.map { col in
            col.title.padding(toLength: col.width, withPad: " ", startingAt: 0)
        }.joined(separator: " ")
    }

    func rowLine(_ item: Data.Element) -> String {
        columns.map { col in
            col.content(item).padding(toLength: col.width, withPad: " ", startingAt: 0)
        }.joined(separator: " ")
    }
}

// Make Array of Identifiable elements work with ForEach
// Wrapper to make array elements work with ForEach by index
struct IndexedItem<T: Identifiable>: Identifiable {
    let index: Int
    let element: T
    var id: T.ID { element.id }
}
