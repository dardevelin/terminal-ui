import Foundation

/// A rotation, as a unit quaternion: one that composes without the gimbal
/// lock Euler angles have, and interpolates along the shortest arc.
///
/// ```swift
/// let spin = Quaternion(axis: .unitY, angle: time) * Quaternion(axis: .unitX, angle: 0.4)
/// let model = spin.matrix
/// ```
public struct Quaternion: Sendable, Hashable {
    /// The vector part's x.
    public var x: Double
    /// The vector part's y.
    public var y: Double
    /// The vector part's z.
    public var z: Double
    /// The scalar part: the cosine of half the angle turned.
    public var w: Double

    /// The quaternion with these components, as given.
    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    /// No rotation.
    public static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)

    /// A turn of `angle` radians about `axis`, anticlockwise looking down
    /// the axis toward the origin. A zero axis turns nothing.
    public init(axis: Vector3, angle: Double) {
        let unit = axis.normalized
        guard unit != .zero else {
            self = .identity
            return
        }
        let half = angle / 2
        let sine = sin(half)
        self.init(x: unit.x * sine, y: unit.y * sine, z: unit.z * sine, w: cos(half))
    }

    /// The rotation of Euler angles in radians, applied roll (about z),
    /// then pitch (about x), then yaw (about y) — the order that turns a
    /// camera or a vehicle without rolling its heading.
    public init(pitch: Double, yaw: Double, roll: Double) {
        self = Quaternion(axis: .unitY, angle: yaw) * Quaternion(axis: .unitX, angle: pitch)
            * Quaternion(axis: .unitZ, angle: roll)
    }

    /// `rhs` then `lhs` (Hamilton's product).
    public static func * (lhs: Quaternion, rhs: Quaternion) -> Quaternion {
        Quaternion(x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
                   y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
                   z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w,
                   w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z)
    }

    /// The quaternion scaled to length 1, or no rotation for a zero one.
    public var normalized: Quaternion {
        let length = (x * x + y * y + z * z + w * w).squareRoot()
        guard length > 0 else { return .identity }
        return Quaternion(x: x / length, y: y / length, z: z / length, w: w / length)
    }

    /// The opposite rotation.
    public var inverse: Quaternion {
        Quaternion(x: -x, y: -y, z: -z, w: w)
    }

    /// `vector` turned by this rotation.
    public func rotate(_ vector: Vector3) -> Vector3 {
        // v' = v + 2w(q × v) + 2q × (q × v), for q the vector part: the
        // sandwich product q v q⁻¹ expanded for a unit quaternion.
        let axis = Vector3(x, y, z)
        let twice = axis.cross(vector) * 2
        return vector + twice * w + axis.cross(twice)
    }

    /// The rotation as a transform.
    public var matrix: Matrix4 {
        let unit = normalized
        let (qx, qy, qz, qw) = (unit.x, unit.y, unit.z, unit.w)
        return Matrix4(
            Vector4(1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy + qz * qw), 2 * (qx * qz - qy * qw), 0),
            Vector4(2 * (qx * qy - qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz + qx * qw), 0),
            Vector4(2 * (qx * qz + qy * qw), 2 * (qy * qz - qx * qw), 1 - 2 * (qx * qx + qy * qy), 0),
            Vector4(0, 0, 0, 1))
    }

    /// The rotation a fraction `amount` of the way to `other`, along the
    /// shorter arc at a steady rate (Shoemake, "Animating Rotation with
    /// Quaternion Curves", SIGGRAPH 1985).
    public func slerp(to other: Quaternion, amount: Double) -> Quaternion {
        var target = other
        var cosine = x * other.x + y * other.y + z * other.z + w * other.w
        if cosine < 0 {
            target = Quaternion(x: -other.x, y: -other.y, z: -other.z, w: -other.w)
            cosine = -cosine
        }
        // Nearly the same rotation: the arc is a line, and sin θ ≈ 0 would
        // divide by nothing.
        if cosine > Self.nearlyParallel {
            return Quaternion(x: x + (target.x - x) * amount, y: y + (target.y - y) * amount,
                              z: z + (target.z - z) * amount, w: w + (target.w - w) * amount).normalized
        }
        let angle = acos(cosine)
        let sine = sin(angle)
        let from = sin((1 - amount) * angle) / sine, to = sin(amount * angle) / sine
        return Quaternion(x: x * from + target.x * to, y: y * from + target.y * to,
                          z: z * from + target.z * to, w: w * from + target.w * to)
    }

    /// The cosine above which two rotations are interpolated as a line.
    private static let nearlyParallel = 0.9995
}
