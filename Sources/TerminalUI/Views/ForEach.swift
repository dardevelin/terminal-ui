/// Renders a view for each element in a collection.
///
/// Uses `Identifiable` elements for stable identity across updates: when the
/// data changes, rows keep their graph nodes (and any state hanging off
/// them) matched by `id`, not by position. `ForEach` adds no chrome of its
/// own — rows stack according to the enclosing ``VStack``/``HStack``. It
/// renders *every* element; for large collections that need scrolling and
/// selection, reach for ``List``, which virtualizes to the visible window.
/// For non-`Identifiable` data keyed by a property, see ``ForEachWithID``.
///
/// ```swift
/// VStack {
///     ForEach(items) { item in
///         Text(item.name)
///     }
/// }
/// ```
public struct ForEach<Data: RandomAccessCollection, Content: TerminalView>: TerminalView
    where Data.Element: Identifiable
{
    /// The collection driving the rows.
    public let data: Data
    /// Builds the row view for one element.
    public let content: (Data.Element) -> Content

    /// Creates rows from an `Identifiable` collection.
    ///
    /// - Parameters:
    ///   - data: Collection whose elements' `id`s provide row identity.
    ///   - content: Row builder, called per element on each update.
    public init(_ data: Data, @TerminalViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    @_documentation(visibility: internal)
    public var body: Never { fatalError() }
}

/// ``ForEach`` with an explicit id key path — for non-`Identifiable` data.
///
/// Same identity contract as ``ForEach``, but row identity comes from the
/// `Hashable` value at `id` instead of an `Identifiable` conformance. Use it
/// for plain `String`/`Int` collections (`id: \.self`) or when the natural
/// key is a property of a type you don't own.
///
/// ```swift
/// ForEachWithID(names, id: \.self) { name in
///     Text(name)
/// }
/// ```
public struct ForEachWithID<Data: RandomAccessCollection, ID: Hashable, Content: TerminalView>: TerminalView {
    /// The collection driving the rows.
    public let data: Data
    /// Key path extracting each element's stable identity.
    public let idKeyPath: KeyPath<Data.Element, ID>
    /// Builds the row view for one element.
    public let content: (Data.Element) -> Content

    /// Creates rows keyed by an explicit id key path.
    ///
    /// - Parameters:
    ///   - data: Collection to iterate.
    ///   - id: Key path to a `Hashable` value providing row identity.
    ///   - content: Row builder, called per element on each update.
    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @TerminalViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.idKeyPath = id
        self.content = content
    }

    @_documentation(visibility: internal)
    public var body: Never { fatalError() }
}

// Convenience: ForEach with id keypath
extension ForEach where Data.Element: Identifiable {
    // Already covered by the main init
}
