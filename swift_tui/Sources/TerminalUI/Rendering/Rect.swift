/// Layout rectangle generic over coordinate type.
///
/// Terminal backends use `LayoutRect<Int>` (aliased as `Rect` and `CellRect`).
/// Pixel backends use `LayoutRect<Double>` (aliased as `PixelRect`).
public struct LayoutRect<C: Coordinate>: Equatable, Sendable, Hashable {
    public var x: C
    public var y: C
    public var width: C
    public var height: C

    public init(x: C, y: C, width: C, height: C) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= C.zero || height <= C.zero }

    public func inset(by amount: C) -> LayoutRect<C> {
        LayoutRect(
            x: x + amount,
            y: y + amount,
            width: (width - amount * C(2)).max(C.zero),
            height: (height - amount * C(2)).max(C.zero)
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
