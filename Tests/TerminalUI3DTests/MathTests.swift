import Foundation
import Testing
import TerminalUI3D

// The transforms follow OpenGL's conventions: column vectors, right-handed
// space, a camera looking down −z, and clip space from −w to w.

private func close(_ lhs: Vector3, _ rhs: Vector3, within tolerance: Double = 1e-9) -> Bool {
    (lhs - rhs).length <= tolerance
}

@Suite("Vectors, matrices and rotations")
struct MathTests {

    @Test func aCrossProductFollowsTheRightHandRule() {
        #expect(Vector3.unitX.cross(.unitY) == .unitZ)
        #expect(Vector3(3, 4, 0).length == 5)
        #expect(close(Vector3(0, 0, 9).normalized, .unitZ))
    }

    @Test func aMatrixAppliesTheRightHandFactorFirst() {
        let move = Matrix4.translation(Vector3(1, 2, 3))
        let grow = Matrix4.scale(2)
        #expect(close((move * grow).transformPoint(Vector3(1, 1, 1)), Vector3(3, 4, 5)))
        #expect(close((grow * move).transformPoint(Vector3(1, 1, 1)), Vector3(4, 6, 8)))
        #expect(close(move.transformDirection(.unitX), .unitX), "a direction is not moved")
    }

    @Test func aQuarterTurnAboutYTakesXToMinusZ() {
        let turn = Matrix4.rotation(about: .unitY, angle: .pi / 2)
        #expect(close(turn.transformPoint(.unitX), Vector3(0, 0, -1)))
        let quaternion = Quaternion(axis: .unitY, angle: .pi / 2)
        #expect(close(quaternion.rotate(.unitX), Vector3(0, 0, -1)))
    }

    @Test func aQuaternionAndItsMatrixAgree() {
        let rotation = Quaternion(axis: Vector3(1, 2, 3), angle: 0.7) * Quaternion(pitch: 0.3, yaw: -1.1, roll: 0.2)
        let point = Vector3(0.4, -2, 1.5)
        #expect(close(rotation.rotate(point), rotation.matrix.transformPoint(point)))
        #expect(close(rotation.inverse.rotate(rotation.rotate(point)), point))
    }

    @Test func slerpHalfwayTurnsHalfTheAngle() {
        let quarter = Quaternion(axis: .unitZ, angle: .pi / 2)
        let half = Quaternion.identity.slerp(to: quarter, amount: 0.5)
        #expect(close(half.rotate(.unitX), Vector3(cos(.pi / 4), sin(.pi / 4), 0)))
    }

    @Test func anInverseUndoesItsMatrix() throws {
        let transform = Matrix4.translation(Vector3(3, -1, 2)) * Matrix4.rotation(about: Vector3(1, 1, 0), angle: 0.8)
            * Matrix4.scale(Vector3(2, 0.5, 3))
        let inverse = try #require(transform.inverse)
        let point = Vector3(0.3, 7, -2)
        #expect(close(inverse.transformPoint(transform.transformPoint(point)), point, within: 1e-9))
        #expect(Matrix4.scale(Vector3(1, 0, 1)).inverse == nil)
    }

    @Test func aNormalStaysPerpendicularUnderAStretch() {
        // A surface sloping at 45° in x–y, stretched along x: its normal
        // carried by the transform itself would no longer be perpendicular.
        let stretch = Matrix4.scale(Vector3(4, 1, 1))
        let along = stretch.transformDirection(Vector3(1, 1, 0))
        let normal = stretch.normalMatrix.transformDirection(Vector3(1, -1, 0))
        #expect(abs(along.dot(normal)) < 1e-12)
    }

    @Test func lookAtPutsTheEyeAtTheOriginFacingMinusZ() {
        let view = Matrix4.lookAt(eye: Vector3(0, 0, 5), target: .zero, up: .unitY)
        #expect(close(view.transformPoint(Vector3(0, 0, 5)), .zero))
        #expect(close(view.transformPoint(.zero), Vector3(0, 0, -5)))
        let above = Matrix4.lookAt(eye: Vector3(0, 10, 0), target: .zero, up: .unitY)
        #expect(close(above.transformPoint(.zero), Vector3(0, 0, -10)), "looking along up still works")
    }

    @Test func aPerspectiveMapsNearAndFarToTheEndsOfClipSpace() {
        let projection = Matrix4.perspective(fieldOfView: .pi / 2, aspect: 1, near: 1, far: 10)
        #expect(abs(projection.transformPoint(Vector3(0, 0, -1)).z - -1) < 1e-12)
        #expect(abs(projection.transformPoint(Vector3(0, 0, -10)).z - 1) < 1e-12)
        // A 90° view: a point as far up as it is in front is at the top.
        #expect(abs(projection.transformPoint(Vector3(0, 4, -4)).y - 1) < 1e-12)
    }

    @Test func anOrthographicViewKeepsSizeWithDistance() {
        let projection = Matrix4.orthographic(left: -2, right: 2, bottom: -1, top: 1, near: 0.1, far: 50)
        #expect(close(projection.transformPoint(Vector3(2, 1, -3)).onScreen, Vector3(1, 1, 0)))
        #expect(close(projection.transformPoint(Vector3(2, 1, -40)).onScreen, Vector3(1, 1, 0)))
    }

    @Test func anOrbitingCameraKeepsItsDistance() {
        let camera = Camera3D.orbit(around: Vector3(1, 0, 0), distance: 4, azimuth: 1.2, elevation: 0.5)
        #expect(abs((camera.position - Vector3(1, 0, 0)).length - 4) < 1e-12)
        #expect(camera.position.y > 0)
    }
}

private extension Vector3 {
    /// The vector with z dropped to 0: where it lands on the screen.
    var onScreen: Vector3 { Vector3(x, y, 0) }
}
