import Foundation
import TerminalUI
import TerminalUI3D

// What a 3D frame costs, in the build it is run in — run it in release:
//
//     swift run -c release SceneBenchmark
//
// Each frame is what a running app does for a SceneView whose scene moved:
// the graph updated from the new view, laid out, and drawn into a 200 × 60
// cell buffer — the rasterizer, lighting, edges, the shading style's
// resolve into the canvas's planes and their composite into cells. Writing
// the frame to a terminal is not counted.

let columns = 200
let rows = 60
let frameCount = 300
let framesPerSecond = 60.0

struct BenchmarkTheme: Theme {
    var background: Color = .rgb(22, 24, 32)
    var foreground: Color = .rgb(222, 224, 232)
    var accent: Color = .rgb(98, 178, 255)
    var primary: Color = .rgb(236, 142, 78)
    var success: Color = .rgb(92, 168, 88)
}

let theme = BenchmarkTheme()
let torus = Mesh.torus(majorRadius: 1, minorRadius: 0.42, majorSegments: 64, minorSegments: 28)
let wordmark = Text3D("TERMINALUI", depth: 4)
let ground = Mesh.heightField(columns: 71, rows: 71, spacing: 0.2) { column, row in
    sin(Double(column) * 0.21) * cos(Double(row) * 0.17) * 1.2 + sin(Double(column + row) * 0.07)
}

func torusAndText(_ frame: Int) -> Scene3D {
    let angle = Double(frame) / framesPerSecond
    var scene = Scene3D(camera: Camera3D(position: Vector3(0, 0, 60), projection: .perspective(fieldOfView: 0.6),
                                         far: 200),
                        background: theme.background)
    scene.add(wordmark.mesh, transform: Matrix4.translation(Vector3(0, -7, 0))
                * Quaternion(axis: .unitY, angle: sin(angle) * 0.5).matrix,
              materials: [Material(theme.accent), Material(theme.primary)])
    scene.add(torus, transform: Matrix4.translation(Vector3(0, 7, 0)) * Matrix4.scale(7)
                * (Quaternion(axis: .unitX, angle: angle) * Quaternion(axis: .unitY, angle: angle * 1.3)).matrix,
              materials: [Material(theme.accent, specular: 0.6)])
    return scene
}

func terrain(_ frame: Int) -> Scene3D {
    var scene = Scene3D(camera: .orbit(around: .zero, distance: 10, azimuth: Double(frame) / 120, elevation: 0.45),
                        background: theme.background)
    scene.fog = Fog3D(start: 6, end: 17)
    scene.add(ground, materials: [Material(gradient: [theme.accent, theme.success, theme.foreground])])
    scene.add(Label3D("peak", at: Vector3(0, 2, 0)))
    return scene
}

/// Milliseconds per frame, the mean and the slowest, drawing `scene` in
/// `shading`.
@MainActor
func measure(_ shading: ShadingStyle, scene: (Int) -> Scene3D) -> (mean: Double, worst: Double) {
    let graph = AttributeGraph()
    var buffer = CellBuffer(width: columns, height: rows)
    let rect = Rect(x: 0, y: 0, width: columns, height: rows)
    var environment = EnvironmentValues()
    environment.theme = theme
    func frame(_ index: Int) {
        GraphContext.$currentEnvironment.withValue(environment) {
            GraphContext.$currentProposedSize.withValue(Size(width: columns, height: rows)) {
                graph.update(from: SceneView(scene(index), shading: shading))
                guard let root = graph.root else { return }
                Layout.measureAndPlace(graph: root, in: rect)
                buffer.clear()
                GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
            }
        }
    }
    frame(0)
    let clock = ContinuousClock()
    var total = Duration.zero, worst = Duration.zero
    for index in 1...frameCount {
        let elapsed = clock.measure { frame(index) }
        total += elapsed
        worst = max(worst, elapsed)
    }
    func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return (Double(seconds) + Double(attoseconds) / 1e18) * 1000
    }
    return (milliseconds(total) / Double(frameCount), milliseconds(worst))
}

let styles: [ShadingStyle] = [.image(), .image(.dots), .halfBlock, .braille(), .hybrid(), .characterRamp()]
print("\(columns) × \(rows) cells, \(frameCount) frames each; a 60 fps frame has \(String(format: "%.1f", 1000 / framesPerSecond)) ms")
print("torus + Text3D: \(torus.triangles.count + wordmark.mesh.triangles.count) triangles; "
      + "height field: \(ground.triangles.count) triangles")
for style in styles {
    let both = measure(style, scene: torusAndText)
    let land = measure(style, scene: terrain)
    // No `%@`: a Swift string is not a C variadic argument on Linux.
    let name = style.name.padding(toLength: 11, withPad: " ", startingAt: 0)
    print(name + String(format: "  torus + text %.2f ms (worst %.2f)   height field %.2f ms (worst %.2f)",
                        both.mean, both.worst, land.mean, land.worst))
}
