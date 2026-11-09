import TerminalUIConfig

/// When each recorded frame shows in a picture made from a recording.
///
/// The app ran on real time — it sleeps and reads `ContinuousClock` — so the
/// log keeps real microseconds, and the picture's own timeline is derived
/// here, in integer milliseconds:
///
/// - ``Mode-swift.enum/script``: the timeline a driver wrote with marks. Mark
///   *i* starts segment *i* at `P_i`, the sum of the segments before it, and
///   the segment lasts `D_i`: the mark's hold, or for a live mark the real
///   span to the next mark (or the end), quantised. In a live segment a frame
///   drawn at `t` shows at `P_i + min(q(t − m_i), D_i)`. A held segment shows
///   the screen as it was at its mark for the whole hold — a driver's dwell
///   does not sleep, so whatever it drew next came a moment later in real
///   time, and shows when the hold ends. Frames drawn before the first mark
///   collapse into it.
/// - ``Mode-swift.enum/draw``: real times, every gap capped at
///   ``drawGapLimit``, for a recording nobody marked.
///
/// In both, of frames that land on one instant only the last is shown.
package struct PresentationClock: Equatable, Sendable {
    package enum Mode: Equatable, Sendable {
        case script
        case draw
    }

    /// Browsers play a GIF frame shorter than 2 cs at about 10 cs, and a
    /// CSS step much under that is not seen; 20 ms keeps every step of a
    /// live segment one a viewer can see.
    package static let minimumQuantum = 20
    package static let defaultQuantum = 40
    /// The longest a `.draw` timeline waits between two moments: an ad-hoc
    /// recording's idle minutes are not worth watching.
    package static let drawGapLimit = 2_000

    package let mode: Mode
    /// Milliseconds a live segment's times are rounded to.
    package let quantum: Int

    package init(mode: Mode, quantum: Int = defaultQuantum) throws(RecordingLogError) {
        guard quantum >= Self.minimumQuantum else {
            throw RecordingLogError("a quantum is at least \(Self.minimumQuantum) ms, not \(quantum) ms")
        }
        self.mode = mode
        self.quantum = quantum
    }

    /// Which part of a recording a picture shows.
    package enum Range: Equatable, Sendable {
        /// All of it.
        case whole
        /// One still: the frame showing when the first mark with this label
        /// was made.
        case at(String)
        /// From the frame showing at one mark to the frame showing at a
        /// later one; the segment the second mark starts is not included.
        case between(from: String, to: String)
    }

    /// The frames `reader` shows over `range`, each at its time in the
    /// picture.
    package func timeline(of reader: RecordingReader,
                          range: Range = .whole) throws(RecordingLogError) -> PresentationTimeline {
        // Every frame placed, those sharing an instant not yet thinned, so a
        // range can still open on a frame that a later one would hide.
        let full = { mode == .script ? scriptTimeline(of: reader) : drawTimeline(of: reader) }
        switch range {
        case .whole:
            return full().lastAtEachInstant()
        case .at(let label):
            let mark = reader.marks[try reader.markIndex(labelled: label)]
            return PresentationTimeline(frames: [.init(frame: mark.currentFrame, time: 0)], marks: [], duration: 0)
        case .between(let fromLabel, let toLabel):
            let fromIndex = try reader.markIndex(labelled: fromLabel)
            let toIndex = try reader.markIndex(labelled: toLabel)
            guard fromIndex <= toIndex else { throw RecordingLogError("the mark \(toLabel) comes before \(fromLabel)") }
            let (from, to, full) = (reader.marks[fromIndex], reader.marks[toIndex], full())
            let start = full.marks[fromIndex].time
            let end = full.marks[toIndex].time
            // The frame showing at `from` opens the range, whenever it was
            // drawn; after it, only frames drawn between the two marks.
            let drawnBetween = (from.currentFrame + 1)..<(to.currentFrame + 1)
            let frames = [PresentationTimeline.Frame(frame: from.currentFrame, time: 0)]
                + full.frames.filter { drawnBetween.contains($0.frame) }
                    .map { .init(frame: $0.frame, time: min(max($0.time - start, 0), end - start)) }
            let marks = full.marks.enumerated()
                .filter { (fromIndex...toIndex).contains($0.offset) }
                .map { PresentationTimeline.Mark(label: $0.element.label, time: $0.element.time - start) }
            return PresentationTimeline(frames: frames, marks: marks, duration: end - start).lastAtEachInstant()
        }
    }

    /// `t` µs rounded to the nearest quantum, as milliseconds; half rounds up.
    package func quantised(microseconds: Int) -> Int {
        let quantumMicroseconds = quantum * TimeUnit.microsecondsPerMillisecond
        return (max(microseconds, 0) + quantumMicroseconds / 2) / quantumMicroseconds * quantum
    }

    // MARK: - Modes

    // Both modes place every frame, and one mark for each of the reader's.

    private func scriptTimeline(of reader: RecordingReader) -> PresentationTimeline {
        // A log nobody marked plays as one live segment from its first frame.
        let segments = reader.marks.isEmpty
            ? [RecordingReader.Mark(time: reader.frames[0].time, label: "", holdMs: nil, framesBefore: 0)]
            : reader.marks
        var starts: [Int] = []
        var durations: [Int] = []
        var position = 0
        for (index, mark) in segments.enumerated() {
            let next = index + 1 < segments.count ? segments[index + 1].time : reader.endTime
            let duration = mark.holdMs ?? quantised(microseconds: next - mark.time)
            starts.append(position)
            durations.append(duration)
            position += duration
        }

        var frames: [PresentationTimeline.Frame] = []
        var segment = -1
        for (index, frame) in reader.frames.enumerated() {
            while segment + 1 < segments.count, segments[segment + 1].framesBefore <= index { segment += 1 }
            let time: Int
            if segment < 0 {
                time = 0
            } else if segments[segment].holdMs != nil {
                time = starts[segment] + durations[segment]
            } else {
                time = starts[segment]
                    + min(quantised(microseconds: frame.time - segments[segment].time), durations[segment])
            }
            frames.append(.init(frame: index, time: time))
        }
        let marks = zip(reader.marks, starts).map { PresentationTimeline.Mark(label: $0.label, time: $1) }
        return PresentationTimeline(frames: frames, marks: marks, duration: position)
    }

    private func drawTimeline(of reader: RecordingReader) -> PresentationTimeline {
        // Every moment the log names, each gap capped; the first frame is 0.
        let origin = reader.frames[0].time
        let moments = Set(reader.frames.map(\.time) + reader.marks.map(\.time) + [reader.endTime])
            .filter { $0 >= origin }.sorted()
        var placed: [Int: Int] = [origin: 0]
        var position = 0
        for (previous, moment) in zip(moments, moments.dropFirst()) {
            position += min(moment - previous, Self.drawGapLimit * TimeUnit.microsecondsPerMillisecond)
            placed[moment] = position
        }
        func milliseconds(_ time: Int) -> Int {
            let microseconds = placed[max(time, origin)] ?? 0
            return (microseconds + TimeUnit.microsecondsPerMillisecond / 2) / TimeUnit.microsecondsPerMillisecond
        }
        let frames = reader.frames.enumerated().map {
            PresentationTimeline.Frame(frame: $0.offset, time: milliseconds($0.element.time))
        }
        let marks = reader.marks.map { PresentationTimeline.Mark(label: $0.label, time: milliseconds($0.time)) }
        return PresentationTimeline(frames: frames, marks: marks, duration: milliseconds(reader.endTime))
    }
}

/// The frames a picture shows, each at its time in milliseconds from the
/// picture's start, and its marks.
package struct PresentationTimeline: Equatable, Sendable {
    package struct Frame: Equatable, Sendable {
        /// The frame's index in ``RecordingReader/frames``.
        package var frame: Int
        package var time: Int

        package init(frame: Int, time: Int) {
            self.frame = frame
            self.time = time
        }
    }

    package struct Mark: Equatable, Sendable {
        package var label: String
        package var time: Int

        package init(label: String, time: Int) {
            self.label = label
            self.time = time
        }
    }

    /// In order of time, at most one at an instant.
    package var frames: [Frame]
    package var marks: [Mark]
    /// How long the picture lasts: its last frame shows until then.
    package var duration: Int

    package init(frames: [Frame], marks: [Mark], duration: Int) {
        self.frames = frames
        self.marks = marks
        self.duration = duration
    }

    /// Only the last of frames that share an instant: the earlier ones
    /// would show for no time at all.
    func lastAtEachInstant() -> PresentationTimeline {
        var kept: [Frame] = []
        for frame in frames {
            if kept.last?.time == frame.time { kept.removeLast() }
            kept.append(frame)
        }
        return PresentationTimeline(frames: kept, marks: marks, duration: duration)
    }
}

// MARK: - GIF delays

/// A frame of a GIF and how long it shows.
package struct GIFFrameDelay: Equatable, Sendable {
    /// The frame's index in ``RecordingReader/frames``.
    package var frame: Int
    package var centiseconds: Int

    package init(frame: Int, centiseconds: Int) {
        self.frame = frame
        self.centiseconds = centiseconds
    }
}

extension PresentationTimeline {
    /// A GIF frame's delay is whole centiseconds (GIF89a §23, Graphic
    /// Control Extension), and browsers play a delay under 2 cs at about
    /// 10 cs (WebKit, Blink and Gecko all clamp it).
    package static let shortestGIFDelay = 2

    /// The timeline as GIF delays. Each frame's start is rounded to the
    /// nearest centisecond and its delay is the distance to the next
    /// rounded start, so rounding never adds up into drift; a frame that
    /// would show under ``shortestGIFDelay`` is merged into the next, which
    /// starts where it would have. The last frame shows until the
    /// timeline's end, and for no less than the shortest delay.
    package func gifDelays() -> [GIFFrameDelay] {
        func centiseconds(_ milliseconds: Int) -> Int {
            (milliseconds + TimeUnit.millisecondsPerCentisecond / 2) / TimeUnit.millisecondsPerCentisecond
        }
        var delays: [GIFFrameDelay] = []
        var mergedStart: Int?
        for (index, frame) in frames.enumerated() {
            let start = mergedStart ?? centiseconds(frame.time)
            let isLast = index == frames.count - 1
            let end = isLast ? centiseconds(duration) : centiseconds(frames[index + 1].time)
            if !isLast, end - start < Self.shortestGIFDelay {
                mergedStart = start
                continue
            }
            mergedStart = nil
            delays.append(GIFFrameDelay(frame: frame.frame, centiseconds: max(end - start, Self.shortestGIFDelay)))
        }
        return delays
    }
}

// MARK: - Durations

extension PresentationClock {
    /// A duration as a flag spells it — `40ms`, `2s`, `1.5s` — in whole
    /// milliseconds; nil for anything else, or finer than a millisecond.
    package static func milliseconds(parsing text: String) -> Int? {
        let (number, scale): (Substring, Int)
        if text.hasSuffix("ms") {
            (number, scale) = (text.dropLast(2), 1)
        } else if text.hasSuffix("s") {
            (number, scale) = (text.dropLast(), TimeUnit.millisecondsPerSecond)
        } else {
            return nil
        }
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        let isDigits = { (part: Substring) in !part.isEmpty && part.allSatisfy(TimeUnit.decimalDigits.contains) }
        guard (1...2).contains(parts.count), parts.allSatisfy(isDigits), let whole = Int(parts[0]) else { return nil }
        var milliseconds = whole * scale
        if parts.count == 2 {
            // The fraction's digits, as thousandths of the unit: `1.5s`
            // is 1500 ms, and `0.4ms` is no whole number of them.
            let fraction = parts[1]
            let digits = String(scale).count - 1
            guard fraction.count <= digits, let value = Int(fraction) else { return nil }
            var power = 1
            for _ in 0..<(digits - fraction.count) { power *= TimeUnit.decimalRadix }
            milliseconds += value * power
        }
        return milliseconds
    }
}

enum TimeUnit {
    static let microsecondsPerMillisecond = 1_000
    static let microsecondsPerSecond = 1_000_000
    static let millisecondsPerSecond = 1_000
    static let millisecondsPerCentisecond = 10
    static let decimalRadix = 10
    static let decimalDigits: ClosedRange<Character> = "0"..."9"
}
