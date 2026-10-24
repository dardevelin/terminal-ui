import Foundation
import TerminalUI

/// A repository's changes, read through `git` as Claude Code's `/diff` reads
/// them: what is not yet committed, and what the last commit changed.
enum Git {
    /// Why a repository's changes could not be read, in words for the panel.
    struct Problem: Error, Equatable {
        let message: String
    }

    /// Both git sources at once, from one call off the cooperative pool.
    struct Snapshot: Equatable, Sendable {
        var uncommitted: [FileChange]
        var lastCommit: [FileChange]
    }

    /// git's well-known hash of the empty tree: a repository with no commit
    /// yet has no HEAD to diff against, and against this everything in it
    /// is an addition.
    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// A file larger than this is listed with its counts left out rather
    /// than read whole into the panel: an untracked build artefact would
    /// otherwise stall every refresh.
    private static let largestUntrackedFile = 256 * 1024

    static func snapshot(of directory: String) -> Result<Snapshot, Problem> {
        Result {
            let hasHead = (try? run(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory)) != nil
            guard (try? run(["rev-parse", "--is-inside-work-tree"], in: directory)) != nil else {
                throw Problem(message: "Not a git repository.")
            }
            let base = hasHead ? "HEAD" : emptyTree
            let tracked = parse(try run(["diff", base, "--no-color", "--no-ext-diff"], in: directory))
            let untracked = try run(["ls-files", "--others", "--exclude-standard", "-z"], in: directory)
                .split(separator: "\0")
                .map { addition(of: String($0), in: directory) }
            let lastCommit = hasHead
                ? parse(try run(["show", "HEAD", "--format=", "--no-color", "--no-ext-diff"], in: directory))
                : []
            return Snapshot(uncommitted: (tracked + untracked).sorted { $0.path < $1.path },
                            lastCommit: lastCommit)
        }
        .mapError { $0 as? Problem ?? Problem(message: "\($0)") }
    }

    /// Splits `git diff` output into its files. The format is git's "diff
    /// --git" extension of the unified format: a header per file, then
    /// hunks headed `@@ -old,count +new,count @@`.
    static func parse(_ diff: String) -> [FileChange] {
        var changes: [FileChange] = []
        var path: String?
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var inHunk = false

        func finish() {
            if let path { changes.append(FileChange(path: path, lines: lines)) }
            path = nil
            lines = []
            inHunk = false
        }

        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                finish()
                // `a/<path> b/<path>`: the new path is the one shown, and a
                // later `+++ b/` line, when there is one, has the same.
                path = line.components(separatedBy: " b/").last
            } else if line.hasPrefix("@@ ") {
                let ranges = line.split(separator: " ")
                oldLine = ranges.count > 1 ? start(of: ranges[1]) : 0
                newLine = ranges.count > 2 ? start(of: ranges[2]) : 0
                inHunk = true
            } else if inHunk, let marker = line.first {
                let text = String(line.dropFirst())
                switch marker {
                case "+":
                    lines.append(DiffLine(id: lines.count, kind: .added, text: text,
                                          oldLineNumber: nil, newLineNumber: newLine))
                    newLine += 1
                case "-":
                    lines.append(DiffLine(id: lines.count, kind: .removed, text: text,
                                          oldLineNumber: oldLine, newLineNumber: nil))
                    oldLine += 1
                case " ":
                    lines.append(DiffLine(id: lines.count, kind: .unchanged, text: text,
                                          oldLineNumber: oldLine, newLineNumber: newLine))
                    oldLine += 1
                    newLine += 1
                // `\ No newline at end of file`, or the next file's header.
                default:
                    break
                }
            }
        }
        finish()
        return changes
    }

    /// `-12,7` or `+3`: the first line of a hunk's range.
    private static func start(of range: Substring) -> Int {
        Int(range.dropFirst().split(separator: ",").first ?? "") ?? 0
    }

    /// A file git does not track yet: every line of it is an addition.
    private static func addition(of path: String, in directory: String) -> FileChange {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= largestUntrackedFile,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return FileChange(path: path, lines: [])
        }
        var body = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if body.last == "" { body.removeLast() }
        let lines = body.enumerated().map { index, text in
            DiffLine(id: index, kind: .added, text: text, oldLineNumber: nil, newLineNumber: index + 1)
        }
        return FileChange(path: path, lines: lines)
    }

    /// Runs `git` in `directory` and returns what it printed, or throws
    /// what it said on failure. It blocks until git exits, so it is called
    /// on a thread of its own (see `CoderState.refreshFromGit`).
    private static func run(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Problem(message: "git could not be run.")
        }
        // Read before waiting: a diff larger than the pipe's buffer would
        // otherwise leave git blocked writing and this blocked waiting.
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Problem(message: String(decoding: said, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: printed, as: UTF8.self)
    }
}
