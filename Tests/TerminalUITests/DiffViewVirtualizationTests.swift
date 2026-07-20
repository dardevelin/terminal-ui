import Testing
@testable import TerminalUI

// `DiffView.renderSideBySide` used to ignore `visibleHeight` and
// iterate every pair from scrollOffset to end-of-diff. For a 5,000-
// line diff in a 20-row viewport, the renderer walked ~5,000 pairs
// per frame, generated 5,000 worth of spans, and let the framework's
// rect clip drop the off-screen output.
//
// This suite pins the contract: the side-by-side renderer must emit
// at most `visibleHeight` pairs per render call. The `visibleHeight`
// parameter has been on the type since v0.6 — the side-by-side path
// was the lone unused-it caller.

@Suite("DiffView — side-by-side virtualization")
@MainActor
struct DiffViewVirtualizationTests {

    @Test("side-by-side rendering caps emitted pair count at visibleHeight")
    func sideBySideCapsAtVisibleHeight() {
        // 200-line diff (every pair is a one-sided change so each contributes
        // one row) in a 10-row viewport. Pre-fix the renderer emitted 200
        // pairs; post-fix the count must be <= visibleHeight.
        let lines = (0..<200).map { i in
            DiffLine(id: i, kind: .added, text: "line \(i)", oldLineNumber: nil, newLineNumber: i)
        }
        let view = DiffView(lines: lines, mode: .sideBySide, visibleHeight: 10)
        let count = view._sideBySideVisiblePairCountForTesting(scrollOffset: 0)
        #expect(count <= 10, "side-by-side renderer must emit at most visibleHeight pairs (got \(count))")
        #expect(count == 10, "with 200 source lines, exactly 10 pairs should fit in a 10-row viewport (got \(count))")
    }

    @Test("scroll offset does not increase emitted pair count")
    func scrollOffsetDoesNotInflate() {
        let lines = (0..<200).map { i in
            DiffLine(id: i, kind: .removed, text: "line \(i)", oldLineNumber: i, newLineNumber: nil)
        }
        let view = DiffView(lines: lines, mode: .sideBySide, visibleHeight: 15)
        // Mid-document scroll: 100..115 worth of pairs fit, total still 200.
        let count = view._sideBySideVisiblePairCountForTesting(scrollOffset: 100)
        #expect(count <= 15, "scroll offset must not break the visibleHeight cap (got \(count))")
    }

    @Test("near end of diff, count clamps to remaining pairs")
    func tailClampsBelowVisibleHeight() {
        let lines = (0..<200).map { i in
            DiffLine(id: i, kind: .added, text: "line \(i)", oldLineNumber: nil, newLineNumber: i)
        }
        let view = DiffView(lines: lines, mode: .sideBySide, visibleHeight: 50)
        // Scroll near the tail — only a handful of pairs remain.
        let count = view._sideBySideVisiblePairCountForTesting(scrollOffset: 195)
        #expect(count <= 50)
        #expect(count <= 5, "only 5 pairs remain after offset 195 in a 200-line diff (got \(count))")
    }
}
