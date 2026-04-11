/// Numeric type used for layout coordinates.
///
/// Terminal backends use `Int` (cell positions).
/// Pixel backends use `Double` (sub-cell precision).
///
/// The view layer never sees this protocol — it exists at the
/// layout/rendering boundary so backends can declare their
/// coordinate precision.
public protocol Coordinate: Equatable, Sendable, Comparable, Hashable {
    static var zero: Self { get }
    static func + (lhs: Self, rhs: Self) -> Self
    static func - (lhs: Self, rhs: Self) -> Self
    static func * (lhs: Self, rhs: Self) -> Self
    func max(_ other: Self) -> Self
    init(_ intValue: Int)
}

extension Int: Coordinate {
    @inlinable
    public func max(_ other: Int) -> Int { Swift.max(self, other) }
}

extension Double: Coordinate {
    @inlinable
    public func max(_ other: Double) -> Double { Swift.max(self, other) }
}
