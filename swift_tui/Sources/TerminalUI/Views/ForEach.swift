/// Renders a view for each element in a collection.
/// Uses Identifiable elements for stable identity across updates.
///
/// Usage:
/// ```
/// ForEach(items) { item in
///     Text(item.name)
/// }
/// ```
public struct ForEach<Data: RandomAccessCollection, Content: TerminalView>: TerminalView
    where Data.Element: Identifiable
{
    public let data: Data
    public let content: (Data.Element) -> Content

    public init(_ data: Data, @TerminalViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    public var body: Never { fatalError() }
}

/// ForEach with explicit id keypath — for non-Identifiable data.
///
/// Usage:
/// ```
/// ForEach(names, id: \.self) { name in
///     Text(name)
/// }
/// ```
public struct ForEachWithID<Data: RandomAccessCollection, ID: Hashable, Content: TerminalView>: TerminalView {
    public let data: Data
    public let idKeyPath: KeyPath<Data.Element, ID>
    public let content: (Data.Element) -> Content

    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @TerminalViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.idKeyPath = id
        self.content = content
    }

    public var body: Never { fatalError() }
}

// Convenience: ForEach with id keypath
extension ForEach where Data.Element: Identifiable {
    // Already covered by the main init
}
