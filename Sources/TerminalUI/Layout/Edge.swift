/// One side of a rectangle. SwiftUI parity: `Edge`.
public enum Edge: Sendable, Hashable, CaseIterable {
    /// The upper side: the rows above the content.
    case top
    /// The side text starts from — the left, in the left-to-right layout
    /// the terminal uses.
    case leading
    /// The lower side: the rows below the content.
    case bottom
    /// The side text runs toward — the right, in the left-to-right layout
    /// the terminal uses.
    case trailing

    /// A set of edges — which sides a border draws, which sides padding
    /// insets. SwiftUI parity: `Edge.Set`, in both names and groupings, so
    /// `.horizontal` is the leading/trailing pair and `.vertical` the
    /// top/bottom one.
    public struct Set: OptionSet, Sendable, Hashable {
        /// The edges as bits: top, leading, bottom, trailing from the low
        /// bit up.
        public let rawValue: UInt8

        /// Creates a set from its bit pattern; prefer the named members.
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// The set holding just `edge`.
        public init(_ edge: Edge) {
            switch edge {
            case .top: self = .top
            case .leading: self = .leading
            case .bottom: self = .bottom
            case .trailing: self = .trailing
            }
        }

        /// Just the top edge.
        public static let top = Set(rawValue: 1 << 0)
        /// Just the leading (left) edge.
        public static let leading = Set(rawValue: 1 << 1)
        /// Just the bottom edge.
        public static let bottom = Set(rawValue: 1 << 2)
        /// Just the trailing (right) edge.
        public static let trailing = Set(rawValue: 1 << 3)

        /// The leading and trailing edges — the vertical pair, named for the
        /// axis they span, as in SwiftUI.
        public static let horizontal: Set = [.leading, .trailing]
        /// The top and bottom edges.
        public static let vertical: Set = [.top, .bottom]
        /// All four.
        public static let all: Set = [.top, .leading, .bottom, .trailing]
    }
}

/// Cells of inset on each side of a view. SwiftUI parity: `EdgeInsets`.
///
/// Cells are about twice as tall as they are wide, so equal insets look taller
/// than they are wide; uneven insets — `EdgeInsets(top: 0, leading: 2,
/// bottom: 0, trailing: 2)` — are the usual way to make padding look even.
public struct EdgeInsets: Sendable, Hashable, CustomStringConvertible {
    /// Blank rows above the content.
    public var top: Int
    /// Blank columns to the left of the content.
    public var leading: Int
    /// Blank rows below the content.
    public var bottom: Int
    /// Blank columns to the right of the content.
    public var trailing: Int

    /// Creates insets; every side defaults to none.
    public init(top: Int = 0, leading: Int = 0, bottom: Int = 0, trailing: Int = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    /// `length` on each of `edges`, none elsewhere.
    public init(_ edges: Edge.Set, _ length: Int) {
        self.init(top: edges.contains(.top) ? length : 0,
                  leading: edges.contains(.leading) ? length : 0,
                  bottom: edges.contains(.bottom) ? length : 0,
                  trailing: edges.contains(.trailing) ? length : 0)
    }

    /// Columns the insets take from a width.
    var horizontal: Int { leading + trailing }
    /// Rows the insets take from a height.
    var vertical: Int { top + bottom }

    /// A uniform inset reads as its one length; otherwise top, leading,
    /// bottom, trailing — so diagnostics for `.padding(1)` read as they always
    /// have.
    public var description: String {
        if top == leading, leading == bottom, bottom == trailing { return "\(top)" }
        return "\(top),\(leading),\(bottom),\(trailing)"
    }
}
