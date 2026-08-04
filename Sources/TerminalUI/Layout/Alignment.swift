/// Where a view sits along the horizontal axis when it is narrower than the
/// space it was given.
///
/// SwiftUI parity in name and meaning. There are no custom alignment guides:
/// a cell grid has no sub-cell positions to align to, so the three edges plus
/// the middle describe everything a terminal can express.
public enum HorizontalAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
}

/// Where a view sits along the vertical axis when it is shorter than the space
/// it was given.
public enum VerticalAlignment: Sendable, Equatable {
    case top
    case center
    case bottom
}

/// A point in two dimensions, for the places that align on both axes at once:
/// a `ZStack`, an `.overlay`, a `.frame` larger than its content.
public struct Alignment: Sendable, Equatable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
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
