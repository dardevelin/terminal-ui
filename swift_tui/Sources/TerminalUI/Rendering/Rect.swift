/// Layout rectangle using Double for unit-agnostic layout math.
/// Cell backends round to Int at render time; pixel backends use fractional values directly.
public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Convenience initializer from Int values (e.g. terminal column/row counts).
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = Double(x)
        self.y = Double(y)
        self.width = Double(width)
        self.height = Double(height)
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func inset(by amount: Int) -> Rect {
        let d = Double(amount)
        return Rect(
            x: x + d,
            y: y + d,
            width: max(0, width - d * 2),
            height: max(0, height - d * 2)
        )
    }

    /// Convert to integer cell coordinates by rounding.
    /// Used at the cell-backend boundary when writing to CellBuffer.
    public var intX: Int { Int(x.rounded(.toNearestOrAwayFromZero)) }
    public var intY: Int { Int(y.rounded(.toNearestOrAwayFromZero)) }
    public var intWidth: Int { Int(width.rounded(.toNearestOrAwayFromZero)) }
    public var intHeight: Int { Int(height.rounded(.toNearestOrAwayFromZero)) }
}
