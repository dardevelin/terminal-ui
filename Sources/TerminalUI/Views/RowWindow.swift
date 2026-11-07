/// Which rows of a scrolling list are drawn, and the `▲`/`▼` lines around
/// them — worked out from the height of each row, so a row may be any number
/// of lines tall.
///
/// The window's budget is in lines, indicators included: a list never draws
/// more than it was given.
struct RowWindow: Equatable, Sendable {
    /// The first row drawn — the list's scroll offset.
    var offset: Int
    /// How many rows are drawn, from `offset`.
    var shown: Int
    /// Whether the `▲ N more` line is drawn above the rows.
    var showsUp: Bool
    /// Whether the `▼ N more` line is drawn below them.
    var showsDown: Bool
    /// The lines the one row drawn is cut to when it is taller than the
    /// window leaves it, drawn from its top; nil when every row is whole.
    var cut: Int?
    /// Rows in the list.
    var total: Int
    /// The window's budget in lines.
    var lines: Int

    /// No rows to draw.
    static func empty(lines: Int) -> RowWindow {
        RowWindow(offset: 0, shown: 0, showsUp: false, showsDown: false, cut: nil, total: 0, lines: lines)
    }

    /// Rows above the window, the count `▲` shows.
    var hiddenAbove: Int { offset }

    /// Rows below the window, the count `▼` shows.
    var hiddenBelow: Int { total - offset - shown }

    /// Whether the last row is drawn. A tiny window can drop `▼` while rows
    /// remain below it, so this is not the same as `!showsDown`.
    var reachesEnd: Bool { offset + shown >= total }

    /// The farthest the wheel may take the offset before the list is drawn
    /// again.
    ///
    /// The heights past this window are not known, so the last offset whose
    /// rows reach the end is not either. Every row is at least one line,
    /// though: rows from an offset below `total - (lines - 1)` cannot all fit
    /// under `▲`, so the wheel may go that far at once, and one row beyond
    /// the window whenever it does not reach the end. With one-line rows the
    /// bound is the last offset exactly, as it always was.
    var wheelLimit: Int {
        guard !reachesEnd else { return offset }
        return max(offset + 1, total - max(1, lines - 1))
    }
}

/// The window walk: given each row's height, which rows a list of `lines`
/// lines draws. Pure — the caller measures, this only counts.
///
/// Rows are placed whole from the offset until the budget runs out, with a
/// line held back for `▼` unless every remaining row fits. A row the window
/// cannot hold whole is drawn from its top and cut off. A window too small
/// for its indicators and a row drops `▼`, then `▲`, before the row.
///
/// Every function asks `height` only for the rows it walks over — the
/// window, and the row on either side of it that stopped the walk — so a
/// list measures O(lines) rows whatever its length.
enum RowWindowing {

    /// The window a list draws this frame.
    ///
    /// - Parameters:
    ///   - offset: The first row the list last drew. One past the last
    ///     offset whose rows reach the end is pulled back to it.
    ///   - selection: The selected row, given only when the selection has
    ///     moved since the window last followed it. Above the window it
    ///     becomes the first row; below, the last.
    ///   - height: The lines row `i` takes at the list's width; anything
    ///     under one counts as one.
    static func window(total: Int, lines: Int, offset: Int, following selection: Int? = nil,
                       height: (Int) -> Int) -> RowWindow {
        let lines = max(1, lines)
        guard total > 0 else { return .empty(lines: lines) }
        var offset = min(max(0, offset), total - 1)
        var window = fit(from: offset, total: total, lines: lines, height: height)
        if offset > 0, window.reachesEnd {
            let last = maxOffset(total: total, lines: lines, height: height)
            if last < offset {
                offset = last
                window = fit(from: offset, total: total, lines: lines, height: height)
            }
        }
        guard let selection else { return window }
        let selected = min(max(0, selection), total - 1)
        if selected < window.offset {
            return fit(from: selected, total: total, lines: lines, height: height)
        }
        if selected >= window.offset + window.shown {
            let first = firstRow(placing: selected, atBottomOf: lines, total: total, height: height)
            return fit(from: first, total: total, lines: lines, height: height)
        }
        return window
    }

    /// The rows drawn from `offset`.
    static func fit(from offset: Int, total: Int, lines: Int, height: (Int) -> Int) -> RowWindow {
        let lines = max(1, lines)
        guard total > 0 else { return .empty(lines: lines) }
        var showsUp = offset > 0
        var room = lines - (showsUp ? 1 : 0)
        if room < 1 {
            showsUp = false
            room = lines
        }
        var used = 0
        var shown = 0
        while offset + shown < total {
            let row = offset + shown
            let heldForDown = row + 1 < total ? 1 : 0
            let rowLines = max(1, height(row))
            guard used + rowLines + heldForDown <= room else { break }
            used += rowLines
            shown += 1
        }
        var showsDown = offset + shown < total
        var cut: Int?
        if shown == 0 {
            shown = 1
            showsDown = offset + 1 < total
            var rowRoom = room - (showsDown ? 1 : 0)
            if rowRoom < 1 {
                showsDown = false
                rowRoom = room
            }
            if max(1, height(offset)) > rowRoom { cut = rowRoom }
        }
        return RowWindow(offset: offset, shown: shown, showsUp: showsUp, showsDown: showsDown,
                         cut: cut, total: total, lines: lines)
    }

    /// The smallest offset whose rows reach the end: the farthest the list
    /// scrolls.
    static func maxOffset(total: Int, lines: Int, height: (Int) -> Int) -> Int {
        guard total > 0 else { return 0 }
        return firstRow(placing: total - 1, atBottomOf: max(1, lines), total: total, height: height)
    }

    /// The offset that draws `row` as the window's last row: walked back from
    /// it under `▲`, with `▼` held back when rows follow it.
    ///
    /// A walk that stops one short of the top, where the first row would fit
    /// in the line `▲` was holding, starts at the top instead and drops `▲`.
    /// Only one row can take the freed line — the walk stopped because the
    /// next row needed more than was left — so that row is the only one
    /// asked about twice.
    private static func firstRow(placing row: Int, atBottomOf lines: Int, total: Int,
                               height: (Int) -> Int) -> Int {
        let heldForDown = row < total - 1 ? 1 : 0
        let room = lines - 1 - heldForDown
        var used = max(1, height(row))
        var first = row
        while first > 0 {
            let above = max(1, height(first - 1))
            guard used + above <= room else {
                if first == 1, used + above <= room + 1 { return 0 }
                return first
            }
            used += above
            first -= 1
        }
        return first
    }
}
