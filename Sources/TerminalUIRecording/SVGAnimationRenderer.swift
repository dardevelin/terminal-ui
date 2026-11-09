import TerminalUI

/// A recording as one SVG that plays its frames, by CSS alone (CSS
/// Animations Level 1), so it animates as a top-level file and inside an
/// `<img>`, where scripts never run.
///
/// The picture is painted in layers, one group a presented frame:
///
/// - the first frame's group draws its whole screen on the canvas;
/// - each later frame's group redraws only the rows that differ from the
///   frame before it, each such row first covered by an opaque rect, the
///   full width of the canvas, in the terminal's background — so whatever
///   earlier groups drew there is hidden, and the groups, painted in
///   document order (SVG 2's rendering order, the painter's model), show
///   exactly the latest frame;
/// - a frame whose window background or size differs from the one before
///   it covers the whole canvas and draws every row.
///
/// Each later group is hidden until its time and visible from then to the
/// end of the loop: `@keyframes kN { 0% { visibility: hidden } P% {
/// visibility: visible } }` played by `animation: kN <total>ms step-end
/// infinite`, so it switches exactly at `P%` (`step-end`, CSS Easing
/// Functions Level 1 §2.3) and every group returns to hidden together when
/// the loop starts again. The loop lasts the timeline and then
/// ``loopPause``, the last frame showing all through it.
///
/// Where nothing animates — a viewer that runs no CSS animations, or one
/// that asks for reduced motion (`prefers-reduced-motion: reduce`, Media
/// Queries Level 5 §12.1), whose rule sets `animation: none` — every group
/// is visible, and by the painter's order the last frame is what shows.
///
/// A row drawn the same in several frames, anywhere on the screen, is
/// drawn once in `<defs>` and placed by `<use>` wherever it recurs. Rows
/// are drawn by ``SVGFrameRenderer``'s own pieces, so a frame of the
/// animation is the still of that frame; the same log gives the same bytes
/// on every system.
package struct SVGAnimationRenderer: Sendable {
    /// Draws each frame's rows, with its metrics, palette, padding and font.
    package var frames: SVGFrameRenderer
    /// Milliseconds the last frame stays before the picture starts over.
    package var loopPause: Int

    package static let defaultLoopPause = 1_500

    package init(frames: SVGFrameRenderer, loopPause: Int = defaultLoopPause) {
        precondition(loopPause >= 0, "a loop pause is not negative")
        self.frames = frames
        self.loopPause = loopPause
    }

    /// The document playing `timeline`'s frames of `reader`, with `title`
    /// as its accessible name.
    package func render(_ reader: RecordingReader, timeline: PresentationTimeline, title: String) -> String {
        let shown = presentedScreens(reader, timeline: timeline)
        guard let first = shown.first, let columns = shown.map(\.buffer.width).max(),
              let rows = shown.map(\.buffer.height).max() else { return "" }
        let layout = frames.layout(columns: columns, rows: rows)
        // Every frame shows by the timeline's end; a loop of no length
        // would leave nothing to divide by.
        let total = max(timeline.duration + loopPause, 1)

        var definitions = RowDefinitions()
        var symbols: Set<UInt32> = []
        var groups = ""
        var animations = ""
        var previous: PaintedFrame?
        for (index, frame) in shown.enumerated() {
            var painted = PaintedFrame(ground: frame.ground, width: frame.buffer.width)
            for y in 0..<frame.buffer.height {
                var row = SVGPainting()
                frames.paintRow(frame.buffer, row: y, top: 0, ground: frame.ground, layout: layout, into: &row)
                symbols.formUnion(row.symbols)
                painted.rows.append(Self.rowBody(row))
            }
            let body = groupBody(painted, after: previous, layout: layout, definitions: &definitions)
            previous = painted

            let id = "\(FrameID.group)\(index)"
            if body.isEmpty {
                groups += "<g id=\"\(id)\"/>\n"
                continue
            }
            groups += "<g id=\"\(id)\">\n" + body + "</g>\n"
            if index > 0 {
                let keyframes = "\(FrameID.keyframes)\(index)"
                animations += "@keyframes \(keyframes){0%{visibility:hidden}"
                    + "\(Self.percentage(frame.time, of: total)){visibility:visible}}\n"
                    + "#\(id){animation:\(keyframes) \(total)ms step-end infinite}\n"
            }
        }

        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(layout.width)\" height=\"\(layout.height)\""
            + " viewBox=\"0 0 \(layout.width) \(layout.height)\" \(frames.fontAttributes)>\n"
        svg += "<title>\(SVGText.escaped(title))</title>\n"
        svg += "<desc>\(SVGText.escaped(Self.description))</desc>\n"
        let fontFaces = frames.embeddedFont?.fontFaceRules ?? ""
        if !fontFaces.isEmpty || !animations.isEmpty {
            svg += "<style>\n" + fontFaces + animations
            if !animations.isEmpty { svg += Self.reducedMotionRule }
            svg += "</style>\n"
        }
        if !symbols.isEmpty || !definitions.text.isEmpty {
            svg += "<defs>\n" + frames.symbols(symbols, layout: layout) + definitions.text + "</defs>\n"
        }
        svg += "<rect width=\"\(layout.width)\" height=\"\(layout.height)\" fill=\"\(first.ground.hexString)\"/>\n"
        return svg + groups + "</svg>\n"
    }

    /// What `<desc>` says: the still's description, and how it plays.
    static let description = SVGFrameRenderer.description + " It plays as an animation; where animation is"
        + " off or motion is reduced, it shows its last frame."

    /// Under reduced motion no group animates, so each is visible and the
    /// last frame shows. `!important` outranks the per-group rules whatever
    /// their specificity (CSS Cascading and Inheritance Level 4, important
    /// declarations).
    static let reducedMotionRule = "@media (prefers-reduced-motion: reduce){g{animation:none!important}}\n"

    private enum FrameID {
        static let group = "f"
        static let keyframes = "k"
        static let row = "r"
    }

    // MARK: - Frames

    private struct Presented {
        var buffer: CellBuffer
        var ground: RGB
        var time: Int
    }

    private func presentedScreens(_ reader: RecordingReader, timeline: PresentationTimeline) -> [Presented] {
        var shown: [Presented] = []
        var pending = timeline.frames[...]
        for screen in reader.screens {
            guard let next = pending.first else { break }
            guard screen.index == next.frame else { continue }
            pending.removeFirst()
            shown.append(Presented(buffer: screen.buffer,
                                   ground: frames.palette.defaultBackground(windowBackground: screen.windowBackground),
                                   time: next.time))
        }
        return shown
    }

    // MARK: - Rows

    /// A frame's rows as their row-local bodies, and what they lie on.
    private struct PaintedFrame {
        var ground: RGB
        var width: Int
        var rows: [String] = []
    }

    /// What a frame's group draws over the frames before it: the rows that
    /// changed, each block of them covered first; or, for the first frame,
    /// which lies on the canvas, and one of another size or ground, which
    /// covers it all, every row.
    private func groupBody(_ frame: PaintedFrame, after previous: PaintedFrame?, layout: SVGLayout,
                           definitions: inout RowDefinitions) -> String {
        guard let previous, previous.ground == frame.ground, previous.width == frame.width,
              previous.rows.count == frame.rows.count else {
            let canvas = previous == nil ? ""
                : cover(x: 0, y: 0, width: layout.width, height: layout.height, colour: frame.ground)
            return canvas + places(Array(frame.rows.indices), of: frame.rows, layout: layout, definitions: &definitions)
        }
        let changed = frame.rows.indices.filter { frame.rows[$0] != previous.rows[$0] }
        let covers = Self.consecutiveRuns(changed).map { run in
            cover(x: 0, y: layout.top(row: run.lowerBound), width: layout.width,
                  height: run.count * layout.cellHeight, colour: frame.ground)
        }.joined()
        return covers + places(changed, of: frame.rows, layout: layout, definitions: &definitions)
    }

    /// The rows of the picture, each drawn once, named in order of first use.
    private struct RowDefinitions {
        var ids: [String: Int] = [:]
        var text = ""

        mutating func id(for body: String) -> String {
            if let index = ids[body] { return "\(FrameID.row)\(index)" }
            let index = ids.count
            ids[body] = index
            text += "<g id=\"\(FrameID.row)\(index)\">\n" + body + "</g>\n"
            return "\(FrameID.row)\(index)"
        }
    }

    /// A row drawn at the top of its own space, a `<use>` placing it: its
    /// backgrounds and underlines without anti-aliased edges, as the still
    /// draws them. Empty for a row of blank cells on the ground.
    private static func rowBody(_ painted: SVGPainting) -> String {
        var body = ""
        if !painted.backgrounds.isEmpty { body += "<g shape-rendering=\"crispEdges\">\n" + painted.backgrounds + "</g>\n" }
        body += painted.text + painted.shapes
        if !painted.underlines.isEmpty { body += "<g shape-rendering=\"crispEdges\">\n" + painted.underlines + "</g>\n" }
        return body
    }

    /// `<use>` of each of `rows` that draws anything, at its row.
    private func places(_ rows: [Int], of bodies: [String], layout: SVGLayout,
                        definitions: inout RowDefinitions) -> String {
        rows.filter { !bodies[$0].isEmpty }.map { y in
            "<use href=\"#\(definitions.id(for: bodies[y]))\" y=\"\(layout.top(row: y))\"/>\n"
        }.joined()
    }

    private func cover(x: Int, y: Int, width: Int, height: Int, colour: RGB) -> String {
        "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(width)\" height=\"\(height)\" fill=\"\(colour.hexString)\""
            + " shape-rendering=\"crispEdges\"/>\n"
    }

    /// Ascending `rows` as runs of consecutive rows, so a block of changed
    /// rows is covered by one rect.
    static func consecutiveRuns(_ rows: [Int]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        for row in rows {
            if let last = runs.last, last.upperBound == row {
                runs[runs.count - 1] = last.lowerBound..<(row + 1)
            } else {
                runs.append(row..<(row + 1))
            }
        }
        return runs
    }

    // MARK: - Timing

    /// `time` as a keyframe selector over a loop of `total` ms: a
    /// percentage (CSS Animations Level 1 §3) to exactly three decimals,
    /// rounded half up from the integers, so each is placed from its own
    /// millisecond and no rounding carries into the next. Never `0%`,
    /// which would show a later frame at the loop's start, nor past
    /// `100%`.
    static func percentage(_ time: Int, of total: Int) -> String {
        let thousandths = min(max((time * Percent.thousandthsInWhole + total / 2) / total, 1),
                              Percent.thousandthsInWhole)
        let fraction = String(thousandths % Percent.thousandthsPerPercent)
        return "\(thousandths / Percent.thousandthsPerPercent)."
            + String(repeating: "0", count: Percent.places - fraction.count) + fraction + "%"
    }

    private enum Percent {
        static let places = 3
        static let thousandthsPerPercent = 1_000
        static let thousandthsInWhole = 100_000
    }
}
