import TerminalUI
import TerminalUIConfig
import TerminalUIRaster

/// A recording's timeline as an animated GIF (GIF89a), each frame drawn by
/// a ``RasterFrameComposer``.
///
/// - Frames show for the timeline's ``PresentationTimeline/gifDelays()``,
///   and the last for ``loopPause`` more, before the animation loops
///   forever (the NETSCAPE2.0 extension).
/// - Each frame after the first is the rectangle of pixels that changed,
///   its unchanged pixels transparent, left in place for the next to draw
///   over (disposal 1); a frame that changes nothing adds its time to the
///   one before.
/// - Colours come from ``IndexedPaletteBuilder``: one global table when
///   every frame's exact colours fit it together, else a local table for
///   each frame's rectangle, one entry of either kept for transparency.
///
/// Every frame is drawn twice — once to count its pixels for the tables,
/// once to encode — so no more than two screens of pixels are ever held.
package struct RasterAnimator {
    package let composer: RasterFrameComposer
    /// Milliseconds the last frame shows for beyond its own time, so a
    /// viewer sees the end before the animation starts again.
    package var loopPause: Int

    package static let defaultLoopPause = 1_500
    /// The table holds 256 entries (GIF89a §19), one of them transparent.
    static let tableCapacity = IndexedImage.maximumPaletteCount - 1
    /// The NETSCAPE2.0 loop count that means forever.
    static let loopForever = 0
    /// §23 stores a delay in 16 bits.
    static let longestDelay = Int(UInt16.max)

    package init(composer: RasterFrameComposer, loopPause: Int = defaultLoopPause) {
        precondition(loopPause >= 0, "a loop pause is not negative")
        self.composer = composer
        self.loopPause = loopPause
    }

    /// `timeline`'s frames of `reader` as a GIF file.
    package func animate(_ reader: RecordingReader, timeline: PresentationTimeline) throws(RecordingLogError) -> RasterPicture {
        var delays = timeline.gifDelays()
        guard !delays.isEmpty else { throw RecordingLogError("the timeline shows no frame") }
        delays[delays.count - 1].centiseconds += (loopPause + TimeUnit.millisecondsPerCentisecond / 2)
            / TimeUnit.millisecondsPerCentisecond
        let screens = Self.screens(of: reader, at: Set(delays.map(\.frame)))
            .mapValues { (buffer: $0.buffer, windowBackground: $0.windowBackground) }
        let columns = screens.values.map(\.buffer.width).max() ?? 0
        let rows = screens.values.map(\.buffer.height).max() ?? 0
        let (width, height) = composer.size(columns: columns, rows: rows)
        var missing = MissingGlyphs()

        func frames(_ body: (_ index: Int, _ frame: RasterFrame, _ previous: BlendCanvas?) -> Void) {
            var previous: BlendCanvas?
            for (index, delay) in delays.enumerated() {
                guard let screen = screens[delay.frame] else { continue }
                let frame = composer.compose(screen.buffer, windowBackground: screen.windowBackground,
                                             columns: columns, rows: rows)
                body(index, frame, previous)
                previous = frame.canvas
            }
        }

        var global = IndexedPaletteBuilder()
        frames { _, frame, previous in
            guard let rectangle = Self.changedRectangle(frame.canvas, previous) else { return }
            frame.canvas.forEachRun(in: rectangle, since: previous) { pixel, count in
                if let pixel { global.add(pixel, count: count) }
            }
        }
        let globalPalette = global.exactColours.count <= Self.tableCapacity
            ? global.build(capacity: Self.tableCapacity, reservingTransparency: true, coordinates: Self.oklab) : nil

        var writer = GIFWriter(width: width, height: height, globalPalette: globalPalette?.colours,
                               loopCount: Self.loopForever)
        var pending: GIFFrame?
        var approximated: [(frame: Int, colours: Int, pixels: Int)] = []
        var frameCount = 0
        frames { index, frame, previous in
            let canvas = frame.canvas
            let number = reader.frames[delays[index].frame].number
            for character in frame.missing { missing.add(character, frame: number) }
            guard let rectangle = Self.changedRectangle(canvas, previous) else {
                pending?.delayCentiseconds += delays[index].centiseconds
                return
            }
            let palette: IndexedPalette
            if let globalPalette {
                palette = globalPalette
            } else {
                var local = IndexedPaletteBuilder()
                canvas.forEachRun(in: rectangle, since: previous) { pixel, count in
                    if let pixel { local.add(pixel, count: count) }
                }
                palette = local.build(capacity: Self.tableCapacity, reservingTransparency: true, coordinates: Self.oklab)
                if !palette.approximations.isEmpty {
                    approximated.append((number, palette.approximations.count, palette.approximations.map(\.pixels).reduce(0, +)))
                }
            }
            if let ready = pending { writer.append(Self.clamped(ready)) }
            var indices: [UInt8] = []
            indices.reserveCapacity(rectangle.width * rectangle.height)
            canvas.forEachRun(in: rectangle, since: previous) { pixel, count in
                let index = pixel.map(palette.index(of:)) ?? palette.transparentIndex ?? 0
                indices.append(contentsOf: repeatElement(index, count: count))
            }
            pending = GIFFrame(left: rectangle.x, top: rectangle.y, width: rectangle.width, height: rectangle.height,
                               indices: indices, localPalette: globalPalette == nil ? palette.colours : nil,
                               delayCentiseconds: delays[index].centiseconds, disposal: .keep,
                               transparentIndex: palette.transparentIndex)
            frameCount += 1
        }
        if let ready = pending { writer.append(Self.clamped(ready)) }

        let warnings = approximated.isEmpty ? [] : [
            "the GIF's colour tables could not hold every colour: "
                + approximated.map { "frame \($0.frame) drew \($0.colours) colours (\($0.pixels) pixels) as their nearest" }
                .joined(separator: "; "),
        ]
        return RasterPicture(bytes: writer.finish(), width: width, height: height, frames: frameCount,
                             missing: missing, warnings: warnings)
    }

    // MARK: - Frames

    /// The screens after the frames at `indices`, read in one pass.
    static func screens(of reader: RecordingReader, at indices: Set<Int>) -> [Int: RecordingReader.Screen] {
        var screens: [Int: RecordingReader.Screen] = [:]
        guard let last = indices.max() else { return screens }
        for screen in reader.screens {
            if indices.contains(screen.index) { screens[screen.index] = screen }
            if screen.index >= last { break }
        }
        return screens
    }

    /// The rectangle a frame draws: the whole canvas when there is no
    /// previous frame, else the pixels that changed; nil when none did.
    static func changedRectangle(_ canvas: BlendCanvas, _ previous: BlendCanvas?) -> PixelRectangle? {
        guard let previous else { return PixelRectangle(x: 0, y: 0, width: canvas.width, height: canvas.height) }
        return canvas.changedRectangle(since: previous)
    }

    private static func clamped(_ frame: GIFFrame) -> GIFFrame {
        var frame = frame
        frame.delayCentiseconds = min(frame.delayCentiseconds, longestDelay)
        return frame
    }

    // MARK: - Colour distance

    /// A colour's place in Oklab, the framework's own transform, in
    /// millionths: whole numbers, so the nearest colour is chosen by integer
    /// comparison, and a last-place difference between two systems' maths
    /// libraries moves a coordinate only across a rounding edge.
    static func oklab(_ colour: RGBA) -> (Int, Int, Int) {
        let (lightness, greenRed, blueYellow) = Color.oklab(red: colour.red, green: colour.green, blue: colour.blue)
        func fixed(_ value: Double) -> Int { Int((value * oklabScale).rounded()) }
        return (fixed(lightness), fixed(greenRed), fixed(blueYellow))
    }

    static let oklabScale = 1_000_000.0
}
