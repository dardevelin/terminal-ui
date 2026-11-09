import TerminalUI
import TerminalUIConfig

/// A recording as an asciicast v2 file
/// (https://docs.asciinema.org/manual/asciicast/v2/): a header line, then
/// one `[time, code, data]` event a line, which asciinema plays as a
/// terminal session.
///
/// The output events are the bytes the framework itself sends a terminal:
/// the first frame the alternate screen with the cursor hidden, the app's
/// window background (OSC 11) and a full render; every later one
/// ``CellBuffer/renderDiff(from:into:)`` from the frame shown before it. A
/// player therefore draws each frame exactly as the runtime would have.
/// Marks are `m` events and a change of size an `r` event. Times are the
/// presentation clock's, written from integer microseconds, so the same
/// log gives the same bytes on every system.
package struct CastEncoder: Sendable {
    package var palette: RecordingPalette

    package init(palette: RecordingPalette) {
        self.palette = palette
    }

    /// The file for `timeline`'s frames of `reader`, newline-terminated.
    package func encode(_ reader: RecordingReader, timeline: PresentationTimeline) -> String {
        guard !timeline.frames.isEmpty else { return "" }
        var events: [(time: Int, line: String)] = []
        var header = ""
        var previous: (buffer: CellBuffer, windowBackground: Color?)?
        var pending = timeline.frames[...]
        for screen in reader.screens {
            guard let next = pending.first else { break }
            guard screen.index == next.frame else { continue }
            pending.removeFirst()
            let buffer = screen.buffer
            let windowBackground = screen.windowBackground
            // A full render for the first frame and after a resize.
            var output = OutputBuffer()
            buffer.renderDiff(from: previous?.buffer, into: &output)
            let cells = String(decoding: output.writtenBytes, as: UTF8.self)
            let data: String
            if let previous {
                if previous.buffer.width != buffer.width || previous.buffer.height != buffer.height {
                    events.append((next.time, event(next.time, CastCode.resize,
                                                    "\(buffer.width)x\(buffer.height)")))
                }
                // After the cells, as the runtime sends it.
                data = cells + (windowBackground == previous.windowBackground
                                ? "" : Terminal.windowBackgroundSequence(windowBackground))
            } else {
                header = headerLine(reader.header, width: buffer.width, height: buffer.height,
                                    windowBackground: windowBackground)
                data = Terminal.alternateScreenEntry.description
                    + (windowBackground.map(Terminal.windowBackgroundSequence) ?? "") + cells
            }
            events.append((next.time, event(next.time, CastCode.output, data)))
            previous = (buffer, windowBackground)
        }
        // A mark goes after a frame shown at its instant: a player that
        // pauses at markers pauses on the screen the mark names.
        var lines: [String] = [header]
        var marks = timeline.marks[...]
        for frameEvent in events {
            while let mark = marks.first, mark.time < frameEvent.time {
                lines.append(event(mark.time, CastCode.marker, mark.label))
                marks.removeFirst()
            }
            lines.append(frameEvent.line)
        }
        lines += marks.map { event($0.time, CastCode.marker, $0.label) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `{"version":2,"width":…,"height":…,"title":…,"env":{"TERM":…},"theme":{…}}`;
    /// no timestamp, so a render is the same file whenever it is made.
    private func headerLine(_ header: RecordingHeader, width: Int, height: Int, windowBackground: Color?) -> String {
        var line = "{\"version\":\(CastFormat.version),\"width\":\(width),\"height\":\(height)"
            + ",\"title\":\(RecordingLog.jsonString(header.app))"
        if let term = header.environment.last(where: { $0.name == CastFormat.termVariable }) {
            line += ",\"env\":{\(RecordingLog.jsonString(term.name)):\(RecordingLog.jsonString(term.value))}"
        }
        let background = palette.defaultBackground(windowBackground: windowBackground)
        let ansi = palette.ansi.map(\.hexString).joined(separator: CastFormat.paletteSeparator)
        line += ",\"theme\":{\"fg\":\(RecordingLog.jsonString(palette.foreground.hexString))"
            + ",\"bg\":\(RecordingLog.jsonString(background.hexString))"
            + ",\"palette\":\(RecordingLog.jsonString(ansi))}}"
        return line
    }

    private func event(_ milliseconds: Int, _ code: String, _ data: String) -> String {
        "[\(Self.seconds(microseconds: milliseconds * TimeUnit.microsecondsPerMillisecond))"
            + ",\(RecordingLog.jsonString(code)),\(RecordingLog.jsonString(data))]"
    }

    /// Seconds with six decimals — `1.250000` — written from integer
    /// microseconds, so no float formatting decides the digits.
    package static func seconds(microseconds: Int) -> String {
        let fraction = String(microseconds % TimeUnit.microsecondsPerSecond)
        return "\(microseconds / TimeUnit.microsecondsPerSecond)."
            + String(repeating: "0", count: CastFormat.fractionDigits - fraction.count) + fraction
    }
}

/// asciicast v2's event codes.
private enum CastCode {
    static let output = "o"
    static let marker = "m"
    static let resize = "r"
}

private enum CastFormat {
    static let version = 2
    static let termVariable = "TERM"
    /// The theme's 16 colours are one string, separated by colons.
    static let paletteSeparator = ":"
    /// Microsecond precision.
    static let fractionDigits = 6
}
