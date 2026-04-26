/// A view that displays line-level diffs between two strings.
/// Supports unified and side-by-side display modes with colored
/// additions/removals and keyboard scrolling.
///
/// Usage:
/// ```
/// // From two strings — computes diff automatically
/// DiffView(original: oldSource, modified: newSource)
///
/// // Side-by-side mode
/// DiffView(original: oldSource, modified: newSource, mode: .sideBySide)
///
/// // From pre-computed diff lines
/// DiffView(lines: diffLines)
///
/// // With file header
/// DiffView(original: old, modified: new)
///     .diffHeader("path/to/file.swift")
/// ```

// MARK: - DiffLine (public model)

/// A single line in a diff result.
public struct DiffLine: Identifiable, Sendable {
    public let id: Int
    public let kind: Kind
    public let text: String
    /// Line number in the original file (nil for additions).
    public let oldLineNumber: Int?
    /// Line number in the modified file (nil for removals).
    public let newLineNumber: Int?

    public enum Kind: Sendable {
        case unchanged
        case added
        case removed
    }

    public init(id: Int, kind: Kind, text: String, oldLineNumber: Int?, newLineNumber: Int?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

// MARK: - DiffMode

/// Display mode for the diff view.
public enum DiffMode: Sendable {
    /// Unified diff — interleaved additions and removals (like `git diff`).
    case unified
    /// Side-by-side — old file on left, new file on right.
    case sideBySide
}

// MARK: - DiffEngine

/// Computes line-level diffs between two strings.
/// Supports two algorithms: Myers (fast for small diffs) and LCS (simple, always correct).
/// Separated from the view so it can be tested independently.
public enum DiffEngine {

    /// Algorithm selection for diff computation.
    public enum Algorithm {
        /// Myers O((N+M)*D) — fast when differences are small (D << N*M).
        /// Based on Eugene Myers' 1986 paper.
        case myers
        /// LCS O(N*M) — simple longest common subsequence. Guaranteed correct,
        /// better for heavily divergent files where D approaches N+M.
        case lcs
    }

    /// Compute diff lines from two multi-line strings.
    public static func diff(original: String, modified: String, algorithm: Algorithm = .myers) -> [DiffLine] {
        let oldLines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = modified.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return diff(oldLines: oldLines, newLines: newLines, algorithm: algorithm)
    }

    /// Compute diff lines from two arrays of strings.
    public static func diff(oldLines: [String], newLines: [String], algorithm: Algorithm = .myers) -> [DiffLine] {
        let edits: [Edit]
        switch algorithm {
        case .myers: edits = myersDiff(old: oldLines, new: newLines)
        case .lcs: edits = lcsDiff(old: oldLines, new: newLines)
        }
        return buildDiffLines(from: edits, old: oldLines, new: newLines)
    }

    // MARK: - Myers Algorithm

    /// Edit operation produced by the Myers algorithm.
    private enum Edit {
        case keep(Int, Int)   // (oldIndex, newIndex)
        case insert(Int)      // newIndex
        case delete(Int)      // oldIndex
    }

    /// Myers diff algorithm — O((N+M)*D) time, O((N+M)*D) space.
    /// D = edit distance (number of insertions + deletions).
    /// Much faster than LCS O(N*M) when differences are small.
    ///
    /// Reference: Eugene W. Myers, "An O(ND) Difference Algorithm and Its Variations", 1986.
    private static func myersDiff(old: [String], new: [String]) -> [Edit] {
        let n = old.count
        let m = new.count

        guard n > 0 || m > 0 else { return [] }

        let maxD = n + m
        let offset = maxD  // index offset so k in [-maxD, maxD] maps to [0, 2*maxD]
        let vSize = 2 * maxD + 1
        var v = Array(repeating: 0, count: vSize)
        var trace: [[Int]] = []

        // Forward pass — find shortest edit path
        var foundD = 0
        outer: for d in 0...maxD {
            // Save V state BEFORE processing this d (for backtracking)
            trace.append(Array(v))

            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    x = v[k + 1 + offset]       // move down (insert from new)
                } else {
                    x = v[k - 1 + offset] + 1   // move right (delete from old)
                }
                var y = x - k

                // Follow diagonal (matching lines)
                while x < n && y < m && old[x] == new[y] {
                    x += 1
                    y += 1
                }

                v[k + offset] = x

                if x >= n && y >= m {
                    foundD = d
                    break outer
                }
            }
        }

        // Backtrack — reconstruct the edit script from the trace
        var x = n
        var y = m
        var edits: [Edit] = []

        for d in stride(from: foundD, through: 1, by: -1) {
            let prevV = trace[d]  // V state saved BEFORE step d was processed
            let k = x - y

            // Determine which diagonal we came from
            let prevK: Int
            if k == -d || (k != d && prevV[k - 1 + offset] < prevV[k + 1 + offset]) {
                prevK = k + 1  // came from above (insert)
            } else {
                prevK = k - 1  // came from left (delete)
            }

            let prevX = prevV[prevK + offset]
            let prevY = prevX - prevK

            // Diagonal moves (matching lines) — walk backwards
            while x > prevX && y > prevY {
                x -= 1
                y -= 1
                edits.append(.keep(x, y))
            }

            // The non-diagonal move
            if x == prevX {
                y -= 1
                edits.append(.insert(y))
            } else {
                x -= 1
                edits.append(.delete(x))
            }
        }

        // Remaining diagonal at d=0 (all matches from the start)
        while x > 0 && y > 0 {
            x -= 1
            y -= 1
            edits.append(.keep(x, y))
        }

        edits.reverse()
        return edits
    }

    /// LCS-based diff — O(N*M) time and space. Simple and always correct.
    /// Better than Myers when differences are large (D approaches N+M).
    private static func lcsDiff(old: [String], new: [String]) -> [Edit] {
        let n = old.count
        let m = new.count

        // Build LCS table
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...max(n, 1) {
            guard i <= n else { break }
            for j in 1...max(m, 1) {
                guard j <= m else { break }
                if old[i - 1] == new[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to produce edit script
        var edits: [Edit] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if old[i - 1] == new[j - 1] {
                edits.append(.keep(i - 1, j - 1))
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                edits.append(.delete(i - 1))
                i -= 1
            } else {
                edits.append(.insert(j - 1))
                j -= 1
            }
        }
        while i > 0 { edits.append(.delete(i - 1)); i -= 1 }
        while j > 0 { edits.append(.insert(j - 1)); j -= 1 }

        edits.reverse()
        return edits
    }

    /// Convert edit operations into DiffLine array with proper line numbers.
    private static func buildDiffLines(from edits: [Edit], old: [String], new: [String]) -> [DiffLine] {
        var lines: [DiffLine] = []
        var lineID = 0

        for edit in edits {
            switch edit {
            case .keep(let oi, let ni):
                lines.append(DiffLine(
                    id: lineID, kind: .unchanged, text: old[oi],
                    oldLineNumber: oi + 1, newLineNumber: ni + 1
                ))
            case .delete(let oi):
                lines.append(DiffLine(
                    id: lineID, kind: .removed, text: old[oi],
                    oldLineNumber: oi + 1, newLineNumber: nil
                ))
            case .insert(let ni):
                lines.append(DiffLine(
                    id: lineID, kind: .added, text: new[ni],
                    oldLineNumber: nil, newLineNumber: ni + 1
                ))
            }
            lineID += 1
        }

        return lines
    }
}

// MARK: - DiffView

/// Displays a line-level diff with colored markers and keyboard scrolling.
public struct DiffView: TerminalView {
    public let lines: [DiffLine]
    public let mode: DiffMode
    public let header: String?
    public let visibleHeight: Int

    @TerminalState private var scrollOffset: Int = 0

    /// Create from two strings — computes diff automatically.
    /// - Note: This runs the Myers diff algorithm on every parent body evaluation.
    ///   For frequently-updating parents, pre-compute with `DiffEngine.diff()` and
    ///   use `init(lines:)` instead.
    public init(original: String, modified: String, mode: DiffMode = .unified, visibleHeight: Int = 40) {
        self.lines = DiffEngine.diff(original: original, modified: modified)
        self.mode = mode
        self.header = nil
        self.visibleHeight = visibleHeight
    }

    /// Create from pre-computed diff lines.
    public init(lines: [DiffLine], mode: DiffMode = .unified, visibleHeight: Int = 40) {
        self.lines = lines
        self.mode = mode
        self.header = nil
        self.visibleHeight = visibleHeight
    }

    /// Internal init used by the diffHeader modifier.
    init(lines: [DiffLine], mode: DiffMode, header: String?, visibleHeight: Int = 40) {
        self.lines = lines
        self.mode = mode
        self.header = header
        self.visibleHeight = visibleHeight
    }

    public var body: some TerminalView {
        let lineNumberWidth = computeLineNumberWidth()

        VStack {
            if let header {
                Text(spans: renderHeader(header))
            }

            switch mode {
            case .unified:
                renderUnified(lineNumberWidth: lineNumberWidth)
            case .sideBySide:
                renderSideBySide(lineNumberWidth: lineNumberWidth)
            }
        }
        .focusable()
        .onKeyPress { [lines, $scrollOffset] event in
            let total = lines.count
            let pageSize = 20

            switch event.key {
            case .up:
                $scrollOffset.set(max(0, $scrollOffset.get() - 1))
                return .handled
            case .down:
                $scrollOffset.set(max(0, min(total - 1, $scrollOffset.get() + 1)))
                return .handled
            case .pageUp:
                $scrollOffset.set(max(0, $scrollOffset.get() - pageSize))
                return .handled
            case .pageDown:
                $scrollOffset.set(max(0, min(total - 1, $scrollOffset.get() + pageSize)))
                return .handled
            case .home:
                $scrollOffset.set(0)
                return .handled
            case .end:
                $scrollOffset.set(max(0, total - 1))
                return .handled
            default:
                return .ignored
            }
        }
    }

    // MARK: - Header Rendering

    private func renderHeader(_ path: String) -> [TextSpan] {
        [
            TextSpan("--- a/", foreground: .gray),
            TextSpan(path, foreground: .white, bold: true),
            TextSpan("\n"),
            TextSpan("+++ b/", foreground: .gray),
            TextSpan(path, foreground: .white, bold: true),
        ]
    }

    // MARK: - Unified Mode

    private func renderUnified(lineNumberWidth: Int) -> Text {
        var spans: [TextSpan] = []
        let visible = lines.dropFirst(scrollOffset).prefix(visibleHeight)

        for (index, line) in visible.enumerated() {
            if index > 0 {
                spans.append(TextSpan("\n"))
            }

            let oldNum = formatLineNumber(line.oldLineNumber, width: lineNumberWidth)
            let newNum = formatLineNumber(line.newLineNumber, width: lineNumberWidth)

            switch line.kind {
            case .unchanged:
                spans.append(TextSpan("\(oldNum) \(newNum)  ", foreground: .gray))
                spans.append(TextSpan(" \(line.text)"))
            case .added:
                spans.append(TextSpan("\(oldNum) \(newNum)  ", foreground: .gray))
                spans.append(TextSpan("+\(line.text)", foreground: .green))
            case .removed:
                spans.append(TextSpan("\(oldNum) \(newNum)  ", foreground: .gray))
                spans.append(TextSpan("-\(line.text)", foreground: .red))
            }
        }

        if spans.isEmpty {
            return Text("(no changes)")
        }

        return Text(spans: spans)
    }

    // MARK: - Side-by-Side Mode

    private func renderSideBySide(lineNumberWidth: Int) -> Text {
        // Build paired lines: match removals with additions where possible
        let pairs = buildSideBySidePairs()
        var spans: [TextSpan] = []
        // Cap iteration at `visibleHeight` so a 5,000-line diff in a
        // 20-row viewport processes 20 pairs per render, not 5,000.
        // The unified path already does this; the side-by-side path
        // had silently fallen out of step.
        let visible = pairs.dropFirst(scrollOffset).prefix(visibleHeight)

        for (index, pair) in visible.enumerated() {
            if index > 0 {
                spans.append(TextSpan("\n"))
            }

            // Left side (original)
            let leftNum = formatLineNumber(pair.leftLineNumber, width: lineNumberWidth)
            spans.append(TextSpan("\(leftNum) ", foreground: .gray))

            switch pair.leftKind {
            case .unchanged:
                spans.append(TextSpan(" \(pair.leftText)"))
            case .removed:
                spans.append(TextSpan("-\(pair.leftText)", foreground: .red))
            case .added:
                spans.append(TextSpan("+\(pair.leftText)", foreground: .green))
            case .empty:
                spans.append(TextSpan(" "))
            }

            // Separator
            spans.append(TextSpan(" \u{2502} ", foreground: .gray))

            // Right side (modified)
            let rightNum = formatLineNumber(pair.rightLineNumber, width: lineNumberWidth)
            spans.append(TextSpan("\(rightNum) ", foreground: .gray))

            switch pair.rightKind {
            case .unchanged:
                spans.append(TextSpan(" \(pair.rightText)"))
            case .added:
                spans.append(TextSpan("+\(pair.rightText)", foreground: .green))
            case .removed:
                spans.append(TextSpan("-\(pair.rightText)", foreground: .red))
            case .empty:
                spans.append(TextSpan(" "))
            }
        }

        if spans.isEmpty {
            return Text("(no changes)")
        }

        return Text(spans: spans)
    }

    // MARK: - Side-by-Side Pairing

    /// A paired row for side-by-side display.
    private struct SideBySidePair {
        let leftText: String
        let leftLineNumber: Int?
        let leftKind: SideKind
        let rightText: String
        let rightLineNumber: Int?
        let rightKind: SideKind

        enum SideKind {
            case unchanged
            case added
            case removed
            case empty
        }
    }

    /// Build paired rows from diff lines.
    /// Consecutive removals and additions are aligned side by side.
    /// Unpaired removals show empty right side, unpaired additions show empty left side.
    private func buildSideBySidePairs() -> [SideBySidePair] {
        var pairs: [SideBySidePair] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            switch line.kind {
            case .unchanged:
                pairs.append(SideBySidePair(
                    leftText: line.text, leftLineNumber: line.oldLineNumber,
                    leftKind: .unchanged,
                    rightText: line.text, rightLineNumber: line.newLineNumber,
                    rightKind: .unchanged
                ))
                i += 1

            case .removed:
                // Collect consecutive removals
                var removals: [DiffLine] = []
                while i < lines.count && lines[i].kind == .removed {
                    removals.append(lines[i])
                    i += 1
                }
                // Collect consecutive additions that follow
                var additions: [DiffLine] = []
                while i < lines.count && lines[i].kind == .added {
                    additions.append(lines[i])
                    i += 1
                }
                // Pair them up
                let pairCount = max(removals.count, additions.count)
                for j in 0..<pairCount {
                    let hasLeft = j < removals.count
                    let hasRight = j < additions.count
                    pairs.append(SideBySidePair(
                        leftText: hasLeft ? removals[j].text : "",
                        leftLineNumber: hasLeft ? removals[j].oldLineNumber : nil,
                        leftKind: hasLeft ? .removed : .empty,
                        rightText: hasRight ? additions[j].text : "",
                        rightLineNumber: hasRight ? additions[j].newLineNumber : nil,
                        rightKind: hasRight ? .added : .empty
                    ))
                }

            case .added:
                // Standalone addition (not preceded by removal)
                pairs.append(SideBySidePair(
                    leftText: "", leftLineNumber: nil,
                    leftKind: .empty,
                    rightText: line.text, rightLineNumber: line.newLineNumber,
                    rightKind: .added
                ))
                i += 1
            }
        }

        return pairs
    }

    // MARK: - Helpers

    /// Width needed for the largest line number in the diff.
    private func computeLineNumberWidth() -> Int {
        var maxNum = 1
        for line in lines {
            if let n = line.oldLineNumber { maxNum = max(maxNum, n) }
            if let n = line.newLineNumber { maxNum = max(maxNum, n) }
        }
        return digitCount(maxNum)
    }

    /// Format a line number right-aligned to the given width, or spaces if nil.
    private func formatLineNumber(_ number: Int?, width: Int) -> String {
        guard let number else {
            return String(repeating: " ", count: width)
        }
        let numStr = String(number)
        let padding = max(0, width - numStr.count)
        return String(repeating: " ", count: padding) + numStr
    }

    /// Count decimal digits in a positive integer without allocation.
    private func digitCount(_ n: Int) -> Int {
        guard n > 0 else { return 1 }
        var count = 0
        var value = n
        while value > 0 {
            count += 1
            value /= 10
        }
        return count
    }
}

// MARK: - DiffHeader modifier

extension DiffView {
    /// Add a file path header above the diff.
    public func diffHeader(_ path: String) -> DiffView {
        DiffView(lines: self.lines, mode: self.mode, header: path, visibleHeight: self.visibleHeight)
    }

    /// Test-only window-size probe. Builds the side-by-side pair list
    /// for `lines`, applies `scrollOffset` + `visibleHeight`, and
    /// returns the number of pairs the renderer would actually iterate.
    /// Pinning `<= visibleHeight` keeps the side-by-side path from
    /// silently regressing the way it had before HYP-117.
    func _sideBySideVisiblePairCountForTesting(scrollOffset: Int) -> Int {
        let pairs = buildSideBySidePairs()
        return pairs.dropFirst(scrollOffset).prefix(visibleHeight).count
    }
}
