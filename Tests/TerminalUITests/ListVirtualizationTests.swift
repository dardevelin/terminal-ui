import Testing
@testable import TerminalUI

// `List.renderList` must materialize only the visible window, not
// the whole source. Probe: a counting `RandomAccessCollection` records
// every `subscript(_:)` access and every iterator advance. A 10-row
// viewport over 10,000 items must touch <100 elements — bounded by
// `visibleCount` plus the small overscan the renderer needs for
// indicator math, never tied to total source length.
//
// SwiftUI parity (LazyVStack/LazyVGrid promise): only the visible
// items are materialized. Same promise here.

private final class AccessCounter: @unchecked Sendable {
    var subscriptCount = 0
    var iteratorAdvanceCount = 0
}

private struct CountingItem: Identifiable {
    let id: Int
}

private struct CountingCollection: RandomAccessCollection {
    typealias Element = CountingItem
    typealias Index = Int

    let total: Int
    let counter: AccessCounter

    var startIndex: Int { 0 }
    var endIndex: Int { total }

    subscript(position: Int) -> CountingItem {
        counter.subscriptCount += 1
        return CountingItem(id: position)
    }

    func index(after i: Int) -> Int { i + 1 }
    func index(before i: Int) -> Int { i - 1 }
    func index(_ i: Int, offsetBy distance: Int) -> Int { i + distance }
    func distance(from start: Int, to end: Int) -> Int { end - start }
}

@Suite("List — visible-window virtualization")
@MainActor
struct ListVirtualizationTests {

    @Test("rendering a 10-row viewport over 10,000 items must NOT touch all items")
    func listOnlyMaterializesVisibleWindow() {
        let counter = AccessCounter()
        let data = CountingCollection(total: 10_000, counter: counter)
        let graph = AttributeGraph()
        graph.update(from: List(data, visibleCount: 10) { item in
            Text("\(item.id)")
        })

        #expect(counter.subscriptCount < 100,
                "list rendered with visibleCount=10 should touch <100 items, not all 10,000; got \(counter.subscriptCount)")
    }
}
