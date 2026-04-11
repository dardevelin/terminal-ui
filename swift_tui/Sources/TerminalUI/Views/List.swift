/// A selectable list of items with keyboard navigation.
///
/// Usage:
/// ```
/// List(items, selection: $selectedID) { item in
///     Text(item.name)
/// }
/// ```
public struct List<Data: RandomAccessCollection, Content: TerminalView>: TerminalView
    where Data.Element: Identifiable
{
    public let data: Data
    public let selection: Binding<Data.Element.ID?>?
    public let content: (Data.Element) -> Content

    public init(
        _ data: Data,
        selection: Binding<Data.Element.ID?>? = nil,
        @TerminalViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.selection = selection
        self.content = content
    }

    public var body: some TerminalView {
        ForEach(data) { item in
            content(item)
        }
    }
}
