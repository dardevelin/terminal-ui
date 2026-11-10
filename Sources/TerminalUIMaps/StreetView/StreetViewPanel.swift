import Foundation
import TerminalUI
import TerminalUIIO

/// A photo drawn in half-blocks, as wide as it is offered and as tall as
/// its proportions make that: a cell is a pixel across and two down, and
/// about twice as tall as it is wide, so a half-block pixel is square. A
/// photo taller than `maximumRows` shows its middle band.
///
/// ```swift
/// StreetPhotoView(photo: street.photo, maximumRows: 18)
/// ```
public struct StreetPhotoView: TerminalView {
    public let photo: ImageBuffer?
    public let maximumRows: Int?

    public init(photo: ImageBuffer?, maximumRows: Int? = nil) {
        self.photo = photo
        self.maximumRows = maximumRows.map { max(1, $0) }
    }

    /// The rows a photo of `width` columns takes.
    static func rows(for photo: ImageBuffer, width: Int) -> Int {
        guard photo.width > 0, width > 0 else { return 0 }
        let pixelRows = Double(width) * Double(photo.height) / Double(photo.width)
        return max(1, Int((pixelRows / Double(PhotoGrid.pixelsPerRow)).rounded()))
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        let photo = photo, maximumRows = maximumRows
        WidthReader { width in
            if let photo {
                let natural = StreetPhotoView.rows(for: photo, width: width)
                let rows = maximumRows.map { min($0, natural) } ?? natural
                let shown = rows < natural ? StreetPhotoView.middleBand(of: photo, share: Double(rows) / Double(natural))
                    : photo
                Canvas(opaque: true) { context, size in
                    StreetPhotoView.draw(shown, in: context, size: size)
                }
                .frame(height: rows)
            }
        }
    }

    /// The middle `share` of a photo's rows.
    static func middleBand(of photo: ImageBuffer, share: Double) -> ImageBuffer {
        let rows = max(1, Int(Double(photo.height) * share))
        let top = (photo.height - rows) / 2
        let rowBytes = photo.width * PhotoGrid.channels
        let band = Array(photo.rgba[(top * rowBytes)..<((top + rows) * rowBytes)])
        return (try? ImageBuffer(rgba: band, width: photo.width, height: rows)) ?? photo
    }

    /// The photo box-filtered to the canvas's half cells and filled into
    /// them, a run of one colour at a time.
    static func draw(_ photo: ImageBuffer, in context: GraphicsContext, size: CanvasSize) {
        let columns = Int(size.width), pixelRows = Int(size.height) * PhotoGrid.pixelsPerRow
        guard columns > 0, pixelRows > 0 else { return }
        let scaled = photo.downsample(toWidth: columns, height: pixelRows)
        let halfRow = 1 / Double(PhotoGrid.pixelsPerRow)
        for y in 0..<pixelRows {
            var runStart = 0
            var runColour: Color?
            func flush(_ end: Int) {
                guard let runColour, end > runStart else { return }
                context.fill(CanvasRect(x: Double(runStart), y: Double(y) * halfRow, width: Double(end - runStart),
                                        height: halfRow), with: .color(runColour))
            }
            for x in 0..<columns {
                let pixel = scaled.pixel(at: x, y)
                let colour = Color.rgb(pixel.r, pixel.g, pixel.b)
                if colour != runColour {
                    flush(x)
                    runStart = x
                    runColour = colour
                }
            }
            flush(columns)
        }
    }

    private enum PhotoGrid {
        /// A half-block cell holds two pixels, one above the other.
        static let pixelsPerRow = 2
        /// `ImageBuffer`'s layout: red, green, blue, alpha.
        static let channels = 4
    }
}

/// Street view as a panel: the photo, where and when it was taken and
/// which way it faces, the keys that step along the street, and the
/// credit and licence its service requires — drawn from a
/// ``StreetViewModel``.
///
/// Its keys, when it has focus: `↑` or `]` the next image, `↓` or `[` the
/// one before, `←` and `→` turn the way a step walks, for imagery whose
/// photos have no sequence.
public struct StreetViewPanel: TerminalView {
    public let model: StreetViewModel
    /// The most rows the photo takes, so its caption and credit stay in
    /// view; a taller photo shows its middle band.
    public let photoRows: Int

    /// Enough for a 16:9 photo across a 64-column panel.
    public static let defaultPhotoRows = 18

    public init(model: StreetViewModel, photoRows: Int = StreetViewPanel.defaultPhotoRows) {
        self.model = model
        self.photoRows = photoRows
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        let theme = theme
        let model = model
        let state = MainActor.assumeIsolated {
            (name: model.imageryName, image: model.image, photo: model.photo, status: model.status,
             hasNext: model.neighbours.next != nil, hasPrevious: model.neighbours.previous != nil,
             bearing: model.walkingBearing)
        }
        VStack(alignment: .leading, spacing: 0) {
            Text("Street view · \(state.name)").bold().foreground(theme.foregroundEmphasis)
            StreetPhotoView(photo: state.photo, maximumRows: photoRows)
            Text(StreetViewPanel.statusLine(state.status)).foreground(StreetViewPanel.statusColour(state.status, theme))
            if let image = state.image {
                Text(StreetViewPanel.caption(image)).foreground(theme.foregroundSubtle)
                Text("\(image.attribution) · \(image.licence)").foreground(theme.foregroundMuted)
            }
            Text(StreetViewPanel.hints(next: state.hasNext, previous: state.hasPrevious,
                                       turns: state.image?.heading == nil, bearing: state.bearing))
                .foreground(theme.foregroundMuted)
        }
        .focusable()
        .onKeyPress { event in
            MainActor.assumeIsolated {
                switch event.key {
                case .up, .character("]"): model.step(.forward)
                case .down, .character("["): model.step(.back)
                case .left: model.turn(by: -StreetViewModel.turnStep)
                case .right: model.turn(by: StreetViewModel.turnStep)
                default: return .ignored
                }
                return .handled
            }
        }
    }

    @TerminalEnvironment(\.theme) private var theme

    static func statusLine(_ status: StreetViewModel.Status) -> String {
        switch status {
        case .idle: ""
        case .searching: "looking for photos near here…"
        case .loadingPhoto: "loading the photo…"
        case .showing: ""
        case .nothingNearby: "no street imagery near here"
        case .failed(let reason): reason
        }
    }

    static func statusColour(_ status: StreetViewModel.Status, _ theme: any Theme) -> Color {
        switch status {
        case .failed: theme.error
        case .nothingNearby: theme.warning
        default: theme.busy
        }
    }

    /// When and which way: "2025-07-08 · facing SW".
    static func caption(_ image: StreetImage) -> String {
        var parts: [String] = []
        if let captured = image.captured {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            parts.append(formatter.string(from: captured))
        }
        if let heading = image.heading { parts.append("facing \(compassPoint(heading))") }
        return parts.isEmpty ? "taken here" : parts.joined(separator: " · ")
    }

    static func hints(next: Bool, previous: Bool, turns: Bool, bearing: Double) -> String {
        var hints: [String] = []
        if next { hints.append("↑ ahead") }
        if previous { hints.append("↓ back") }
        if turns { hints.append("←→ turn (\(compassPoint(bearing)))") }
        return hints.isEmpty ? "the end of this street's photos" : hints.joined(separator: " · ")
    }

    /// The nearest of the eight compass points to a bearing.
    static func compassPoint(_ bearing: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let sector = CompassBearing.fullTurn / Double(points.count)
        let index = Int((CompassBearing.normalised(bearing) / sector).rounded()) % points.count
        return points[index]
    }
}
