/// Numeric type used for layout coordinates.
///
/// Terminal backends use `Int` (cell positions).
/// Pixel backends use `Double` (sub-cell precision).
///
/// The view layer never sees this protocol — it exists at the
/// layout/rendering boundary so backends can declare their
/// coordinate precision.
public protocol Coordinate: Equatable, Sendable, Comparable, Hashable {
    /// The additive identity — the origin value (`0` / `0.0`), used for
    /// empty sizes and as the clamp floor in layout math.
    static var zero: Self { get }
    /// Coordinate addition — offsetting positions and summing extents.
    static func + (lhs: Self, rhs: Self) -> Self
    /// Coordinate subtraction. May produce negative values; layout code
    /// clamps with ``max(_:)`` where a negative extent is meaningless.
    static func - (lhs: Self, rhs: Self) -> Self
    /// Coordinate multiplication — scaling extents (e.g. doubling an
    /// inset for both edges in `LayoutRect.inset(by:)`).
    static func * (lhs: Self, rhs: Self) -> Self
    /// The larger of `self` and `other` — an instance-method spelling of
    /// `Swift.max` so generic layout code can clamp without shadowing
    /// issues (typically `.max(.zero)` to floor a computed extent).
    func max(_ other: Self) -> Self
    /// Convert a literal cell count into this coordinate type — how
    /// generic layout code spells constants (`C(2)` for "one inset on
    /// each edge") without tying itself to `Int`.
    init(_ intValue: Int)
}

/// `Int` is the cell-grid coordinate type — the one terminal rendering
/// uses (`Rect`, `CellRect`).
extension Int: Coordinate {
    /// The larger of the two cell counts; `extent.max(0)` floors a
    /// computed width or height at zero.
    @inlinable
    public func max(_ other: Int) -> Int { Swift.max(self, other) }
}

/// `Double` is the fractional coordinate type for pixel-space rects
/// (`PixelRect`).
extension Double: Coordinate {
    /// The larger of the two pixel values; `extent.max(0)` floors a
    /// computed width or height at zero.
    @inlinable
    public func max(_ other: Double) -> Double { Swift.max(self, other) }
}
