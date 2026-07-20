import TerminalUI

/// Three hand-curated fixture diffs. The smoke harness exercises
/// the first one (single-file edit, one hunk) — the others are
/// here for manual exploration via the file-tree pane.
enum Fixtures {

    static func defaultFiles() -> [FileChange] {
        return [
            singleFileEdit(),
            multiFileEdit_a(),
            multiFileEdit_b(),
            largeDiff(),
        ]
    }

    /// Fixture #1: a single file with one small hunk. The smoke
    /// baseline — `gitclient.renders` looks for `file_a.swift` and
    /// `@@` from this file.
    private static func singleFileEdit() -> FileChange {
        FileChange(
            id: 1,
            path: "src/file_a.swift",
            status: .modified,
            hunks: [
                HunkDiff.Hunk(
                    oldStart: 10,
                    newStart: 10,
                    lines: [
                        HunkDiff.Line(type: .context, content: "    func greet() {",      oldLineNo: 10, newLineNo: 10),
                        HunkDiff.Line(type: .remove, content: "        print(\"Hi\")",   oldLineNo: 11, newLineNo: nil),
                        HunkDiff.Line(type: .add,   content: "        print(\"Hello\")", oldLineNo: nil, newLineNo: 11),
                        HunkDiff.Line(type: .add,   content: "        print(\"World\")", oldLineNo: nil, newLineNo: 12),
                        HunkDiff.Line(type: .context, content: "    }",                    oldLineNo: 12, newLineNo: 13),
                    ]
                ),
            ]
        )
    }

    /// Fixture #2 (first half): a file with two hunks, exercises
    /// hunk-to-hunk navigation.
    private static func multiFileEdit_a() -> FileChange {
        FileChange(
            id: 2,
            path: "src/file_b.swift",
            status: .modified,
            hunks: [
                HunkDiff.Hunk(
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        HunkDiff.Line(type: .add,   content: "import Foundation",   oldLineNo: nil, newLineNo: 1),
                        HunkDiff.Line(type: .context, content: "import TerminalUI",   oldLineNo: 1,   newLineNo: 2),
                    ]
                ),
                HunkDiff.Hunk(
                    oldStart: 30,
                    newStart: 31,
                    lines: [
                        HunkDiff.Line(type: .context, content: "}",                    oldLineNo: 30, newLineNo: 31),
                        HunkDiff.Line(type: .add,   content: "",                     oldLineNo: nil, newLineNo: 32),
                        HunkDiff.Line(type: .add,   content: "// trailing comment",  oldLineNo: nil, newLineNo: 33),
                    ]
                ),
            ]
        )
    }

    /// Fixture #2 (second half).
    private static func multiFileEdit_b() -> FileChange {
        FileChange(
            id: 3,
            path: "Tests/FileBTests.swift",
            status: .added,
            hunks: [
                HunkDiff.Hunk(
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        HunkDiff.Line(type: .add, content: "import Testing",         oldLineNo: nil, newLineNo: 1),
                        HunkDiff.Line(type: .add, content: "@testable import App",   oldLineNo: nil, newLineNo: 2),
                        HunkDiff.Line(type: .add, content: "",                       oldLineNo: nil, newLineNo: 3),
                        HunkDiff.Line(type: .add, content: "@Suite struct FileBTests {", oldLineNo: nil, newLineNo: 4),
                        HunkDiff.Line(type: .add, content: "    @Test func basic() {", oldLineNo: nil, newLineNo: 5),
                        HunkDiff.Line(type: .add, content: "        #expect(true)",  oldLineNo: nil, newLineNo: 6),
                        HunkDiff.Line(type: .add, content: "    }",                  oldLineNo: nil, newLineNo: 7),
                        HunkDiff.Line(type: .add, content: "}",                      oldLineNo: nil, newLineNo: 8),
                    ]
                ),
            ]
        )
    }

    /// Fixture #3: a large diff with 5+ hunks in one file —
    /// exercises scroll-inside-hunk-view and stretches the cursor /
    /// scroll bookkeeping.
    private static func largeDiff() -> FileChange {
        var hunks: [HunkDiff.Hunk] = []
        for i in 0..<6 {
            let oldStart = 1 + i * 20
            let newStart = 1 + i * 20 + i  // each hunk grows by one line
            hunks.append(
                HunkDiff.Hunk(
                    oldStart: oldStart,
                    newStart: newStart,
                    lines: [
                        HunkDiff.Line(type: .context, content: "func hunk\(i)() {",        oldLineNo: oldStart,       newLineNo: newStart),
                        HunkDiff.Line(type: .remove, content: "    return 0",             oldLineNo: oldStart + 1,   newLineNo: nil),
                        HunkDiff.Line(type: .add,   content: "    return \(i)",          oldLineNo: nil,            newLineNo: newStart + 1),
                        HunkDiff.Line(type: .context, content: "}",                        oldLineNo: oldStart + 2,   newLineNo: newStart + 2),
                    ]
                )
            )
        }
        return FileChange(
            id: 4,
            path: "src/large.swift",
            status: .modified,
            hunks: hunks
        )
    }
}
