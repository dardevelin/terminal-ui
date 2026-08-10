/// Where a view sits along the horizontal axis when it is narrower than the
/// space it was given.
///
/// SwiftUI parity in name and meaning. There are no custom alignment guides:
/// a cell grid has no sub-cell positions to align to, so the three edges plus
/// the middle describe everything a terminal can express.
public enum HorizontalAlignment: Sendable, Equatable {
    /// Flush with the left edge of the available cells (column 0 of the
    /// slack). TerminalUI renders left-to-right, so leading is always
    /// left.
    case leading
    /// Horizontally centered; an odd cell of slack lands the view one
    /// cell left of true center (integer division).
    case center
    /// Flush with the right edge of the available cells.
    case trailing
}

/// Where a view sits along the vertical axis when it is shorter than the space
/// it was given.
///
/// The vertical counterpart to ``HorizontalAlignment``, with the same
/// whole-cell constraint: offsets are computed in rows via
/// ``offset(for:in:)``, and centering an odd remainder rounds toward
/// the top. Used by `VStack`/`HStack` cross-axis alignment and combined
/// with a horizontal value inside ``Alignment``.
public enum VerticalAlignment: Sendable, Equatable {
    /// Flush with the top edge of the available cells (row 0 of the
    /// slack).
    case top
    /// Vertically centered; an odd row of slack lands the view one row
    /// above true center (integer division).
    case center
    /// Flush with the bottom edge of the available cells.
    case bottom
}

/// A point in two dimensions, for the places that align on both axes at once:
/// a `ZStack`, an `.overlay`, a `.frame` larger than its content.
///
/// Pairs a ``HorizontalAlignment`` with a ``VerticalAlignment``; the
/// nine static values cover every corner, edge midpoint, and the
/// center — the full set a whole-cell grid can express. Matches
/// SwiftUI's `Alignment` in name and meaning, so `.frame(width:height:
/// alignment:)` and `.overlay(alignment:)` read identically.
public struct Alignment: Sendable, Equatable {
    /// Placement along the horizontal axis (columns).
    public var horizontal: HorizontalAlignment
    /// Placement along the vertical axis (rows).
    public var vertical: VerticalAlignment

    /// Combine a horizontal and a vertical placement. The nine static
    /// presets cover every combination; this exists for call sites
    /// that compute the axes independently.
    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// Top-left corner of the available space.
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    /// Centered against the top edge.
    public static let top = Alignment(horizontal: .center, vertical: .top)
    /// Top-right corner of the available space.
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    /// Vertically centered against the left edge.
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    /// Centered on both axes — the default for `.frame` and `.overlay`.
    public static let center = Alignment(horizontal: .center, vertical: .center)
    /// Vertically centered against the right edge.
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    /// Bottom-left corner of the available space.
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    /// Centered against the bottom edge.
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    /// Bottom-right corner of the available space.
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)
}

extension HorizontalAlignment {
    /// The x offset that places `size` cells inside `available` cells.
    ///
    /// Integer division truncates, so an odd remainder lands the view one cell
    /// left of true centre. That is the only choice a cell grid offers, and it
    /// is the same one every terminal UI makes.
    public func offset(for size: Int, in available: Int) -> Int {
        let slack = max(0, available - size)
        switch self {
        case .leading: return 0
        case .center: return slack / 2
        case .trailing: return slack
        }
    }
}

extension VerticalAlignment {
    /// The y offset that places `size` cells inside `available` cells.
    public func offset(for size: Int, in available: Int) -> Int {
        let slack = max(0, available - size)
        switch self {
        case .top: return 0
        case .center: return slack / 2
        case .bottom: return slack
        }
    }
}
