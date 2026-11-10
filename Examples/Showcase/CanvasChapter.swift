import Foundation
import TerminalUI

/// The Canvas chapter: one canvas, full screen, redrawn by the timeline
/// every frame — a live chart whose fill is a gradient of half cells under
/// curves stroked in braille, a clock keeping the wall clock's time, and
/// meters easing to new readings on a schedule, all labelled in text.
struct CanvasChapter: TerminalView {
    /// Seconds into the chapter.
    let time: Double
    /// The timeline's date: the clock's time.
    let date: Date
    @TerminalEnvironment(\.theme) var theme

    // MARK: The score

    static let duration = 13.0
    /// The whole chapter, coming out of the ground and going back.
    static let shown = Cue(from: 0.3, to: 12.7)
    static let fade = 0.6
    /// The chart drawn in from the left, its curves rising as they go.
    static let chartReveal = Cue(from: 0.5, to: 2.3)
    /// The clock's hands sweeping round from twelve to the time.
    static let clockReveal = Cue(from: 1.2, to: 2.8)
    /// The meters growing from nothing, one after another.
    static let metersReveal = Cue(from: 2.0, to: 3.2)
    /// The delay between one meter starting to grow and the next.
    static let meterStagger = 0.09

    var body: some TerminalView {
        let theme = theme
        let time = time, date = date
        return Canvas(opaque: true) { context, size in
            context.fill(CanvasRect(x: 0, y: 0, width: size.width, height: size.height),
                         with: .color(theme.background))
            var stage = context
            stage.opacity = Self.shown.presence(at: time, fade: Self.fade)
            let layout = Layout(size)
            SignalChart(theme: theme, time: time).draw(in: stage, frame: layout.chart)
            ClockFace(theme: theme, time: time, date: date).draw(in: stage, frame: layout.clock)
            Meters(theme: theme, time: time).draw(in: stage, frame: layout.meters)
            Self.caption(in: stage, size: size, theme: theme)
        }
    }

    static func caption(in context: GraphicsContext, size: CanvasSize, theme: any Theme) {
        context.draw(Text(spans: [
            "Canvas · TimelineView".fg(theme.accent).bolded(),
            "  fills in half cells · strokes in braille · text in cells".fg(theme.foregroundMuted),
        ]), at: CanvasPoint(x: Layout.margin, y: size.height - 1), anchor: .topLeading)
    }

    /// Where each piece sits: the chart on the left, the clock and the
    /// meters stacked on the right, the caption along the bottom.
    struct Layout {
        static let margin = 2.0
        /// The chart's share of the width.
        static let chartShare = 0.6
        /// The gap between the chart and the right-hand column.
        static let gutter = 4.0
        /// The clock's share of the right-hand column's height.
        static let clockShare = 0.55

        let chart: CanvasRect
        let clock: CanvasRect
        let meters: CanvasRect

        init(_ size: CanvasSize) {
            let top = 1.0, bottom = size.height - 2
            let usable = size.width - 2 * Self.margin
            let chartWidth = (usable * Self.chartShare).rounded()
            chart = CanvasRect(x: Self.margin, y: top, width: chartWidth, height: bottom - top)
            let columnX = Self.margin + chartWidth + Self.gutter
            let columnWidth = size.width - Self.margin - columnX
            let clockHeight = ((bottom - top) * Self.clockShare).rounded()
            clock = CanvasRect(x: columnX, y: top, width: columnWidth, height: clockHeight)
            meters = CanvasRect(x: columnX, y: top + clockHeight + 1, width: columnWidth,
                                height: bottom - top - clockHeight - 1)
        }
    }
}

// MARK: - The chart

/// Two signals traced by a sweep, as a monitor draws them: it writes each
/// reading where it passes and leaves it, and clears a narrow gap ahead of
/// itself as it goes round again. The first signal is a filled area, its
/// gradient of half cells deepening toward the curve; both are stroked in
/// braille over it.
struct SignalChart {
    let theme: any Theme
    let time: Double

    /// Readings a column apart, in the signal's own time.
    static let step = 0.12
    /// Seconds the sweep takes to cross the plot.
    static let sweepSeconds = 5.0
    /// Columns cleared ahead of the sweep.
    static let gap = 3.0
    /// Gridlines across the plot, and their labels' values.
    static let gridValues = [0.25, 0.5, 0.75]
    /// What a reading of 1 reads as.
    static let fullScale = 2000.0
    /// Rows the title and the axis labels take, above and below the plot.
    static let titleRows = 2.0
    static let axisRows = 1.0
    /// Columns the value labels take, left of the plot.
    static let labelColumns = 6.0
    /// How far down from the curve the gradient takes to fade, as a share
    /// of the plot's height, and how faint it starts and ends.
    static let gradientDepth = 0.6
    static let gradientNear = 0.35, gradientFar = 0.92
    /// How thick the curves are, in cells: two dots across the signal's,
    /// one across the trend's.
    static let traceWidth = 1.0, trendWidth = 0.5

    /// The first signal at `moment`, 0 to 1: a few incommensurate swells.
    static func load(_ moment: Double) -> Double {
        0.52 + 0.17 * sin(moment * 0.9) + 0.11 * sin(moment * 2.3 + 1) + 0.05 * sin(moment * 5.3 + 2)
    }

    /// The second: a slower trace, lagging the first.
    static func trend(_ moment: Double) -> Double {
        0.36 + 0.12 * sin(moment * 0.9 - 0.7) + 0.05 * sin(moment * 1.7 + 0.3)
    }

    func draw(in context: GraphicsContext, frame: CanvasRect) {
        let rise = CanvasChapter.chartReveal.eased(at: time)
        let plot = CanvasRect(x: frame.x + Self.labelColumns, y: frame.y + Self.titleRows,
                              width: frame.width - Self.labelColumns,
                              height: frame.height - Self.titleRows - Self.axisRows)
        let width = plot.width
        // Where the sweep is: how many times round, and how far across.
        let swept = max(0, time - CanvasChapter.chartReveal.start) / Self.sweepSeconds * width
        let pass = (swept / width).rounded(.down)
        let head = swept - pass * width

        /// The moment the reading at `column` was taken: on this pass left
        /// of the sweep, on the last one beyond its gap, none in between.
        func moment(_ column: Double) -> Double? {
            if column <= head { return (pass * width + column) * Self.step }
            if pass > 0, column > head + Self.gap { return ((pass - 1) * width + column) * Self.step }
            return nil
        }
        func y(_ value: Double) -> Double { plot.y + plot.height * (1 - value * rise) }

        let columns = Int(width)
        let halfRows = Int(plot.height * 2)
        let surfaces = (0..<columns).map { column in
            moment(Double(column) + 0.5).map { (y(Self.load($0)) - plot.y) * 2 }
        }
        context.fillHalfCells(columns: columns, halfRows: halfRows, at: CanvasPoint(x: plot.x, y: plot.y)) { column, halfRow in
            guard let surface = surfaces[column] else { return nil }
            let depth = Double(halfRow) - surface
            guard depth >= 0 else { return nil }
            let amount = min(1, depth / (Double(halfRows) * Self.gradientDepth))
            return theme.accent.blended(with: theme.background, amount: mix(Self.gradientNear, Self.gradientFar, amount))
        }

        for value in Self.gridValues {
            let row = plot.y + plot.height * (1 - value)
            var line = Path()
            line.move(to: CanvasPoint(x: plot.x, y: row))
            line.addLine(to: CanvasPoint(x: plot.x + width, y: row))
            context.stroke(line, with: .color(theme.foregroundMuted.blended(with: theme.background, amount: 0.5)))
            context.draw(Text(Self.reading(value).fg(theme.foregroundMuted)),
                         at: CanvasPoint(x: plot.x - 1, y: row), anchor: .trailing)
        }

        // The curves, a dot apart, two to a column, broken at the gap.
        var trace = Path(), trend = Path()
        var drawing = false
        for dot in stride(from: 0.0, through: width, by: 0.5) {
            guard let moment = moment(dot) else {
                drawing = false
                continue
            }
            let load = CanvasPoint(x: plot.x + dot, y: y(Self.load(moment)))
            let lag = CanvasPoint(x: plot.x + dot, y: y(Self.trend(moment)))
            if drawing {
                trace.addLine(to: load)
                trend.addLine(to: lag)
            } else {
                trace.move(to: load)
                trend.move(to: lag)
                drawing = true
            }
        }
        context.stroke(trend, with: .color(theme.primary), lineWidth: Self.trendWidth)
        context.stroke(trace, with: .color(theme.info), lineWidth: Self.traceWidth)

        let newest = moment(head) ?? 0
        context.draw(Text(spans: [
            "throughput".fg(theme.foreground).bolded(), "  requests a second".fg(theme.foregroundMuted),
        ]), at: CanvasPoint(x: frame.x, y: frame.y), anchor: .topLeading)
        context.draw(Text(spans: [
            "━ ".fg(theme.info), Self.reading(Self.load(newest) * rise).fg(theme.foreground).bolded(),
            "   ━ ".fg(theme.primary), Self.reading(Self.trend(newest) * rise).fg(theme.foreground).bolded(),
        ]), at: CanvasPoint(x: frame.x + frame.width, y: frame.y), anchor: .topTrailing)
        let axis = plot.y + plot.height + 0.5
        context.draw(Text("0 s".fg(theme.foregroundMuted)), at: CanvasPoint(x: plot.x, y: axis), anchor: .topLeading)
        context.draw(Text("\(Int(Self.sweepSeconds)) s".fg(theme.foregroundMuted)),
                     at: CanvasPoint(x: plot.x + width, y: axis), anchor: .topTrailing)
    }

    static func reading(_ value: Double) -> String {
        String(Int((value * fullScale).rounded()))
    }
}

// MARK: - The clock

/// A clock face showing the wall clock's time: its rim and ticks stroked in
/// braille on a face of half cells, the second hand sweeping, and the time
/// in text below.
struct ClockFace {
    let theme: any Theme
    let time: Double
    let date: Date

    static let ticks = 60
    /// Every this many ticks, an hour's mark: longer, and brighter.
    static let hourTick = 5
    /// The hands' lengths, as shares of the face's radius.
    static let hourHand = 0.5, minuteHand = 0.78, secondHand = 0.88
    /// How thick the hour and minute hands are, in cells; the second hand
    /// is the finest line braille draws.
    static let hourHandWidth = 1.0, minuteHandWidth = 0.5
    /// Where the ticks start, as shares of the radius.
    static let tickInner = 0.9, hourTickInner = 0.8
    /// Rows the readout under the face takes.
    static let readoutRows = 2.0

    func draw(in context: GraphicsContext, frame: CanvasRect) {
        let sweep = CanvasChapter.clockReveal.eased(at: time)
        // A row is about two columns tall, so a circle spans twice as many
        // columns as rows.
        let radius = max(1, min((frame.height - Self.readoutRows) / 2, frame.width / 4) - 0.5)
        let centre = CanvasPoint(x: frame.x + frame.width / 2, y: frame.y + radius + 0.5)
        func point(_ turn: Double, _ share: Double) -> CanvasPoint {
            let angle = turn * 2 * .pi
            return CanvasPoint(x: centre.x + sin(angle) * radius * share * 2, y: centre.y - cos(angle) * radius * share)
        }
        let face = CanvasRect(x: centre.x - radius * 2, y: centre.y - radius, width: radius * 4, height: radius * 2)
        context.fill(Path(ellipseIn: face), with: .color(theme.foreground.blended(with: theme.background, amount: 0.93)))
        context.stroke(Path(ellipseIn: face), with: .color(theme.foregroundMuted))
        for tick in 0..<Self.ticks where tick % Self.hourTick == 0 {
            let turn = Double(tick) / Double(Self.ticks)
            var mark = Path()
            mark.move(to: point(turn, Self.hourTickInner))
            mark.addLine(to: point(turn, Self.tickInner))
            context.stroke(mark, with: .color(theme.foreground))
        }

        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1e9
        let minutes = Double(parts.minute ?? 0) + seconds / 60
        let hours = Double((parts.hour ?? 0) % 12) + minutes / 60
        func hand(_ turn: Double, _ length: Double, _ colour: Color, width: Double = 0) {
            var line = Path()
            line.move(to: centre)
            line.addLine(to: point(turn * sweep, length))
            context.stroke(line, with: .color(colour), lineWidth: width)
        }
        hand(hours / 12, Self.hourHand, theme.foreground, width: Self.hourHandWidth)
        hand(minutes / 60, Self.minuteHand, theme.foreground, width: Self.minuteHandWidth)
        hand(seconds / 60, Self.secondHand, theme.primary)

        let readout = String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let below = centre.y + radius + 1
        context.draw(Text(readout.fg(theme.foreground).bolded()), at: CanvasPoint(x: centre.x, y: below), anchor: .top)
    }
}

// MARK: - The meters

/// Eight meters, each easing to a new reading every period: bars of half
/// cells shading from calm to hot as they rise, labelled in text.
struct Meters {
    let theme: any Theme
    let time: Double

    static let count = 8
    /// Seconds between one set of readings and the next.
    static let period = 1.5
    /// Seconds a meter takes to ease from one reading to the next.
    static let easing = 0.8
    static let barWidth = 3.0
    /// Rows the title and the labels take, above and below the bars.
    static let titleRows = 2.0
    static let labelRows = 1.0

    /// Meter `index`'s reading in set `epoch`, 0.15 to 0.95: the same on
    /// every run, by an integer hash (the multipliers are large odd
    /// constants, mixed as in MurmurHash3's finaliser).
    static func reading(_ index: Int, _ epoch: Int) -> Double {
        var hash = UInt64(index &+ 1) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(epoch)) &* 0xC2B2_AE3D_27D4_EB4F
        hash ^= hash >> 33
        hash &*= 0xFF51_AFD7_ED55_8CCD
        hash ^= hash >> 33
        return 0.15 + 0.8 * Double(hash & 0xFFFF) / Double(0xFFFF)
    }

    /// Meter `index`'s level at the chapter's time: growing in as the
    /// chapter opens, then easing from each reading to the next.
    func level(_ index: Int) -> Double {
        let reveal = CanvasChapter.metersReveal
        let start = reveal.start + Double(index) * CanvasChapter.meterStagger
        let grow = Cue(from: start, to: start + reveal.length).eased(at: time, .easeOut)
        let since = max(0, time - reveal.end)
        let epoch = Int(since / Self.period)
        let into = since - Double(epoch) * Self.period
        let moving = Cue(from: 0, to: Self.easing).eased(at: into)
        let previous = Self.reading(index, epoch - 1), next = Self.reading(index, epoch)
        return grow * mix(previous, next, epoch == 0 && into == 0 ? 0 : moving)
    }

    func draw(in context: GraphicsContext, frame: CanvasRect) {
        let levels = (0..<Self.count).map(level)
        let average = levels.reduce(0, +) / Double(Self.count)
        context.draw(Text(spans: [
            "cores".fg(theme.foreground).bolded(), "  load".fg(theme.foregroundMuted),
        ]), at: CanvasPoint(x: frame.x, y: frame.y), anchor: .topLeading)
        context.draw(Text("\(Int((average * 100).rounded()))%".fg(theme.foreground).bolded()),
                     at: CanvasPoint(x: frame.x + frame.width, y: frame.y), anchor: .topTrailing)

        let top = frame.y + Self.titleRows
        let height = frame.height - Self.titleRows - Self.labelRows
        let halfRows = Int(height * 2)
        let gap = max(1, ((frame.width - Self.barWidth * Double(Self.count)) / Double(Self.count - 1)).rounded(.down))
        let span = Self.barWidth * Double(Self.count) + gap * Double(Self.count - 1)
        let left = frame.x + ((frame.width - span) / 2).rounded(.down)
        let calm = theme.success, warm = theme.warning, hot = theme.error
        let track = theme.foreground.blended(with: theme.background, amount: 0.92)
        for (index, level) in levels.enumerated() {
            let x = left + Double(index) * (Self.barWidth + gap)
            let filled = Int((Double(halfRows) * level).rounded())
            context.fillHalfCells(columns: Int(Self.barWidth), halfRows: halfRows, at: CanvasPoint(x: x, y: top)) { _, halfRow in
                let fromBottom = halfRows - halfRow
                guard fromBottom <= filled else { return track }
                let height = Double(fromBottom) / Double(halfRows)
                return height < 0.5 ? calm.blended(with: warm, amount: height * 2)
                    : warm.blended(with: hot, amount: (height - 0.5) * 2)
            }
            context.draw(Text("\(index)".fg(theme.foregroundMuted)),
                         at: CanvasPoint(x: x + Self.barWidth / 2, y: top + height), anchor: .top)
        }
    }
}
