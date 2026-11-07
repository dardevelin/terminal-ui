import Testing
@testable import TerminalUI

// The window walk a list chooses its rows with. A list counted one line per
// row, so a row taller than a line overflowed the height it measured; the
// walk takes each row's height instead. With every row one line tall it must
// choose what the list always chose.

private func uniform(_ lines: Int) -> (Int) -> Int { { _ in lines } }

private func heights(_ rows: [Int]) -> (Int) -> Int { { rows[$0] } }

/// How `List` chose its offset when every row was one line, kept here as the
/// reference the walk is held to.
private func legacyOffset(scrollOffset: Int, selectedIndex: Int, total: Int, visibleCount: Int) -> Int {
    guard total > visibleCount else { return 0 }
    var offset = scrollOffset
    let hasUp = offset > 0
    let hasDown = (offset + visibleCount) < total
    let itemLines = visibleCount - (hasUp ? 1 : 0) - (hasDown ? 1 : 0)
    if selectedIndex > offset + itemLines - 1 {
        let items = visibleCount - 1 - (selectedIndex < total - 1 ? 1 : 0)
        offset = selectedIndex - items + 1
    }
    if selectedIndex < offset {
        offset = selectedIndex
    }
    return max(0, min(total - (visibleCount - 1), offset))
}

@Suite("A window of rows of any height")
struct RowWindowTests {

    // MARK: - One-line rows choose what the list always chose

    @Test func oneLineRowsFollowTheSelectionAsTheListAlwaysDid() {
        for total in 1...14 {
            for lines in 3...7 {
                var legacy = 0
                var walked = 0
                // Down to the end and back to the top, one row at a time, as
                // the arrows move it — then the jumps Home and End make.
                let path = Array(0..<total) + Array((0..<total).reversed()) + [total - 1, 0]
                for selection in path {
                    legacy = legacyOffset(scrollOffset: legacy, selectedIndex: selection,
                                          total: total, visibleCount: lines)
                    walked = RowWindowing.window(total: total, lines: lines, offset: walked,
                                                 following: selection, height: uniform(1)).offset
                    // The one place the old count was wrong: scrolled to
                    // exactly `lines` rows from the end, it drew no `▼` and
                    // left the last row hidden, so the row above it looked
                    // in view. The walk holds a line for `▼` there, and
                    // scrolls one row further to show the selection.
                    let legacyHidLastRow = legacy > 0 && legacy + lines == total && selection == total - 2
                    if legacyHidLastRow {
                        #expect(walked == legacy + 1)
                        legacy = walked
                        continue
                    }
                    #expect(walked == legacy,
                            "\(total) rows in \(lines) lines, selection \(selection): \(walked), was \(legacy)")
                }
            }
        }
    }

    @Test(arguments: [
        // total, lines, offset → shown, ▲, ▼
        (20, 5, 0, 4, false, true),
        (20, 5, 3, 3, true, true),
        (20, 5, 16, 4, true, false),
        (4, 5, 0, 4, false, false),
        (5, 5, 0, 5, false, false),
        (6, 5, 0, 4, false, true),
    ])
    func oneLineRowsDrawTheWindowTheListDrew(total: Int, lines: Int, offset: Int,
                                             shown: Int, up: Bool, down: Bool) {
        let window = RowWindowing.window(total: total, lines: lines, offset: offset, height: uniform(1))
        #expect(window.offset == offset)
        #expect(window.shown == shown)
        #expect(window.showsUp == up)
        #expect(window.showsDown == down)
        #expect(window.cut == nil)
    }

    @Test func oneLineRowsScrollAsFarAsTheyAlwaysDid() {
        for total in 1...14 {
            for lines in 3...7 {
                let legacy = legacyOffset(scrollOffset: 0, selectedIndex: total - 1,
                                          total: total, visibleCount: lines)
                #expect(RowWindowing.maxOffset(total: total, lines: lines, height: uniform(1)) == legacy,
                        "\(total) rows in \(lines) lines")
                let top = RowWindowing.window(total: total, lines: lines, offset: 0, height: uniform(1))
                #expect(top.wheelLimit == (top.reachesEnd ? 0 : legacy),
                        "the wheel should reach the end at once: \(total) rows in \(lines) lines")
            }
        }
    }

    // MARK: - Rows of any height

    @Test func rowsArePlacedWholeWithALineHeldForTheDownIndicator() {
        let window = RowWindowing.window(total: 6, lines: 6, offset: 0, height: heights([2, 3, 1, 4, 1, 1]))
        #expect(window.shown == 2, "2 + 3 lines, and the next row would leave no line for ▼")
        #expect(window.showsDown)
        #expect(window.hiddenBelow == 4)
    }

    @Test func noLineIsHeldWhenEveryRemainingRowFits() {
        let fits = RowWindowing.window(total: 3, lines: 6, offset: 0, height: uniform(2))
        #expect(fits.shown == 3)
        #expect(!fits.showsDown)
        let overflows = RowWindowing.window(total: 4, lines: 6, offset: 0, height: heights([2, 2, 2, 1]))
        #expect(overflows.shown == 2, "seven lines do not fit in six, so ▼ takes one")
        #expect(overflows.showsDown)
        #expect(overflows.hiddenBelow == 2)
    }

    @Test func aSelectionBelowTheWindowBecomesItsLastRow() {
        let threeLines = uniform(3)
        let top = RowWindowing.window(total: 10, lines: 8, offset: 0, height: threeLines)
        #expect(top.shown == 2)
        let followed = RowWindowing.window(total: 10, lines: 8, offset: 0, following: 2, height: threeLines)
        #expect(followed.offset == 1)
        #expect(followed.shown == 2, "▲, rows 1 and 2, ▼: \(followed)")
        #expect(followed.showsUp && followed.showsDown)
        #expect(followed.hiddenAbove == 1)
        #expect(followed.hiddenBelow == 7)
    }

    @Test func aSelectionAboveTheWindowBecomesItsFirstRow() {
        let followed = RowWindowing.window(total: 10, lines: 8, offset: 5, following: 3, height: uniform(3))
        #expect(followed.offset == 3)
        #expect(RowWindowing.window(total: 10, lines: 8, offset: 5, following: 0, height: uniform(3)).showsUp == false)
    }

    @Test func aSelectionInsideTheWindowLeavesItWhereItIs() {
        let window = RowWindowing.window(total: 10, lines: 8, offset: 4, following: 5, height: uniform(3))
        #expect(window.offset == 4)
    }

    @Test func theLastOffsetIsTheFirstWhoseRowsReachTheEnd() {
        let threeLines = uniform(3)
        let last = RowWindowing.maxOffset(total: 10, lines: 8, height: threeLines)
        #expect(last == 8)
        #expect(RowWindowing.fit(from: last, total: 10, lines: 8, height: threeLines).reachesEnd)
        #expect(!RowWindowing.fit(from: last - 1, total: 10, lines: 8, height: threeLines).reachesEnd)
        let end = RowWindowing.window(total: 10, lines: 8, offset: 0, following: 9, height: threeLines)
        #expect(end.offset == last, "selecting the last row scrolls exactly as far")
        #expect(end.shown == 2 && !end.showsDown)
    }

    @Test func anOffsetPastTheLastIsPulledBack() {
        let window = RowWindowing.window(total: 10, lines: 8, offset: 9, height: uniform(3))
        #expect(window.offset == 8)
    }

    @Test func rowsThatAllFitScrollNowhere() {
        // Under ▲ the first row would not fit; with the line ▲ held, it does.
        #expect(RowWindowing.maxOffset(total: 3, lines: 7, height: heights([1, 3, 3])) == 0)
        #expect(RowWindowing.window(total: 3, lines: 7, offset: 1, height: heights([1, 3, 3])).offset == 0)
    }

    @Test func theWheelNeverPassesTheLastOffset() {
        let rows = [1, 3, 2, 1, 4, 1, 1, 2, 3, 1, 1, 2]
        for lines in 1...9 {
            let last = RowWindowing.maxOffset(total: rows.count, lines: lines, height: heights(rows))
            for offset in 0...last {
                let window = RowWindowing.fit(from: offset, total: rows.count, lines: lines, height: heights(rows))
                #expect(window.reachesEnd == (offset == last), "\(lines) lines from \(offset)")
                #expect(window.wheelLimit <= last, "\(lines) lines from \(offset)")
                if !window.reachesEnd { #expect(window.wheelLimit > offset) }
            }
        }
    }

    @Test func aRowTallerThanTheWindowIsCutWithTheDownIndicatorKept() {
        let window = RowWindowing.window(total: 3, lines: 5, offset: 0, height: heights([10, 1, 1]))
        #expect(window.shown == 1)
        #expect(window.cut == 4)
        #expect(window.showsDown)
        #expect(window.hiddenBelow == 2)
        let last = RowWindowing.window(total: 3, lines: 5, offset: 0, following: 2, height: heights([1, 1, 10]))
        #expect(last.offset == 2 && last.cut == 4 && last.showsUp && !last.showsDown, "\(last)")
    }

    @Test func aOneLineWindowDrawsOnlyTheRow() {
        for offset in 0..<3 {
            let window = RowWindowing.window(total: 3, lines: 1, offset: offset, height: uniform(1))
            #expect(window.offset == offset)
            #expect(window.shown == 1 && window.cut == nil)
            #expect(!window.showsUp && !window.showsDown, "from \(offset): \(window)")
        }
        let tall = RowWindowing.window(total: 3, lines: 1, offset: 0, height: uniform(3))
        #expect(tall.cut == 1)
    }

    @Test func aTwoLineWindowDropsTheDownIndicatorBeforeTheUpOne() {
        let middle = RowWindowing.window(total: 5, lines: 2, offset: 2, height: uniform(1))
        #expect(middle.showsUp && !middle.showsDown && middle.shown == 1, "\(middle)")
        #expect(!middle.reachesEnd, "rows remain below though ▼ was dropped")
        let top = RowWindowing.window(total: 5, lines: 2, offset: 0, height: uniform(3))
        #expect(!top.showsUp && top.showsDown && top.cut == 1, "\(top)")
    }

    @Test func theIndicatorsCountRows() {
        let window = RowWindowing.window(total: 12, lines: 7, offset: 4, height: uniform(2))
        #expect(window.shown == 2)
        #expect(window.hiddenAbove == 4)
        #expect(window.hiddenBelow == 6)
    }

    @Test func theWalkAsksOnlyForTheRowsAroundTheWindow() {
        var asked = Set<Int>()
        _ = RowWindowing.window(total: 10_000, lines: 10, offset: 5_000, following: 9_000) { row in
            asked.insert(row)
            return 2
        }
        #expect(asked.count < 30, "asked about \(asked.count) rows")
    }

    @Test func anEmptyListDrawsNothing() {
        let window = RowWindowing.window(total: 0, lines: 5, offset: 3, height: uniform(1))
        #expect(window.shown == 0 && !window.showsUp && !window.showsDown)
    }
}
