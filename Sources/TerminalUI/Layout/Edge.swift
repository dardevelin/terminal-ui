/// One side of a rectangle. SwiftUI parity: `Edge`.
public enum Edge: Sendable, Hashable, CaseIterable {
    case top
    case leading
    case bottom
    case trailing

    /// A set of edges — which sides a border draws, which sides padding
    /// insets. SwiftUI parity: `Edge.Set`, in both names and groupings, so
    /// `.horizontal` is the leading/trailing pair and `.vertical` the
    /// top/bottom one.
    public struct Set: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8

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

        public static let top = Set(rawValue: 1 << 0)
        public static let leading = Set(rawValue: 1 << 1)
        public static let bottom = Set(rawValue: 1 << 2)
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
    public var top: Int
    public var leading: Int
    public var bottom: Int
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
