import Foundation
import Testing
@testable import TerminalUI

// A split tree round-trips through JSON so external tools — scripts, agents,
// debug viewers, a second terminal over the control socket — can read the live
// layout and load one back. This is i3's `get_tree` / `append_layout` pair.
//
// Leaves serialize as markers, not as views. `any TerminalView` is not
// Codable and a view body is arbitrary Swift, so reflecting one into JSON is
// not a thing that can round-trip. i3 has the same constraint and solves it
// the same way: a saved layout describes *slots*, and swallows criteria decide
// what fills them. Here the caller supplies a registry mapping marker to view.

/// Built per call rather than stored globally: the values are
/// `any TerminalView`, which is not `Sendable`, so a shared instance is not
/// expressible under strict concurrency — the same constraint that makes the
/// decode API main-actor only.
@MainActor
private func registry() -> [String: any TerminalView] {
    [
        "left": Text("L"),
        "right": Text("R"),
        "top-right": Text("TR"),
        "bottom-right": Text("BR"),
    ]
}

/// Normalise JSON text so assertions compare structure rather than key order
/// or whitespace, which `JSONEncoder` does not promise.
private func canonical(_ json: String) throws -> String {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let data = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
}

@Suite("Split tree encoding")
@MainActor
struct SplitTreeEncodingTests {

    @Test("a single-level horizontal split encodes to the wire format")
    func encodeSingleLevelHorizontal() throws {
        let tree = SplitNode.split(
            axis: .horizontal,
            children: [.leaf(Text("L"), id: "left"), .leaf(Text("R"), id: "right")],
            ratios: [0.6, 0.4]
        )
        let expected = """
        {"axis":"horizontal","children":[{"id":"left","kind":"leaf"},\
        {"id":"right","kind":"leaf"}],"ratios":[0.6,0.4]}
        """
        #expect(try canonical(tree.encodedJSON()) == (try canonical(expected)))
    }

    @Test("a nested tree encodes recursively")
    func encodeNestedTree() throws {
        let tree = SplitNode.split(
            axis: .horizontal,
            children: [
                .leaf(Text("L"), id: "left"),
                .split(
                    axis: .vertical,
                    children: [
                        .leaf(Text("TR"), id: "top-right"),
                        .leaf(Text("BR"), id: "bottom-right"),
                    ],
                    ratios: [0.5, 0.5]
                ),
            ],
            ratios: [0.6, 0.4]
        )
        let expected = """
        {"axis":"horizontal","children":[{"id":"left","kind":"leaf"},\
        {"axis":"vertical","children":[{"id":"top-right","kind":"leaf"},\
        {"id":"bottom-right","kind":"leaf"}],"ratios":[0.5,0.5]}],"ratios":[0.6,0.4]}
        """
        #expect(try canonical(tree.encodedJSON()) == (try canonical(expected)))
    }

    @Test("a leaf built without a marker cannot be encoded")
    func encodeRejectsUnmarkedLeaf() {
        // The marker is what a reader has to resolve back to a view. A leaf
        // without one would encode a slot nothing could fill, so the failure
        // belongs at encode time rather than in whatever tries to load it.
        let tree = SplitNode.split(
            axis: .horizontal,
            children: [.leaf(Text("anon")), .leaf(Text("R"), id: "right")],
            ratios: [0.5, 0.5]
        )
        #expect(throws: SplitTreeCodingError.unmarkedLeaf) {
            try tree.encodedJSON()
        }
    }

    @Test("axis encodes as a lowercase string")
    func encodeAxisLowercaseStrings() throws {
        let vertical = SplitNode.split(
            axis: .vertical,
            children: [.leaf(Text("L"), id: "left")],
            ratios: [1.0]
        )
        #expect(try vertical.encodedJSON().contains("\"vertical\""))
        #expect(try !vertical.encodedJSON().contains("SplitAxis"))
    }

    @Test("children and ratios keep declaration order")
    func encodeRatiosMatchInputOrder() throws {
        let tree = SplitNode.split(
            axis: .horizontal,
            children: [
                .leaf(Text("R"), id: "right"),
                .leaf(Text("L"), id: "left"),
            ],
            ratios: [0.25, 0.75]
        )
        let json = try tree.encodedJSON()
        let rightIndex = try #require(json.range(of: "right")).lowerBound
        let leftIndex = try #require(json.range(of: "left")).lowerBound
        #expect(rightIndex < leftIndex, "children are zipped with ratios by index")
        #expect(json.contains("0.25"))
    }
}

@Suite("Split tree decoding")
@MainActor
struct SplitTreeDecodingTests {

    @Test("an encoded split decodes back to the same shape")
    func decodeRoundTripsHorizontalSplit() throws {
        let original = SplitNode.split(
            axis: .horizontal,
            children: [.leaf(Text("L"), id: "left"), .leaf(Text("R"), id: "right")],
            ratios: [0.6, 0.4]
        )
        let decoded = try SplitNode.decoded(
            fromJSON: original.encodedJSON(), registry: registry()
        )
        guard case .split(let axis, let children, let ratios) = decoded else {
            Issue.record("expected a split at the root")
            return
        }
        #expect(axis == .horizontal)
        #expect(children.count == 2)
        #expect(ratios == [0.6, 0.4])
    }

    @Test("a marker with no registry entry is refused")
    func decodeUnknownMarkerThrows() {
        let json = """
        {"axis":"horizontal","ratios":[1.0],"children":[{"kind":"leaf","id":"ghost"}]}
        """
        #expect(throws: SplitTreeCodingError.unknownLeafMarker("ghost")) {
            try SplitNode.decoded(fromJSON: json, registry: registry())
        }
    }

    @Test("a split without an axis is refused")
    func decodeMissingAxisThrows() {
        let json = """
        {"ratios":[1.0],"children":[{"kind":"leaf","id":"left"}]}
        """
        #expect(throws: SplitTreeCodingError.missingAxis) {
            try SplitNode.decoded(fromJSON: json, registry: registry())
        }
    }

    @Test("ratios that do not match the child count are refused")
    func decodeRatioMismatchThrows() {
        let json = """
        {"axis":"horizontal","ratios":[0.5],"children":[\
        {"kind":"leaf","id":"left"},{"kind":"leaf","id":"right"}]}
        """
        #expect(throws: SplitTreeCodingError.ratioCountMismatch(expected: 2, got: 1)) {
            try SplitNode.decoded(fromJSON: json, registry: registry())
        }
    }

    @Test("a split with no children is refused")
    func decodeEmptyChildrenThrows() {
        let json = """
        {"axis":"horizontal","ratios":[],"children":[]}
        """
        #expect(throws: SplitTreeCodingError.childrenEmpty) {
            try SplitNode.decoded(fromJSON: json, registry: registry())
        }
    }

    @Test("an empty marker is refused rather than decoded into an unsavable tree")
    func decodeEmptyMarkerThrows() {
        // The encoder requires a non-empty marker. Accepting one here would
        // hand back a tree the caller could not save again.
        let json = """
        {"axis":"horizontal","ratios":[1.0],"children":[{"kind":"leaf","id":""}]}
        """
        #expect(throws: SplitTreeCodingError.unmarkedLeaf) {
            try SplitNode.decoded(fromJSON: json, registry: registry())
        }
    }

    @Test("ratios that are not numbers are named as malformed, not miscounted")
    func decodeMalformedRatiosThrows() {
        // Reporting a count mismatch here would say "0 ratios" about a list
        // that visibly has two.
        let json = """
        {"axis":"horizontal","ratios":["0.5","0.5"],"children":[\
        {"kind":"leaf","id":"left"},{"kind":"leaf","id":"right"}]}
        """
        #expect(throws: SplitTreeCodingError.ratiosMalformed) {
            try SplitNode.decoded(fromJSON: json, registry: registry())
        }
    }

    @Test("boolean ratios are refused rather than coerced to 1 and 0")
    func decodeBooleanRatiosThrows() {
        // JSON booleans arrive as NSNumber and bridge to Double as readily as
        // real numbers do, so `[true, false]` would otherwise pass as a layout.
        let json = """
        {"axis":"horizontal","ratios":[true,false],"children":[\
        {"kind":"leaf","id":"left"},{"kind":"leaf","id":"right"}]}
        """
        #expect(throws: SplitTreeCodingError.ratiosMalformed) {
            try SplitNode.decoded(fromJSON: json, registry: registry())
        }
    }

    @Test("integer ratios decode — JSON does not distinguish 1 from 1.0")
    func decodeIntegerRatios() throws {
        let json = """
        {"axis":"horizontal","ratios":[1,3],"children":[\
        {"kind":"leaf","id":"left"},{"kind":"leaf","id":"right"}]}
        """
        let decoded = try SplitNode.decoded(fromJSON: json, registry: registry())
        guard case .split(_, _, let ratios) = decoded else {
            Issue.record("expected a split at the root")
            return
        }
        #expect(ratios == [1.0, 3.0])
    }

    @Test("something that is not an object where a node belongs is refused")
    func decodeNonObjectThrows() {
        #expect(throws: SplitTreeCodingError.notANode) {
            try SplitNode.decoded(fromJSON: "[1,2]", registry: registry())
        }
    }

    @Test("a node kind this version does not know is refused by name")
    func decodeUnsupportedKindThrows() {
        // i3 has stacked, tabbed and dockarea containers. Naming the kind in
        // the error means a layout saved by a later version fails legibly
        // rather than as a generic parse error.
        let json = """
        {"axis":"horizontal","ratios":[1.0],"children":[{"kind":"tabbed","id":"x"}]}
        """
        #expect(throws: SplitTreeCodingError.unsupportedKind("tabbed")) {
            try SplitNode.decoded(fromJSON: json, registry: registry())
        }
    }
}

@Suite("Split tree round-trip")
@MainActor
struct SplitTreeRoundTripTests {

    @Test("encoding a decoded tree reproduces the original JSON")
    func roundTripPreservesShape() throws {
        let original = SplitNode.split(
            axis: .horizontal,
            children: [
                .leaf(Text("L"), id: "left"),
                .split(
                    axis: .vertical,
                    children: [
                        .leaf(Text("TR"), id: "top-right"),
                        .leaf(Text("BR"), id: "bottom-right"),
                    ],
                    ratios: [0.5, 0.5]
                ),
            ],
            ratios: [0.6, 0.4]
        )
        let first = try original.encodedJSON()
        let second = try SplitNode
            .decoded(fromJSON: first, registry: registry())
            .encodedJSON()
        #expect(try canonical(first) == (try canonical(second)))
    }

    @Test("ratios survive unnormalised")
    func roundTripPreservesRatios() throws {
        // Ratios are data. Normalising them is layout's job, and doing it in
        // the codec would silently rewrite a tree the caller round-tripped.
        let original = SplitNode.split(
            axis: .vertical,
            children: [.leaf(Text("L"), id: "left"), .leaf(Text("R"), id: "right")],
            ratios: [3.0, 7.0]
        )
        let decoded = try SplitNode.decoded(
            fromJSON: original.encodedJSON(), registry: registry()
        )
        guard case .split(_, _, let ratios) = decoded else {
            Issue.record("expected a split at the root")
            return
        }
        #expect(ratios == [3.0, 7.0])
    }

    @Test("SplitState round-trips through JSON")
    func splitStateRoundTrips() throws {
        let state = SplitState(root: .split(
            axis: .horizontal,
            children: [.leaf(Text("L"), id: "left"), .leaf(Text("R"), id: "right")],
            ratios: [0.6, 0.4]
        ))
        let restored = try SplitState(jsonString: state.encodedJSON(), registry: registry())
        #expect(try canonical(restored.encodedJSON()) == (try canonical(state.encodedJSON())))
    }
}
