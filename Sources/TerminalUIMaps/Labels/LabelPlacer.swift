import TerminalUI

/// A label the map would like to draw.
public struct LabelRequest: Sendable, Hashable {
    /// Where a label goes relative to its anchor.
    public enum Style: Sendable, Hashable {
        /// A name that is the place: centred on it, or else just above or
        /// below.
        case centred
        /// A name next to a marker drawn at the anchor: right of it, else
        /// left, else above or below; never over the marker's cell.
        case besideMarker
        /// A point of interest: its glyph at the anchor, and its name
        /// beside it as ``besideMarker`` places one. Unlike a marker's pin,
        /// the glyph claims its cell like any label — where an earlier
        /// label holds it, the point is dropped — and where the name finds
        /// no room the glyph is kept alone, so a busy street still shows
        /// what is on it.
        case pointOfInterest
    }

    public var text: String
    /// Where the label belongs, in cells of the canvas it is drawn on:
    /// fractional, since a projected coordinate falls between cells, and
    /// rounding it is the placer's job, not the projection's.
    public var anchor: CanvasPoint
    /// Lower claims space first (`MapRole.labelRank`).
    public var rank: Int
    public var style: Style

    public init(text: String, anchor: CanvasPoint, rank: Int, style: Style = .centred) {
        self.text = text
        self.anchor = anchor
        self.rank = rank
        self.style = style
    }
}

/// A label given a place on the screen: `width` columns from `column` on
/// `row`.
public struct PlacedLabel: Sendable, Hashable {
    public var text: String
    public var column: Int
    public var row: Int
    public var width: Int
    public var rank: Int
    /// Where its request sat in the list handed to the placer, so a caller
    /// can draw what goes with it — a marker at its anchor.
    public var request: Int
    /// False for a point of interest whose glyph found room and whose name
    /// did not: only its anchor's cell is taken, and the text is not drawn.
    public var showsText: Bool

    public init(text: String, column: Int, row: Int, width: Int, rank: Int, request: Int = 0,
                showsText: Bool = true) {
        self.text = text
        self.column = column
        self.row = row
        self.width = width
        self.rank = rank
        self.request = request
        self.showsText = showsText
    }
}

/// Places a frame's labels so none overlaps another, the most important
/// first.
///
/// The split is pretext's (github.com/chenglou/pretext): measuring text is
/// the cost, placing it arithmetic. A text is measured once, the first frame
/// it appears in, and every later frame — each pan and zoom step — places
/// it from the cached width. Placement is greedy in rank order against a
/// grid of claimed cells: a label takes the first of its candidate places
/// that is on screen and free, or is dropped.
public struct LabelPlacer: Sendable {
    private enum Spacing {
        /// Free columns kept either side of a label, so two on one row read
        /// as two names and not one.
        static let gap = 1
        /// How near, in cells, a label may come to another of the same
        /// text. Neighbouring tiles each carry a road's name, and a road
        /// through several tiles would otherwise be named in each.
        static let repeatColumns = 24.0
        static let repeatRows = 8.0
        /// The marker's own cell and the space after it.
        static let markerOffset = 2
    }

    private var widths: [String: Int] = [:]

    /// How many texts have been measured since the placer was made: one
    /// per distinct text, however many frames place it.
    public private(set) var measurements = 0

    public init() {}

    /// The places this frame's labels get, in the order they claimed them.
    public mutating func place(_ requests: [LabelRequest], in size: Size) -> [PlacedLabel] {
        guard size.width > 0, size.height > 0 else { return [] }
        var claimed = ClaimGrid(size: size)
        var placed: [PlacedLabel] = []
        let ordered = requests.enumerated().sorted { lhs, rhs in
            (lhs.element.rank, lhs.offset) < (rhs.element.rank, rhs.offset)
        }
        for (index, request) in ordered {
            let width = measure(request.text)
            guard width > 0, !repeatsNearby(request, among: placed) else { continue }
            let anchorColumn = Int(request.anchor.x.rounded(.down))
            let anchorRow = Int(request.anchor.y.rounded(.down))
            switch request.style {
            case .besideMarker:
                claimed.claim(row: anchorRow, from: anchorColumn, width: 1)
            case .pointOfInterest:
                guard (0..<size.width).contains(anchorColumn), (0..<size.height).contains(anchorRow),
                      claimed.isFree(row: anchorRow, from: anchorColumn, width: 1) else { continue }
                claimed.claim(row: anchorRow, from: anchorColumn, width: 1)
            case .centred:
                break
            }
            let spot = candidates(for: request, width: width, column: anchorColumn, row: anchorRow).first {
                column, row in
                column >= 0 && column + width <= size.width && (0..<size.height).contains(row)
                    && claimed.isFree(row: row, from: column - Spacing.gap, width: width + 2 * Spacing.gap)
            }
            guard let (column, row) = spot else {
                if request.style == .pointOfInterest {
                    placed.append(PlacedLabel(text: request.text, column: anchorColumn, row: anchorRow, width: 1,
                                              rank: request.rank, request: index, showsText: false))
                }
                continue
            }
            claimed.claim(row: row, from: column - Spacing.gap, width: width + 2 * Spacing.gap)
            placed.append(PlacedLabel(text: request.text, column: column, row: row, width: width,
                                      rank: request.rank, request: index))
        }
        return placed
    }

    /// The columns `text` takes, measured the first time it is asked for
    /// and remembered: what a caller deciding where to offer a name needs,
    /// counted with the placer's own measurements.
    public mutating func width(of text: String) -> Int {
        measure(text)
    }

    private mutating func measure(_ text: String) -> Int {
        if let width = widths[text] { return width }
        let width = text.displayWidth
        widths[text] = width
        measurements += 1
        return width
    }

    private func candidates(for request: LabelRequest, width: Int, column: Int, row: Int) -> [(Int, Int)] {
        let centred = Int((request.anchor.x - Double(width) / 2).rounded())
        switch request.style {
        case .centred:
            return [(centred, row), (centred, row - 1), (centred, row + 1)]
        case .besideMarker, .pointOfInterest:
            return [
                (column + Spacing.markerOffset, row),
                (column - Spacing.markerOffset - width + 1, row),
                (centred, row - 1),
                (centred, row + 1),
            ]
        }
    }

    private func repeatsNearby(_ request: LabelRequest, among placed: [PlacedLabel]) -> Bool {
        placed.contains { label in
            label.text == request.text
                && abs(Double(label.column) + Double(label.width) / 2 - request.anchor.x) < Spacing.repeatColumns
                && abs(Double(label.row) - request.anchor.y) < Spacing.repeatRows
        }
    }
}

/// The cells labels have taken this frame.
private struct ClaimGrid {
    private let size: Size
    private var taken: [Bool]

    init(size: Size) {
        self.size = size
        taken = Array(repeating: false, count: size.width * size.height)
    }

    /// The part of a row's span that is on screen, as indices into `taken`.
    private func span(row: Int, from column: Int, width: Int) -> Range<Int>? {
        guard (0..<size.height).contains(row) else { return nil }
        let start = max(column, 0)
        let end = min(column + width, size.width)
        guard start < end else { return nil }
        return (row * size.width + start)..<(row * size.width + end)
    }

    /// Off-screen cells count as free: a label's gap may hang past the edge.
    func isFree(row: Int, from column: Int, width: Int) -> Bool {
        guard let span = span(row: row, from: column, width: width) else { return true }
        return !taken[span].contains(true)
    }

    mutating func claim(row: Int, from column: Int, width: Int) {
        guard let span = span(row: row, from: column, width: width) else { return }
        for index in span { taken[index] = true }
    }
}
