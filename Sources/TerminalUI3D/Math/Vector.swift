import Foundation

/// A point or direction in a plane: a footprint's corner, a texture place.
public struct Vector2: Sendable, Hashable {
    /// Across.
    public var x: Double
    /// Down the plane's other axis — `z` when the plane is the ground.
    public var y: Double

    /// The vector (`x`, `y`).
    @inlinable
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// The origin.
    public static let zero = Vector2(0, 0)

    /// The sum, component by component.
    @inlinable public static func + (lhs: Vector2, rhs: Vector2) -> Vector2 { Vector2(lhs.x + rhs.x, lhs.y + rhs.y) }
    /// The difference, component by component.
    @inlinable public static func - (lhs: Vector2, rhs: Vector2) -> Vector2 { Vector2(lhs.x - rhs.x, lhs.y - rhs.y) }
    /// The vector scaled by `rhs`.
    @inlinable public static func * (lhs: Vector2, rhs: Double) -> Vector2 { Vector2(lhs.x * rhs, lhs.y * rhs) }

    /// The z component of the cross product of the two, extended into
    /// space: positive when `other` turns anticlockwise from this one.
    @inlinable
    public func cross(_ other: Vector2) -> Double { x * other.y - y * other.x }

    /// The dot product.
    @inlinable
    public func dot(_ other: Vector2) -> Double { x * other.x + y * other.y }
}

/// A point or direction in space.
///
/// Right-handed, as OpenGL's: x to the right, y up, and z toward the viewer
/// of a camera that has not been moved.
public struct Vector3: Sendable, Hashable {
    /// Right.
    public var x: Double
    /// Up.
    public var y: Double
    /// Toward the viewer.
    public var z: Double

    /// The vector (`x`, `y`, `z`).
    @inlinable
    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// The origin.
    public static let zero = Vector3(0, 0, 0)
    /// One along every axis.
    public static let one = Vector3(1, 1, 1)
    /// The x axis.
    public static let unitX = Vector3(1, 0, 0)
    /// The y axis: up.
    public static let unitY = Vector3(0, 1, 0)
    /// The z axis.
    public static let unitZ = Vector3(0, 0, 1)

    /// The sum, component by component.
    @inlinable public static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }
    /// The difference, component by component.
    @inlinable public static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }
    /// The vector pointing the other way.
    @inlinable public static prefix func - (vector: Vector3) -> Vector3 { Vector3(-vector.x, -vector.y, -vector.z) }
    /// The vector scaled by `rhs`.
    @inlinable public static func * (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }
    /// The vector scaled by `lhs`.
    @inlinable public static func * (lhs: Double, rhs: Vector3) -> Vector3 { rhs * lhs }
    /// The vector divided by `rhs`.
    @inlinable public static func / (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
    }
    /// Adds `rhs` to the vector.
    @inlinable public static func += (lhs: inout Vector3, rhs: Vector3) { lhs = lhs + rhs }
    /// Subtracts `rhs` from the vector.
    @inlinable public static func -= (lhs: inout Vector3, rhs: Vector3) { lhs = lhs - rhs }

    /// The dot product.
    @inlinable
    public func dot(_ other: Vector3) -> Double { x * other.x + y * other.y + z * other.z }

    /// The cross product: perpendicular to both, by the right-hand rule.
    @inlinable
    public func cross(_ other: Vector3) -> Vector3 {
        Vector3(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
    }

    /// The vector's length.
    @inlinable
    public var length: Double { dot(self).squareRoot() }

    /// The vector scaled to length 1, or the zero vector unchanged.
    @inlinable
    public var normalized: Vector3 {
        let length = self.length
        return length > 0 ? self / length : self
    }

    /// The point a fraction `amount` of the way to `other`.
    @inlinable
    public func interpolated(to other: Vector3, amount: Double) -> Vector3 {
        self + (other - self) * amount
    }
}

/// A point in homogeneous coordinates: what a ``Matrix4`` projects a
/// ``Vector3`` to before the divide by ``w``.
public struct Vector4: Sendable, Hashable {
    /// The x component.
    public var x: Double
    /// The y component.
    public var y: Double
    /// The z component.
    public var z: Double
    /// The homogeneous weight: 1 for a point, 0 for a direction.
    public var w: Double

    /// The vector (`x`, `y`, `z`, `w`).
    @inlinable
    public init(_ x: Double, _ y: Double, _ z: Double, _ w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    /// The point `vector`, with a weight of `w`.
    @inlinable
    public init(_ vector: Vector3, _ w: Double) {
        self.init(vector.x, vector.y, vector.z, w)
    }

    /// The first three components.
    @inlinable
    public var xyz: Vector3 { Vector3(x, y, z) }

    /// The sum, component by component.
    @inlinable public static func + (lhs: Vector4, rhs: Vector4) -> Vector4 {
        Vector4(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z, lhs.w + rhs.w)
    }
    /// The difference, component by component.
    @inlinable public static func - (lhs: Vector4, rhs: Vector4) -> Vector4 {
        Vector4(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z, lhs.w - rhs.w)
    }
    /// The vector scaled by `rhs`.
    @inlinable public static func * (lhs: Vector4, rhs: Double) -> Vector4 {
        Vector4(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs, lhs.w * rhs)
    }

    /// The dot product.
    @inlinable
    public func dot(_ other: Vector4) -> Double { x * other.x + y * other.y + z * other.z + w * other.w }
}
