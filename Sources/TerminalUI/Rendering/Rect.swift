/// Layout rectangle generic over coordinate type.
///
/// Terminal backends use `LayoutRect<Int>` (aliased as `Rect` and `CellRect`).
/// Pixel backends use `LayoutRect<Double>` (aliased as `PixelRect`).
public struct LayoutRect<C: Coordinate>: Equatable, Sendable, Hashable {
    /// Left edge, 0-based from the container's left.
    public var x: C
    /// Top edge, 0-based from the container's top.
    public var y: C
    /// Horizontal extent; the rect covers `x ..< x + width`.
    public var width: C
    /// Vertical extent; the rect covers `y ..< y + height`.
    public var height: C

    /// Creates a rect from origin and size.
    public init(x: C, y: C, width: C, height: C) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// `true` when either dimension is zero or negative — the rect covers
    /// no cells.
    public var isEmpty: Bool { width <= C.zero || height <= C.zero }

    /// A rect shrunk by `amount` on all four edges; dimensions floor at
    /// zero rather than going negative.
    public func inset(by amount: C) -> LayoutRect<C> {
        LayoutRect(
            x: x + amount,
            y: y + amount,
            width: (width - amount * C(2)).max(C.zero),
            height: (height - amount * C(2)).max(C.zero)
        )
    }

    /// Intersection of two rects. Returns an empty rect (width or height <= 0)
    /// when the inputs don't overlap. Clip stacks use this so a child's clip
    /// can never extend beyond an ancestor's.
    public func intersected(with other: LayoutRect<C>) -> LayoutRect<C> {
        let x1 = x > other.x ? x : other.x
        let y1 = y > other.y ? y : other.y
        let x2a = x + width
        let x2b = other.x + other.width
        let x2 = x2a < x2b ? x2a : x2b
        let y2a = y + height
        let y2b = other.y + other.height
        let y2 = y2a < y2b ? y2a : y2b
        return LayoutRect(
            x: x1, y: y1,
            width: (x2 - x1).max(C.zero),
            height: (y2 - y1).max(C.zero)
        )
    }
}

// MARK: - Default typealiases

/// Cell-based rectangle — the default for terminal rendering.
/// All existing code uses this via the bare name `Rect`.
public typealias Rect = LayoutRect<Int>

/// Explicit alias for terminal backends.
public typealias CellRect = LayoutRect<Int>

/// Pixel-based rectangle for GPU/fractional rendering.
public typealias PixelRect = LayoutRect<Double>
