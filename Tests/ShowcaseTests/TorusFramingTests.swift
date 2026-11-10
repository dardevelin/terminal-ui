import Testing
import TerminalUI3D
@testable import Showcase

/// The 3D chapter's torus stays inside its view, clear of every edge by the
/// padding, through the whole of a turntable's turn: its wobble and roll
/// tip the ring past what a fit of any one pose leaves room for.
@Suite struct TorusFramingTests {
    /// Windows the torus is seen in: the recording's (800 × 450 at 13 px),
    /// the smoke harness's, a classic terminal's and a tall narrow one.
    static let windows: [(columns: Int, rows: Int)] = [(96, 23), (140, 39), (80, 23), (60, 40)]
    /// Moments a turn is sampled at.
    static let samples = 360
    /// Rounding the projection may carry past the padding.
    static let tolerance = 1e-9

    @Test(arguments: windows.indices)
    func theTorusStaysInsideThePaddingThroughAWholeTurn(window: Int) {
        let (columns, rows) = Self.windows[window]
        let camera = SceneChapter.torusCamera(columns: columns, rows: rows)
        // As the renderer projects: braille samples, two across a cell and
        // four down.
        let aspect = Double(columns * 2) / Double(rows * 4)
        let projection = Matrix4.perspective(fieldOfView: Projection3D.defaultFieldOfView, aspect: aspect,
                                             near: camera.near, far: camera.far)
        let viewProjection = projection * camera.viewMatrix
        let period = Turntable().period * 2
        var top = Double.infinity, bottom = -Double.infinity
        var left = Double.infinity, right = -Double.infinity
        for sample in 0..<Self.samples {
            let turn = SceneChapter.torusTurn(at: period * Double(sample) / Double(Self.samples)).matrix
            for position in SceneChapter.torusMesh.positions {
                let clip = viewProjection * Vector4(turn.transformPoint(position), 1)
                // Clip space to cells: x from the left edge, y from the top.
                let column = (clip.x / clip.w + 1) / 2 * Double(columns)
                let row = (1 - clip.y / clip.w) / 2 * Double(rows)
                top = min(top, row)
                bottom = max(bottom, row)
                left = min(left, column)
                right = max(right, column)
            }
        }
        let padding = SceneChapter.torusPadding
        #expect(top >= padding - Self.tolerance, "the torus reached row \(top) of \(rows)")
        #expect(bottom <= Double(rows) - padding + Self.tolerance, "the torus reached row \(bottom) of \(rows)")
        #expect(left >= 2 * padding - Self.tolerance, "the torus reached column \(left) of \(columns)")
        #expect(right <= Double(columns) - 2 * padding + Self.tolerance,
                "the torus reached column \(right) of \(columns)")
    }
}
