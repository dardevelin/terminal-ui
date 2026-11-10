import Testing
@testable import TerminalUI

// SwiftUI's rule, down the vertical axis: a stack holding a view that takes
// the height it is offered takes it too. A size-driven List under a heading,
// in a VStack nested in another — a side panel's, a sheet's — was measured
// with its stack, as content, and drew no rows.

private struct Item: Identifiable { let id: Int }

/// A heading over a list, as a panel's own view.
private struct Panel: TerminalView {
    var body: some TerminalView {
        VStack(spacing: 0) {
            Text("head")
            List((0..<3).map(Item.init)) { item in Text("row \(item.id)") }
        }
    }
}

@Suite("A stack takes the height a child would")
@MainActor
struct NestedStackHeightTests {
    private let expected = ["head", "  row 0", "  row 1", "  row 2", "", ""]

    @Test func aListInAStackInAStackGetsItsRows() {
        let nested = renderedBuffer(VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("head")
                List((0..<3).map(Item.init)) { item in Text("row \(item.id)") }
            }
        }, width: 20, height: 6)
        #expect(nested.rowTexts == expected)
    }

    @Test func aListInAViewWhoseBodyIsAStackGetsItsRows() {
        #expect(renderedBuffer(VStack(spacing: 0) { Panel() }, width: 20, height: 6).rowTexts == expected)
    }

    @Test func aStackWithASpacerPushesWhatFollowsItsParentToTheEnd() {
        let rows = renderedBuffer(VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("top")
                Spacer()
            }
            Text("bottom")
        }, width: 10, height: 4).rowTexts
        #expect(rows == ["top", "", "", "bottom"])
    }

    @Test func aRowWithASpacerStaysOneLineTall() {
        let rows = renderedBuffer(VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("left")
                Spacer()
                Text("right")
            }
            Text("below")
            Spacer()
        }, width: 12, height: 4).rowTexts
        #expect(rows == ["left   right", "below", "", ""])
    }
}
