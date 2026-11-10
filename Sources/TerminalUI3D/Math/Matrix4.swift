import Foundation

/// A 4 × 4 transform: a rotation, scale and translation, a camera's view,
/// or a projection — in column-major order, multiplied onto column vectors,
/// as OpenGL's are.
///
/// `a * b` applies `b` first: `projection * view * model` takes a model's
/// point to the screen.
///
/// ```swift
/// let model = Matrix4.translation(Vector3(0, 1, 0)) * Matrix4.rotation(about: .unitY, angle: .pi / 4)
/// let placed = model.transformPoint(Vector3(1, 0, 0))
/// ```
public struct Matrix4: Sendable, Hashable {
    /// The first column: where the x axis goes.
    public var column0: Vector4
    /// The second column: where the y axis goes.
    public var column1: Vector4
    /// The third column: where the z axis goes.
    public var column2: Vector4
    /// The fourth column: the translation, and a projection's weight.
    public var column3: Vector4

    /// The matrix with these columns.
    @inlinable
    public init(_ column0: Vector4, _ column1: Vector4, _ column2: Vector4, _ column3: Vector4) {
        self.column0 = column0
        self.column1 = column1
        self.column2 = column2
        self.column3 = column3
    }

    /// The transform that changes nothing.
    public static let identity = Matrix4(Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0),
                                         Vector4(0, 0, 1, 0), Vector4(0, 0, 0, 1))

    /// The row `index`, 0 to 3.
    @inlinable
    public func row(_ index: Int) -> Vector4 {
        switch index {
        case 0: Vector4(column0.x, column1.x, column2.x, column3.x)
        case 1: Vector4(column0.y, column1.y, column2.y, column3.y)
        case 2: Vector4(column0.z, column1.z, column2.z, column3.z)
        default: Vector4(column0.w, column1.w, column2.w, column3.w)
        }
    }

    /// `rhs` then `lhs`.
    @inlinable
    public static func * (lhs: Matrix4, rhs: Matrix4) -> Matrix4 {
        Matrix4(lhs * rhs.column0, lhs * rhs.column1, lhs * rhs.column2, lhs * rhs.column3)
    }

    /// The vector transformed.
    @inlinable
    public static func * (lhs: Matrix4, rhs: Vector4) -> Vector4 {
        lhs.column0 * rhs.x + lhs.column1 * rhs.y + lhs.column2 * rhs.z + lhs.column3 * rhs.w
    }

    /// The point transformed, translation included, and divided by its
    /// weight when a projection gave it one.
    @inlinable
    public func transformPoint(_ point: Vector3) -> Vector3 {
        let transformed = self * Vector4(point, 1)
        guard transformed.w != 0, transformed.w != 1 else { return transformed.xyz }
        return transformed.xyz / transformed.w
    }

    /// The direction transformed: rotated and scaled, not translated.
    @inlinable
    public func transformDirection(_ direction: Vector3) -> Vector3 {
        (self * Vector4(direction, 0)).xyz
    }

    /// The matrix with rows and columns swapped.
    public var transposed: Matrix4 {
        Matrix4(row(0), row(1), row(2), row(3))
    }

    // MARK: - Building

    /// A move by `offset`.
    public static func translation(_ offset: Vector3) -> Matrix4 {
        var matrix = identity
        matrix.column3 = Vector4(offset, 1)
        return matrix
    }

    /// A scale by `factors` along each axis, about the origin.
    public static func scale(_ factors: Vector3) -> Matrix4 {
        Matrix4(Vector4(factors.x, 0, 0, 0), Vector4(0, factors.y, 0, 0),
                Vector4(0, 0, factors.z, 0), Vector4(0, 0, 0, 1))
    }

    /// A scale by `factor` along every axis, about the origin.
    public static func scale(_ factor: Double) -> Matrix4 {
        scale(Vector3(factor, factor, factor))
    }

    /// A turn of `angle` radians about `axis`, anticlockwise looking down
    /// the axis toward the origin. A zero axis turns nothing.
    public static func rotation(about axis: Vector3, angle: Double) -> Matrix4 {
        Quaternion(axis: axis, angle: angle).matrix
    }

    /// The transform a camera at `eye` looking at `target` sees the world
    /// through: the world moved so the camera sits at the origin looking
    /// down −z with `up` as near to +y as it can be (`gluLookAt`).
    public static func lookAt(eye: Vector3, target: Vector3, up: Vector3) -> Matrix4 {
        let forward = (target - eye).normalized
        var side = forward.cross(up)
        if side.length < Self.parallelTolerance * max(1, up.length) {
            // Looking along `up`, or so nearly that the side it gives is
            // rounding error: any side will do, so take one that is
            // perpendicular to the view.
            side = forward.cross(abs(forward.x) < Self.parallelLimit ? Vector3.unitX : Vector3.unitZ)
        }
        side = side.normalized
        let trueUp = side.cross(forward)
        return Matrix4(Vector4(side.x, trueUp.x, -forward.x, 0),
                       Vector4(side.y, trueUp.y, -forward.y, 0),
                       Vector4(side.z, trueUp.z, -forward.z, 0),
                       Vector4(-side.dot(eye), -trueUp.dot(eye), forward.dot(eye), 1))
    }

    /// The component below which a direction has turned away from an axis.
    private static let parallelLimit = 0.9
    /// The sine of the angle below which a view and its up are taken as
    /// parallel: well under a millionth of a degree.
    private static let parallelTolerance = 1e-8

    /// A perspective projection (`gluPerspective`): `fieldOfView` radians
    /// top to bottom, `aspect` its width over its height, seeing from
    /// `near` to `far` in front of the camera into OpenGL's clip space.
    public static func perspective(fieldOfView: Double, aspect: Double, near: Double, far: Double) -> Matrix4 {
        let focal = 1 / tan(fieldOfView / 2)
        let depth = near - far
        return Matrix4(Vector4(focal / aspect, 0, 0, 0),
                       Vector4(0, focal, 0, 0),
                       Vector4(0, 0, (far + near) / depth, -1),
                       Vector4(0, 0, 2 * far * near / depth, 0))
    }

    /// A parallel projection (`glOrtho`) of the box from `left` to `right`,
    /// `bottom` to `top`, and `near` to `far` in front of the camera.
    public static func orthographic(left: Double, right: Double, bottom: Double, top: Double,
                                    near: Double, far: Double) -> Matrix4 {
        let width = right - left, height = top - bottom, depth = far - near
        return Matrix4(Vector4(2 / width, 0, 0, 0),
                       Vector4(0, 2 / height, 0, 0),
                       Vector4(0, 0, -2 / depth, 0),
                       Vector4(-(right + left) / width, -(top + bottom) / height, -(far + near) / depth, 1))
    }

    // MARK: - Inverse

    /// The transform that undoes this one, or nil when none does — a scale
    /// of zero along some axis. By cofactors (Cramer's rule), as MESA's
    /// `gluInvertMatrix` computes it.
    public var inverse: Matrix4? {
        let entries = [column0.x, column0.y, column0.z, column0.w, column1.x, column1.y, column1.z, column1.w,
                 column2.x, column2.y, column2.z, column2.w, column3.x, column3.y, column3.z, column3.w]
        var cofactors = [Double](repeating: 0, count: 16)
        cofactors[0] = entries[5] * entries[10] * entries[15] - entries[5] * entries[11] * entries[14] - entries[9] * entries[6] * entries[15]
            + entries[9] * entries[7] * entries[14] + entries[13] * entries[6] * entries[11] - entries[13] * entries[7] * entries[10]
        cofactors[4] = -entries[4] * entries[10] * entries[15] + entries[4] * entries[11] * entries[14] + entries[8] * entries[6] * entries[15]
            - entries[8] * entries[7] * entries[14] - entries[12] * entries[6] * entries[11] + entries[12] * entries[7] * entries[10]
        cofactors[8] = entries[4] * entries[9] * entries[15] - entries[4] * entries[11] * entries[13] - entries[8] * entries[5] * entries[15]
            + entries[8] * entries[7] * entries[13] + entries[12] * entries[5] * entries[11] - entries[12] * entries[7] * entries[9]
        cofactors[12] = -entries[4] * entries[9] * entries[14] + entries[4] * entries[10] * entries[13] + entries[8] * entries[5] * entries[14]
            - entries[8] * entries[6] * entries[13] - entries[12] * entries[5] * entries[10] + entries[12] * entries[6] * entries[9]
        cofactors[1] = -entries[1] * entries[10] * entries[15] + entries[1] * entries[11] * entries[14] + entries[9] * entries[2] * entries[15]
            - entries[9] * entries[3] * entries[14] - entries[13] * entries[2] * entries[11] + entries[13] * entries[3] * entries[10]
        cofactors[5] = entries[0] * entries[10] * entries[15] - entries[0] * entries[11] * entries[14] - entries[8] * entries[2] * entries[15]
            + entries[8] * entries[3] * entries[14] + entries[12] * entries[2] * entries[11] - entries[12] * entries[3] * entries[10]
        cofactors[9] = -entries[0] * entries[9] * entries[15] + entries[0] * entries[11] * entries[13] + entries[8] * entries[1] * entries[15]
            - entries[8] * entries[3] * entries[13] - entries[12] * entries[1] * entries[11] + entries[12] * entries[3] * entries[9]
        cofactors[13] = entries[0] * entries[9] * entries[14] - entries[0] * entries[10] * entries[13] - entries[8] * entries[1] * entries[14]
            + entries[8] * entries[2] * entries[13] + entries[12] * entries[1] * entries[10] - entries[12] * entries[2] * entries[9]
        cofactors[2] = entries[1] * entries[6] * entries[15] - entries[1] * entries[7] * entries[14] - entries[5] * entries[2] * entries[15]
            + entries[5] * entries[3] * entries[14] + entries[13] * entries[2] * entries[7] - entries[13] * entries[3] * entries[6]
        cofactors[6] = -entries[0] * entries[6] * entries[15] + entries[0] * entries[7] * entries[14] + entries[4] * entries[2] * entries[15]
            - entries[4] * entries[3] * entries[14] - entries[12] * entries[2] * entries[7] + entries[12] * entries[3] * entries[6]
        cofactors[10] = entries[0] * entries[5] * entries[15] - entries[0] * entries[7] * entries[13] - entries[4] * entries[1] * entries[15]
            + entries[4] * entries[3] * entries[13] + entries[12] * entries[1] * entries[7] - entries[12] * entries[3] * entries[5]
        cofactors[14] = -entries[0] * entries[5] * entries[14] + entries[0] * entries[6] * entries[13] + entries[4] * entries[1] * entries[14]
            - entries[4] * entries[2] * entries[13] - entries[12] * entries[1] * entries[6] + entries[12] * entries[2] * entries[5]
        cofactors[3] = -entries[1] * entries[6] * entries[11] + entries[1] * entries[7] * entries[10] + entries[5] * entries[2] * entries[11]
            - entries[5] * entries[3] * entries[10] - entries[9] * entries[2] * entries[7] + entries[9] * entries[3] * entries[6]
        cofactors[7] = entries[0] * entries[6] * entries[11] - entries[0] * entries[7] * entries[10] - entries[4] * entries[2] * entries[11]
            + entries[4] * entries[3] * entries[10] + entries[8] * entries[2] * entries[7] - entries[8] * entries[3] * entries[6]
        cofactors[11] = -entries[0] * entries[5] * entries[11] + entries[0] * entries[7] * entries[9] + entries[4] * entries[1] * entries[11]
            - entries[4] * entries[3] * entries[9] - entries[8] * entries[1] * entries[7] + entries[8] * entries[3] * entries[5]
        cofactors[15] = entries[0] * entries[5] * entries[10] - entries[0] * entries[6] * entries[9] - entries[4] * entries[1] * entries[10]
            + entries[4] * entries[2] * entries[9] + entries[8] * entries[1] * entries[6] - entries[8] * entries[2] * entries[5]
        let determinant = entries[0] * cofactors[0] + entries[1] * cofactors[4] + entries[2] * cofactors[8] + entries[3] * cofactors[12]
        guard determinant != 0, determinant.isFinite else { return nil }
        let scale = 1 / determinant
        return Matrix4(Vector4(cofactors[0], cofactors[1], cofactors[2], cofactors[3]) * scale,
                       Vector4(cofactors[4], cofactors[5], cofactors[6], cofactors[7]) * scale,
                       Vector4(cofactors[8], cofactors[9], cofactors[10], cofactors[11]) * scale,
                       Vector4(cofactors[12], cofactors[13], cofactors[14], cofactors[15]) * scale)
    }

    /// What normals are carried through: the inverse transpose of this
    /// transform's rotation and scale, which keeps a normal perpendicular to
    /// its surface under a scale that is not the same along every axis. A
    /// transform with no inverse carries them through itself.
    public var normalMatrix: Matrix4 {
        var linear = self
        linear.column3 = Vector4(0, 0, 0, 1)
        linear.column0.w = 0
        linear.column1.w = 0
        linear.column2.w = 0
        return linear.inverse?.transposed ?? linear
    }
}
