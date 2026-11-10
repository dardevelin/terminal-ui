import Foundation
import Observation
import Testing
@testable import TerminalUI
import TerminalUI3D

// The examples of TerminalUI3D.docc's "Drawing a scene", as written there:
// each must build, and draw something.

private struct Ring: TerminalView {
    @TerminalEnvironment(\.theme) var theme

    var body: some TerminalView {
        let theme = theme
        var scene = Scene3D(camera: Camera3D(position: Vector3(0, 1.5, 4)))
        scene.add(.torus(), materials: [Material(theme.accent, specular: 0.8)])
        return SceneView(scene)
            .framing(.fit())
            .frame(height: 20)
    }
}

@Observable
private final class Survey {
    var heading = 0.4
    var summit = Vector3(0, 1, 0)
}

private struct Terrain: TerminalView {
    let model: Survey
    @TerminalEnvironment(\.theme) var theme
    static let terrain = Mesh.heightField(columns: 8, rows: 8, spacing: 1) { column, row in
        sin(Double(column)) * cos(Double(row))
    }

    var body: some TerminalView {
        let theme = theme, model = model, terrain = Self.terrain
        return SceneView { scene in
            scene.camera = .orbit(around: .zero, distance: 8, azimuth: model.heading, elevation: 0.5)
            scene.add(terrain, materials: [Material(gradient: [theme.info, theme.success, theme.foreground])])
            scene.add(Label3D("summit", at: model.summit))
        }
    }
}

private struct Turning: TerminalView {
    @TerminalEnvironment(\.theme) var theme

    var body: some TerminalView {
        let theme = theme
        return TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            SceneView { scene in
                scene.add(.torus(), transform: Turntable().rotation(at: seconds).matrix,
                          materials: [Material(theme.accent, specular: 0.9, shininess: 36)])
            }
            .framing(.fit())
        }
    }
}

@Suite("The documentation's examples")
@MainActor
struct DocumentationExampleTests {

    @Test func aRingIsOnScreen() {
        #expect(renderedBuffer(Ring(), width: 60, height: 20, theme: DarkTestTheme()).drawnCells > 100)
    }

    @Test func aSceneBuiltInAClosureDrawsItsLabel() {
        let buffer = renderedBuffer(Terrain(model: Survey()), width: 60, height: 20, theme: DarkTestTheme())
        #expect(buffer.drawnCells > 100)
        #expect(buffer.rowTexts.contains { $0.contains("summit") })
    }

    @Test func aTimelineTurnsTheRing() {
        #expect(renderedBuffer(Turning(), width: 60, height: 20, theme: DarkTestTheme()).drawnCells > 100)
    }

    @Test func theOtherExamplesBuild() {
        var scene = Scene3D()
        scene.lights = [.ambient(0.15), .directional(toward: Vector3(-0.4, 0.8, 0.6)), .rim(0.4)]
        let seconds = 2.5
        let tour = CameraTour([
            .init(Camera3D(position: Vector3(0, 6, 11)), hold: 1.5, travel: 5),
            .init(Camera3D(position: Vector3(8, 2, 3), target: Vector3(-1, 0.8, -2)), hold: 1, travel: 5),
        ])
        scene.camera = tour.camera(at: seconds)
        scene.add(.sphere(), materials: [Material(DarkTestTheme().accent)])
        let view = SceneView(scene, shading: .characterRamp(.detailed).outlines(false))
        #expect(renderedBuffer(view, width: 40, height: 20, theme: DarkTestTheme()).drawnCells > 0)
    }
}
