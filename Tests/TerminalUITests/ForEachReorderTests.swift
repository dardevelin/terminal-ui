import Observation
import Testing
@testable import TerminalUI

// A ForEach whose elements only moved kept every row's node, and took the
// path that settles an unchanged frame: it reported nothing changed, and
// left the sizes measured for the old order cached. A stack's size can
// depend on that order — an HStack measures only the rows that start inside
// its width — so a reordered row could be drawn clipped to the height of the
// order before.

private struct Item: Identifiable {
    let id: Int
    let text: String
}

private struct Identified: TerminalView {
    let items: [Item]
    var body: some TerminalView {
        VStack {
            ForEach(items) { item in Text(item.text) }
        }
    }
}

private struct KeyPathed: TerminalView {
    let words: [String]
    var body: some TerminalView {
        VStack {
            ForEachWithID(words, id: \.self) { word in Text(word) }
        }
    }
}

/// An HStack whose height follows the order of its rows: at a width of four,
/// `abcd` first fills the line and the rows after it are not measured, while
/// a two-line row first is.
private struct Strip: TerminalView {
    let items: [Item]
    var body: some TerminalView {
        VStack {
            HStack {
                ForEach(items) { item in Text(item.text) }
            }
            Text("end")
        }
    }
}

@Observable
private final class Shelf {
    var items: [Item]
    init(_ items: [Item]) { self.items = items }
}

/// `Strip`, reordered by a change to observed state: the runtime drains it
/// in place rather than walking from the root.
private struct ObservedStrip: TerminalView {
    let shelf: Shelf
    var body: some TerminalView { Strip(items: shelf.items) }
}

/// Lays out and draws a frame as the runtime does, one string per line with
/// its trailing blanks dropped.
@MainActor
private func render(_ graph: AttributeGraph, width: Int, height: Int) -> [String] {
    var buffer = CellBuffer(width: width, height: height)
    if let root = graph.root {
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: root, in: rect)
        GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
    }
    return (0..<height).map { y in
        var line = String((0..<width).map { x in buffer[x, y].character })
        while line.last == " " { line.removeLast() }
        return line
    }
}

private let alpha = Item(id: 1, text: "alpha")
private let beta = Item(id: 2, text: "beta")
private let gamma = Item(id: 3, text: "gamma")

@Suite("A ForEach whose rows only moved reports the change and draws the new order")
@MainActor
struct ForEachReorderTests {

    @Test func anIdentifiedForEachReorderedReportsAChange() {
        let graph = AttributeGraph()
        graph.update(from: Identified(items: [alpha, beta, gamma]))
        _ = render(graph, width: 10, height: 3)

        let changed = graph.update(from: Identified(items: [gamma, alpha, beta]))
        #expect(changed)
        #expect(render(graph, width: 10, height: 3) == ["gamma", "alpha", "beta"])
    }

    @Test func aKeyPathForEachReorderedReportsAChange() {
        let graph = AttributeGraph()
        graph.update(from: KeyPathed(words: ["one", "two", "three"]))
        _ = render(graph, width: 10, height: 3)

        let changed = graph.update(from: KeyPathed(words: ["three", "two", "one"]))
        #expect(changed)
        #expect(render(graph, width: 10, height: 3) == ["three", "two", "one"])
    }

    @Test func aForEachInTheSameOrderReportsNoChange() {
        let graph = AttributeGraph()
        graph.update(from: Identified(items: [alpha, beta, gamma]))

        let changed = graph.update(from: Identified(items: [alpha, beta, gamma]))
        #expect(!changed)
    }

    @Test func aReorderReMeasuresTheStackHoldingTheRows() {
        let wide = Item(id: 1, text: "abcd")
        let tall = Item(id: 2, text: "x\ny")
        let graph = AttributeGraph()
        graph.update(from: Strip(items: [wide, tall]))
        #expect(render(graph, width: 4, height: 3) == ["abcd", "end", ""])

        graph.update(from: Strip(items: [tall, wide]))
        #expect(render(graph, width: 4, height: 3) == ["xabc", "yd", "end"])
    }

    @Test func soDoesAReorderOfObservedStateDrainedInPlace() {
        let shelf = Shelf([Item(id: 1, text: "abcd"), Item(id: 2, text: "x\ny")])
        let graph = AttributeGraph()
        graph.update(from: ObservedStrip(shelf: shelf))
        #expect(render(graph, width: 4, height: 3) == ["abcd", "end", ""])

        shelf.items.reverse()
        graph.drain()
        #expect(render(graph, width: 4, height: 3) == ["xabc", "yd", "end"])
    }

    @Test func aListsRowsReorderedDrawInTheNewOrder() {
        let graph = AttributeGraph()
        graph.update(from: List([alpha, beta, gamma], visibleCount: 3) { Text($0.text) })
        _ = render(graph, width: 10, height: 3)

        graph.update(from: List([beta, gamma, alpha], visibleCount: 3) { Text($0.text) })
        #expect(render(graph, width: 10, height: 3) == ["  beta", "  gamma", "  alpha"])
    }
}
