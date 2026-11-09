#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import TerminalUIConfig

// Records the frames the runtime draws into a `.tuirec` log (see
// RecordingLog.swift), from which `swtui` prints a screen and, later,
// renders pictures. Erased in release builds.

#if DEBUG

/// Why a recording could not start or go on.
enum RecordingError: Error, Equatable, CustomStringConvertible {
    /// One is already being written.
    case alreadyRecording
    /// `open(2)` refused the path; `EEXIST` for anything already there.
    case cannotOpen(path: String, errno: Int32)
    /// A write to the log failed, and the recording stopped.
    case writeFailed(path: String, errno: Int32)
    /// A mark or a stop asked of a recorder with no recording open.
    case notRecording

    var description: String {
        switch self {
        case .alreadyRecording:
            "a recording is already being written"
        case .cannotOpen(let path, EEXIST):
            "\(path) already exists, and a recording never writes over anything"
        case .cannotOpen(let path, let code):
            "cannot create \(path): \(String(cString: strerror(code)))"
        case .writeFailed(let path, let code):
            "writing \(path) failed, so the recording stopped: \(String(cString: strerror(code)))"
        case .notRecording:
            "no recording is active"
        }
    }
}

/// Keeps what the runtime draws, frame by frame, in a `.tuirec` log: the
/// first frame whole, then the rows each frame changed, each style declared
/// the first time a cell is drawn in it.
///
/// Owned by the runtime and called on the main actor, where the frame loop
/// and the control socket both run, so it needs no lock. While nothing is
/// being recorded, a drawn frame costs one check of ``isActive``.
@MainActor
final class FrameRecorder {
    /// Lines are kept in memory and written past this, as well as at every
    /// mark and when the recording stops: a frame's delta is a few hundred
    /// bytes, so a write per frame would cost a syscall per frame for nothing.
    static let flushThreshold = 256 * 1024

    /// A recording is open: being written, or waiting for its first frame.
    private(set) var isActive = false
    /// Why the last recording stopped early, if it did.
    private(set) var failure: RecordingError?

    private var path = ""
    private var descriptor: Int32 = -1
    private var appName = ""
    private var writer = RecordingLogWriter()
    /// When the first frame was recorded, which every time is counted from.
    private var origin = ContinuousClock.now
    /// The last frame written, which the next is compared with; nil until
    /// the first, which then carries the header.
    private var lastFrame: CellBuffer?
    private var lastWindowBackground: String?
    private var styleIDs: [StyleKey: Int] = [:]
    private var framesWritten = 0
    private var marksWritten = 0
    /// The mark a start was given, written with the first frame.
    private var startMark: (label: String, holdMs: Int?)?
    /// When the recording ended, in microseconds since its first frame;
    /// nil while it runs.
    private var endTime: Int?
    /// The runtime's number for the last frame recorded: the screen a mark
    /// made now would show.
    private(set) var lastFrameNumber: Int?

    /// How the last recording started stands: the one being written, or
    /// the last one, stopped.
    var info: RecordingInfo {
        let duration = endTime ?? (framesWritten > 0 ? elapsedMicroseconds() : 0)
        return RecordingInfo(path: path.isEmpty ? nil : path, frames: framesWritten, marks: marksWritten,
                             durationMs: duration / Microseconds.perMillisecond, active: isActive)
    }

    /// Starts a recording at `path`, a file it creates readable by its owner
    /// alone. `current` is the screen as it is now — drawn as `frame`, on
    /// `windowBackground` — written as the first frame; nil, before the app
    /// has drawn, makes the first frame drawn the first recorded. A `label`
    /// marks that first frame, at the recording's time 0.
    ///
    /// The file is created with `O_CREAT | O_EXCL | O_NOFOLLOW`: anything
    /// already at `path` — a file, a directory, a FIFO, or a link, even one
    /// that points nowhere — is refused, never opened, followed or replaced.
    func start(path: String, appName: String, current: CellBuffer?,
               windowBackground: Color? = nil, frame: Int = 0,
               label: String? = nil, holdMs: Int? = nil) throws(RecordingError) {
        guard !isActive else { throw .alreadyRecording }
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let descriptor = open(path, flags, FileMode.ownerReadWrite)
        guard descriptor >= 0 else { throw .cannotOpen(path: path, errno: errno) }

        self.path = path
        self.descriptor = descriptor
        self.appName = appName
        writer = RecordingLogWriter()
        lastFrame = nil
        lastWindowBackground = nil
        styleIDs = [:]
        framesWritten = 0
        marksWritten = 0
        startMark = label.map { ($0, holdMs) }
        endTime = nil
        lastFrameNumber = nil
        failure = nil
        isActive = true
        if let current {
            record(current, windowBackground: windowBackground, frame: frame)
        }
    }

    /// The runtime drew `buffer`; called after the frame is flushed. A frame
    /// identical to the last one recorded is not recorded again.
    func frameDrawn(_ buffer: CellBuffer, windowBackground: Color?, frame: Int) {
        guard isActive else { return }
        record(buffer, windowBackground: windowBackground, frame: frame)
    }

    /// Names this moment of the recording; `holdMs` is how long a picture
    /// made from it should show the screen as it is now.
    func mark(label: String, holdMs: Int?) {
        guard isActive, lastFrame != nil else { return }
        writer.write(.mark(time: elapsedMicroseconds(), label: label, holdMs: holdMs))
        marksWritten += 1
        flush()
    }

    /// Ends the recording with an `end` line and closes its file.
    func stop() {
        guard isActive else { return }
        if lastFrame != nil {
            let end = elapsedMicroseconds()
            endTime = end
            writer.write(.end(time: end, frames: framesWritten, marks: marksWritten))
        }
        flush()
        closeFile()
    }

    /// The runtime is quitting — on its own, or because a terminating
    /// signal asked it to: a recording nobody stopped is ended so its log
    /// is whole.
    func finish() {
        stop()
    }

    // MARK: - Frames

    private func record(_ buffer: CellBuffer, windowBackground: Color?, frame: Int) {
        let background = windowBackground?.recordedSpelling
        var lines: [RecordingLine] = []
        let rows: [Int]
        let backgroundChange: String??
        let time: Int
        if let lastFrame {
            time = elapsedMicroseconds()
            if lastFrame.width != buffer.width || lastFrame.height != buffer.height {
                lines.append(.resize(time: time, cols: buffer.width, rows: buffer.height))
                rows = Array(0..<buffer.height)
            } else {
                rows = (0..<buffer.height).filter { !rowIsUnchanged($0, from: lastFrame, to: buffer) }
            }
            backgroundChange = background == lastWindowBackground ? nil : .some(background)
            if rows.isEmpty, backgroundChange == nil { return }
        } else {
            // The log's clock starts at its first frame.
            origin = .now
            time = 0
            lines.append(.header(RecordingHeader(
                cols: buffer.width, rows: buffer.height, cursorVisible: false, app: appName,
                environment: Self.recordedEnvironment())))
            rows = Array(0..<buffer.height)
            // A reader starts from the terminal's own background, so the
            // first frame states one only when the app set its own.
            backgroundChange = background.map { .some($0) }
        }

        let recordedRows = rows.map { recordedRow($0, of: buffer, declaringStylesInto: &lines) }
        lines.append(.frame(RecordedFrame(time: time, number: frame,
                                          windowBackground: backgroundChange, rows: recordedRows)))
        for line in lines { writer.write(line) }
        framesWritten += 1
        lastFrame = buffer
        lastWindowBackground = background
        lastFrameNumber = frame
        if let startMark {
            self.startMark = nil
            writer.write(.mark(time: time, label: startMark.label, holdMs: startMark.holdMs))
            marksWritten += 1
        }
        if writer.bytes.count >= Self.flushThreshold { flush() }
    }

    private func rowIsUnchanged(_ y: Int, from previous: CellBuffer, to buffer: CellBuffer) -> Bool {
        let cells = (y * buffer.width)..<((y + 1) * buffer.width)
        return previous.cells[cells] == buffer.cells[cells]
    }

    private func recordedRow(_ y: Int, of buffer: CellBuffer,
                             declaringStylesInto lines: inout [RecordingLine]) -> RecordedRow {
        let cells = buffer.cells[(y * buffer.width)..<((y + 1) * buffer.width)]
        var styles: [Int] = []
        styles.reserveCapacity(cells.count)
        for cell in cells {
            let key = StyleKey(cell.style)
            if let id = styleIDs[key] {
                styles.append(id)
            } else {
                let id = styleIDs.count
                styleIDs[key] = id
                lines.append(.style(id: id, cell.style.recorded))
                styles.append(id)
            }
        }
        return RecordedRow(index: y, styles: styles, characters: cells.map(\.character))
    }

    /// What decides how the app's colours were meant to look: the
    /// terminal's type and whether it claimed truecolor.
    private static func recordedEnvironment() -> [RecordedVariable] {
        let environment = ProcessInfo.processInfo.environment
        return ["TERM", "COLORTERM"].compactMap { name in
            environment[name].map { RecordedVariable(name: name, value: $0) }
        }
    }

    // MARK: - File

    private func elapsedMicroseconds() -> Int {
        let elapsed = (ContinuousClock.now - origin).components
        return Int(elapsed.seconds) * Microseconds.perSecond
            + Int(elapsed.attoseconds / Microseconds.attosecondsPerMicrosecond)
    }

    private func flush() {
        let bytes = writer.takeBytes()
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                write(descriptor, raw.baseAddress! + offset, raw.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                failure = .writeFailed(path: path, errno: errno)
                closeFile()
                return
            }
            offset += written
        }
    }

    private func closeFile() {
        if endTime == nil, framesWritten > 0 { endTime = elapsedMicroseconds() }
        close(descriptor)
        descriptor = -1
        isActive = false
        lastFrame = nil
    }
}

private enum FileMode {
    /// rw for the owner, nothing for anyone else (`<sys/stat.h>`).
    static let ownerReadWrite: mode_t = 0o600
}

private enum Microseconds {
    static let perSecond = 1_000_000
    static let perMillisecond = 1_000
    static let attosecondsPerMicrosecond: Int64 = 1_000_000_000_000
}

/// A style as a dictionary key, its colours packed into integers so a
/// lookup per cell allocates nothing. `nil` and `.default` pack alike: both
/// are the terminal's own colour, and the log spells both `null`.
private struct StyleKey: Hashable {
    let foreground: UInt32
    let background: UInt32
    let flags: UInt8

    init(_ style: Style) {
        foreground = Self.pack(style.foreground)
        background = Self.pack(style.background)
        flags = (style.bold ? Flag.bold : 0) | (style.italic ? Flag.italic : 0)
            | (style.underline ? Flag.underline : 0)
    }

    private enum Flag {
        static let bold: UInt8 = 1 << 0
        static let italic: UInt8 = 1 << 1
        static let underline: UInt8 = 1 << 2
    }

    /// The top byte says which kind of colour the low three bytes hold.
    private enum Tag {
        static let named: UInt32 = 1 << 24
        static let indexed: UInt32 = 2 << 24
        static let rgb: UInt32 = 3 << 24
    }

    private static func pack(_ color: Color?) -> UInt32 {
        guard let color else { return 0 }
        switch color {
        case .default: return 0
        case .ansi256(let index): return Tag.indexed | UInt32(index)
        case .rgb(let red, let green, let blue):
            return Tag.rgb | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        default:
            return Tag.named | UInt32(Color.recordedNames.firstIndex { $0.color == color } ?? 0)
        }
    }
}

extension Style {
    fileprivate var recorded: RecordedStyle {
        RecordedStyle(foreground: foreground?.recordedSpelling, background: background?.recordedSpelling,
                      bold: bold, italic: italic, underline: underline)
    }
}

#endif
