import Foundation
import TerminalUI
import TerminalUI3D

// The 3D pages: a torus, lettering and a terrain, each turning on its own
// through a TimelineView, each switchable between the shading styles and
// between the app's theme and a dark and a light one of the page's own.

/// What a 3D page shows.
enum Scene3DSubject {
    case torus, lettering, terrain
}

/// The styles the pages cycle through, in order.
let scene3DStyles: [ShadingStyle] = [.image(), .image(.dots), .halfBlock, .braille(), .hybrid(), .characterRamp(),
                                      .braille(.edges)]

/// The themes the pages cycle through: the app's own, and two whose
/// backgrounds the renderer can mix fog and edges toward.
enum Scene3DLook: Int, CaseIterable {
    case app, dark, light

    var name: String {
        switch self {
        case .app: "app"
        case .dark: "dark"
        case .light: "light"
        }
    }

    var theme: (any Theme)? {
        switch self {
        case .app: nil
        case .dark: Scene3DDarkTheme()
        case .light: Scene3DLightTheme()
        }
    }
}

/// A dark theme with a background of its own.
struct Scene3DDarkTheme: Theme {
    var background: Color = .rgb(22, 24, 32)
    var foreground: Color = .rgb(222, 224, 232)
    var foregroundEmphasis: Color = .rgb(245, 246, 250)
    var foregroundMuted: Color = .rgb(130, 128, 120)
    var accent: Color = .rgb(98, 178, 255)
    var primary: Color = .rgb(236, 142, 78)
    var success: Color = .rgb(92, 168, 88)
    var info: Color = .rgb(52, 112, 196)
}

/// A light theme with a background of its own.
struct Scene3DLightTheme: Theme {
    var background: Color = .rgb(246, 244, 238)
    var foreground: Color = .rgb(34, 34, 40)
    var foregroundEmphasis: Color = .rgb(250, 250, 252)
    var foregroundMuted: Color = .rgb(120, 112, 100)
    var accent: Color = .rgb(28, 98, 206)
    var primary: Color = .rgb(196, 92, 30)
    var success: Color = .rgb(70, 140, 64)
    var info: Color = .rgb(44, 100, 184)
}

/// A 3D page: its controls, and the scene beneath them.
struct Scene3DPage: TerminalView {
    let subject: Scene3DSubject
    let state: StorybookState
    @TerminalEnvironment(\.theme) var appTheme
    @TerminalEnvironment(\.terminalSize) var terminalSize

    var body: some TerminalView {
        let style = scene3DStyles[state.scene3DStyle % scene3DStyles.count]
        let look = Scene3DLook(rawValue: state.scene3DLook % Scene3DLook.allCases.count) ?? .app
        // The theme is always set, the app's own included: a branch that
        // set it only for the page's themes would rebuild the page as the
        // theme changed, and drop the focus off its controls.
        let theme = look.theme ?? appTheme
        return VStack(spacing: 0) {
            Text("style ‹\(style.name)›  theme ‹\(look.name)›  \(state.scene3DPaused ? "paused" : "turning")")
                .foreground(.cyan)
                .focusable()
                .onKeyPress { [state] key in
                    switch key.key {
                    case .character("s"), .right:
                        state.scene3DStyle += 1
                    case .left:
                        state.scene3DStyle += scene3DStyles.count - 1
                    case .character("t"):
                        state.scene3DLook += 1
                    case .character(" "), .activate:
                        state.scene3DPaused.toggle()
                    default:
                        return .ignored
                    }
                    return .handled
                }
            Text("s/←→ style · t theme · space pause").foreground(.gray)
            Scene3DPreview(subject: subject, shading: style, paused: state.scene3DPaused,
                           paintsBackground: look != .app)
                .frame(height: Scene3DPreview.height(in: terminalSize.rows))
        }
        .environment(\.theme, theme)
    }
}

/// The scene itself, built from the timeline's date.
struct Scene3DPreview: TerminalView {
    /// The rows the page's title, code and frame take from the window; the
    /// scene has the rest, and never fewer than `leastHeight`.
    static let chromeRows = 22
    static let leastHeight = 12

    static func height(in windowRows: Int) -> Int {
        max(leastHeight, windowRows - chromeRows)
    }

    /// Twenty frames a second, as the Codex CLI's animation runs: smooth to
    /// the eye, and a third of the bytes of sixty over a slow link.
    static let frameInterval = 1.0 / 20.0

    let subject: Scene3DSubject
    let shading: ShadingStyle
    let paused: Bool
    let paintsBackground: Bool
    @TerminalEnvironment(\.theme) var theme

    var body: some TerminalView {
        let theme = theme
        let subject = subject, shading = shading, paintsBackground = paintsBackground
        return TimelineView(.animation(minimumInterval: Scene3DPreview.frameInterval, paused: paused)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas3D(shading: shading) { scene, _ in
                if paintsBackground { scene.background = theme.background }
                switch subject {
                case .torus: Scene3DPreview.torus(&scene, at: seconds, theme: theme)
                case .lettering: Scene3DPreview.lettering(&scene, at: seconds, theme: theme)
                case .terrain: Scene3DPreview.terrain(&scene, at: seconds, theme: theme)
                }
            }
            .framing(subject == .terrain ? .camera : .fit(padding: 1))
        }
    }

    // MARK: Torus

    static let torusMesh = Mesh.torus(majorRadius: 1, minorRadius: 0.42, majorSegments: 64, minorSegments: 28)

    /// The ring stood on its edge, so a turn about the vertical shows it
    /// face on, then edge on.
    static let standing = Quaternion(axis: .unitX, angle: .pi / 2)

    static func torus(_ scene: inout Scene3D, at seconds: Double, theme: any Theme) {
        scene.camera = Camera3D(position: Vector3(0, 0.6, 4))
        let turn = Turntable().rotation(at: seconds) * Quaternion(axis: .unitZ, angle: 0.35) * standing
        scene.add(torusMesh, transform: turn.matrix,
                  materials: [Material(theme.accent, specular: 0.9, shininess: 36)])
    }

    // MARK: Lettering

    static let wordmark = Text3D("TERMINAL\nUI", depth: 4)

    static func lettering(_ scene: inout Scene3D, at seconds: Double, theme: any Theme) {
        // A long lens, so the wordmark's near end does not loom as it turns.
        scene.camera = Camera3D(position: Vector3(0, 0, 80), projection: .perspective(fieldOfView: .pi / 9))
        let turn = Turntable(period: 4.8).rotation(at: seconds)
        scene.add(wordmark.mesh, transform: turn.matrix,
                  materials: [Material(theme.accent, specular: 0.8, shininess: 30),
                              Material(theme.primary, specular: 0.3)])
    }

    // MARK: Terrain

    static let terrainColumns = 71
    static let terrainSpacing = 0.2
    static let waterLevel = 0.35
    static let terrainHeights: [Double] = {
        var heights: [Double] = []
        for row in 0..<terrainColumns {
            for column in 0..<terrainColumns {
                let x = Double(column) / Double(terrainColumns - 1) * 4
                let y = Double(row) / Double(terrainColumns - 1) * 4
                heights.append(max(waterLevel, ValueNoise.fractal(x: x, y: y) * 2.6 - 0.2))
            }
        }
        return heights
    }()

    static let terrainMesh: Mesh = {
        var mesh = Mesh.heightField(columns: terrainColumns, rows: terrainColumns, spacing: terrainSpacing,
                                    heights: terrainHeights)
        // Triangles wholly at the water line are lakes: a material of their own.
        mesh.triangles = mesh.triangles.map { triangle in
            let flat = [triangle.first, triangle.second, triangle.third]
                .allSatisfy { mesh.positions[$0].y <= waterLevel }
            return Mesh.Triangle(triangle.first, triangle.second, triangle.third, material: flat ? 1 : 0)
        }
        return mesh
    }()

    /// The three highest points far enough apart to be peaks of their own.
    static let peaks: [Vector3] = {
        let order = terrainMesh.positions.indices.sorted { terrainMesh.positions[$0].y > terrainMesh.positions[$1].y }
        var chosen: [Vector3] = []
        for index in order {
            let point = terrainMesh.positions[index]
            if chosen.allSatisfy({ ($0 - point).length > 3 }) { chosen.append(point) }
            if chosen.count == 3 { break }
        }
        return chosen
    }()

    static let peakNames = ["Summit", "Watch Hill", "Grey Tor"]

    /// Out over the lakes, low along the valley, and up over the ridge.
    static let flyover = CameraTour([
        .init(Camera3D(position: Vector3(0, 6, 11), target: Vector3(0, 0.5, 0)), hold: 1.5, travel: 5),
        .init(Camera3D(position: Vector3(8, 2.2, 3), target: Vector3(-1, 0.8, -2)), hold: 1, travel: 5),
        .init(Camera3D(position: Vector3(-3, 1.8, -8), target: Vector3(1, 1, 1)), hold: 1, travel: 5),
        .init(Camera3D(position: Vector3(-9, 5, 4), target: Vector3(0, 0.5, 0)), hold: 1, travel: 5),
    ])

    static func terrain(_ scene: inout Scene3D, at seconds: Double, theme: any Theme) {
        scene.camera = flyover.camera(at: seconds)
        scene.fog = Fog3D(start: 6, end: 17, density: 0.8)
        scene.lights = [.ambient(0.18), .directional(toward: Vector3(-0.6, 0.7, 0.3), intensity: 0.9), .rim(0.2)]
        scene.add(terrainMesh, materials: [
            Material(gradient: [theme.info, theme.success, theme.success, theme.foregroundMuted,
                                theme.foregroundEmphasis], specular: 0.08),
            Material(theme.info, specular: 0.9, shininess: 40),
        ])
        for (peak, name) in zip(peaks, peakNames) {
            scene.add(Label3D(name, at: peak + Vector3(0, 0.05, 0), bold: true))
        }
    }
}

/// Smooth noise on a lattice of hashed values, summed over octaves —
/// Perlin's fractal sum ("An Image Synthesizer", SIGGRAPH 1985) over value
/// noise — for a terrain that looks like ground and is the same on every run.
enum ValueNoise {
    static func fractal(x: Double, y: Double) -> Double {
        var total = 0.0, amplitude = 0.5, frequency = 1.0, weight = 0.0
        for _ in 0..<5 {
            total += amplitude * value(x: x * frequency, y: y * frequency)
            weight += amplitude
            amplitude *= 0.5
            frequency *= 2.03
        }
        return total / weight
    }

    private static func value(x: Double, y: Double) -> Double {
        let column = x.rounded(.down), row = y.rounded(.down)
        let across = smooth(x - column), down = smooth(y - row)
        let cornerX = Int(column), cornerY = Int(row)
        let top = lattice(cornerX, cornerY) + (lattice(cornerX + 1, cornerY) - lattice(cornerX, cornerY)) * across
        let bottom = lattice(cornerX, cornerY + 1)
            + (lattice(cornerX + 1, cornerY + 1) - lattice(cornerX, cornerY + 1)) * across
        return top + (bottom - top) * down
    }

    /// Hermite smoothstep, 3t² − 2t³: no crease where cells meet.
    private static func smooth(_ fraction: Double) -> Double {
        fraction * fraction * (3 - 2 * fraction)
    }

    /// A value in 0...1 for a lattice point, by an integer hash (the
    /// multipliers are large odd constants, mixed as in MurmurHash3's
    /// finaliser).
    private static func lattice(_ column: Int, _ row: Int) -> Double {
        var hash = UInt64(bitPattern: Int64(column)) &* 0x9E37_79B9_7F4A_7C15
            ^ UInt64(bitPattern: Int64(row)) &* 0xC2B2_AE3D_27D4_EB4F
        hash ^= hash >> 33
        hash &*= 0xFF51_AFD7_ED55_8CCD
        hash ^= hash >> 33
        return Double(hash & 0xFFFF) / Double(0xFFFF)
    }
}
