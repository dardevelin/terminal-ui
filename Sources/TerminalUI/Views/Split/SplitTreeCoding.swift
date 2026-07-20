import Foundation

// JSON (de)serialisation for split trees — i3's `get_tree` / `append_layout`
// pair, so external tools can read the live layout and load one back.
//
// Leaves serialise as markers rather than as views. `any TerminalView` is not
// `Codable`, a view's body is arbitrary Swift, and neither can round-trip
// through JSON. i3 has exactly this constraint and answers it the same way: a
// saved layout describes *slots*, and swallows criteria decide what fills
// them. Here the caller passes a registry mapping marker to view.
//
// Built on `JSONSerialization` rather than `Codable`. Decoding resolves markers
// through a caller-supplied registry, which is not a pure-data transform and
// has no natural channel in `Decoder` short of stuffing `userInfo`; and the two
// node shapes are told apart by key presence rather than a discriminator, which
// `KeyedDecodingContainer` handles awkwardly. A pure-data mirror type would add
// a third representation and a recursive mapping in both directions to buy
// formatting this format does not need.

/// What can go wrong translating a split tree to or from JSON.
public enum SplitTreeCodingError: Error, Equatable {
    /// A leaf had no marker, so nothing could resolve it on the way back in.
    case unmarkedLeaf
    /// The JSON named a marker the supplied registry has no view for.
    case unknownLeafMarker(String)
    /// A split's ratio count did not match its child count.
    case ratioCountMismatch(expected: Int, got: Int)
    /// A node had children but no axis to lay them out along.
    case missingAxis
    /// A node kind this version does not understand — named, so a layout
    /// written by a later version fails legibly.
    case unsupportedKind(String)
    /// A split with no children. A container has to contain something.
    case childrenEmpty
    /// Where a node was expected, the JSON held something that is not an
    /// object — a bare array or number.
    case notANode
    /// A ratio list held something that is not a number. Distinct from a
    /// count mismatch: reporting "0 ratios" for `["0.5", "0.5"]` would send a
    /// tool author looking for a missing value that is plainly there.
    case ratiosMalformed
}

/// Wire-format keys. Split nodes are recognised by carrying an axis, leaves by
/// `kind: "leaf"` — so a future container kind (i3 has stacked, tabbed and
/// dockarea) slots in as another `kind` value without disturbing either.
private enum WireKey {
    static let kind = "kind"
    static let id = "id"
    static let axis = "axis"
    static let children = "children"
    static let ratios = "ratios"
    static let leafKind = "leaf"
}

private extension NSNumber {
    /// Whether this number came from a JSON `true` or `false`.
    ///
    /// `as? Bool` is no help — it coerces 1 and 0 — and the CoreFoundation
    /// singletons (`kCFBooleanTrue`) do not exist on Linux. The type encoding
    /// does distinguish them on both platforms: `c` for a boolean, `i`/`d`/`q`
    /// for real numbers. Documented under `NSNumber.objCType`, and the same
    /// technique swift-corelibs-foundation uses internally.
    var isJSONBoolean: Bool {
        String(cString: objCType) == "c"
    }
}

private enum AxisName {
    static let horizontal = "horizontal"
    static let vertical = "vertical"

    /// Switched rather than ternary so a third axis case becomes a compiler
    /// error here instead of silently encoding as "vertical".
    static func of(_ axis: SplitAxis) -> String {
        switch axis {
        case .horizontal: return horizontal
        case .vertical: return vertical
        }
    }

    static func parse(_ name: String) -> SplitAxis? {
        switch name {
        case horizontal: return .horizontal
        case vertical: return .vertical
        default: return nil
        }
    }
}

extension SplitNode {

    /// Encode this tree as JSON data. Every leaf must carry a marker.
    public func encoded() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: jsonObject(), options: [.sortedKeys]
        )
    }

    /// Encode this tree as a JSON string.
    public func encodedJSON() throws -> String {
        String(decoding: try encoded(), as: UTF8.self)
    }

    /// Decode a tree from JSON data, resolving each leaf marker through
    /// `registry`.
    ///
    /// Main-actor only: the registry holds `any TerminalView` values, which
    /// are not `Sendable` because view bodies routinely capture observable
    /// state classes.
    @MainActor
    public static func decoded(
        from data: Data,
        registry: [String: any TerminalView]
    ) throws -> SplitNode {
        let object = try JSONSerialization.jsonObject(with: data)
        return try node(from: object, registry: registry)
    }

    /// Decode a tree from a JSON string.
    @MainActor
    public static func decoded(
        fromJSON string: String,
        registry: [String: any TerminalView]
    ) throws -> SplitNode {
        try decoded(from: Data(string.utf8), registry: registry)
    }

    // MARK: - Encoding

    private func jsonObject() throws -> [String: Any] {
        switch self {
        case .leaf(_, let id):
            guard let id, !id.isEmpty else { throw SplitTreeCodingError.unmarkedLeaf }
            return [WireKey.kind: WireKey.leafKind, WireKey.id: id]

        case .split(let axis, let children, let ratios):
            return [
                WireKey.axis: AxisName.of(axis),
                WireKey.ratios: ratios,
                WireKey.children: try children.map { try $0.jsonObject() },
            ]
        }
    }

    // MARK: - Decoding

    /// Read a ratio list, refusing anything that is not a number.
    ///
    /// `as? [Double]` alone is too permissive in one direction and too blunt
    /// in the other: `JSONSerialization` hands back `NSNumber`, which bridges
    /// booleans to 1.0 and 0.0 as readily as it bridges 1 and 0.5 — so
    /// `[true, false]` would pass as a valid layout. And a failed cast on
    /// `["0.5"]` yields nil, which read as an empty list and surfaced as a
    /// count mismatch reporting zero ratios for a list that plainly has two.
    private static func ratios(from raw: Any?) throws -> [Double] {
        guard let raw else { return [] }
        guard let values = raw as? [Any] else { throw SplitTreeCodingError.ratiosMalformed }
        return try values.map { value in
            guard let number = value as? NSNumber, !number.isJSONBoolean else {
                throw SplitTreeCodingError.ratiosMalformed
            }
            return number.doubleValue
        }
    }

    @MainActor
    private static func node(
        from object: Any,
        registry: [String: any TerminalView]
    ) throws -> SplitNode {
        guard let dictionary = object as? [String: Any] else {
            throw SplitTreeCodingError.notANode
        }

        // A `kind` marks a non-split node. Only "leaf" exists today; anything
        // else is a container from a version that knows more than this one.
        if let kind = dictionary[WireKey.kind] as? String {
            guard kind == WireKey.leafKind else {
                throw SplitTreeCodingError.unsupportedKind(kind)
            }
            // Rejected here rather than on the way back out: an empty marker
            // decodes to a tree the encoder then refuses, so a caller could
            // load a layout they cannot save again.
            guard let id = dictionary[WireKey.id] as? String, !id.isEmpty else {
                throw SplitTreeCodingError.unmarkedLeaf
            }
            guard let view = registry[id] else {
                throw SplitTreeCodingError.unknownLeafMarker(id)
            }
            return .leaf(view, id: id)
        }

        guard let axisName = dictionary[WireKey.axis] as? String,
              let axis = AxisName.parse(axisName) else {
            throw SplitTreeCodingError.missingAxis
        }

        let rawChildren = dictionary[WireKey.children] as? [Any] ?? []
        guard !rawChildren.isEmpty else { throw SplitTreeCodingError.childrenEmpty }

        let ratios = try Self.ratios(from: dictionary[WireKey.ratios])
        guard ratios.count == rawChildren.count else {
            throw SplitTreeCodingError.ratioCountMismatch(
                expected: rawChildren.count, got: ratios.count
            )
        }

        return .split(
            axis: axis,
            children: try rawChildren.map { try node(from: $0, registry: registry) },
            ratios: ratios
        )
    }
}

extension SplitState {

    /// Encode this state's tree as JSON data.
    public func encoded() throws -> Data {
        try root.encoded()
    }

    /// Encode this state's tree as a JSON string.
    public func encodedJSON() throws -> String {
        try root.encodedJSON()
    }

    /// Build a state from JSON data, resolving leaf markers through `registry`.
    @MainActor
    public convenience init(
        jsonData: Data,
        registry: [String: any TerminalView]
    ) throws {
        self.init(root: try SplitNode.decoded(from: jsonData, registry: registry))
    }

    /// Build a state from a JSON string.
    @MainActor
    public convenience init(
        jsonString: String,
        registry: [String: any TerminalView]
    ) throws {
        try self.init(jsonData: Data(jsonString.utf8), registry: registry)
    }
}
