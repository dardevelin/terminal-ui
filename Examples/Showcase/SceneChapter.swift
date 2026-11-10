import Foundation
import TerminalUI
import TerminalUI3D

/// The 3D chapter: the wordmark turning into view, the torus filling the
/// screen as an image with its highlight sliding, the same torus in two
/// other shading styles, and a flight over a fogged, labelled terrain.
struct SceneChapter: TerminalView {
    /// Seconds into the chapter.
    let time: Double
    @TerminalEnvironment(\.theme) var theme

    // MARK: The score

    static let title = Cue(from: 0.4, to: 5.2)
    static let torus = Cue(from: 5.2, to: 11.9)
    static let terrain = Cue(from: 11.9, to: 17.6)
    static let duration = 17.9

    /// How long each scene takes to come out of the ground and go back.
    static let titleFade = 0.7
    static let torusFade = 0.5
    static let terrainFade = 0.9

    /// The torus as an image, then in braille dots, then in characters.
    static let torusStyles: [(cue: Cue, name: String, style: ShadingStyle)] = [
        (Cue(from: torus.start, to: 9.4), ".image()", .image()),
        (Cue(from: 9.4, to: 10.6), ".braille()", .braille()),
        (Cue(from: 10.6, to: torus.end), ".characterRamp(.detailed)", .characterRamp(.detailed)),
    ]

    var body: some TerminalView {
        let theme = theme
        let time = time
        let (caption, detail, shading) = Self.captions(at: time)
        let presence = Self.presence(at: time)
        return VStack(spacing: 0) {
            SceneView(shading: shading) { scene in
                scene.background = theme.background
                if Self.title.contains(time) {
                    Self.title(&scene, at: time - Self.title.start, theme: theme)
                } else if Self.torus.contains(time) {
                    Self.torus(&scene, at: time - Self.torus.start, theme: theme)
                } else if Self.terrain.contains(time) {
                    Self.terrain(&scene, at: time - Self.terrain.start, theme: theme)
                }
            }
            .framing(Self.framing(at: time))
            HStack(spacing: 0) {
                Text("TerminalUI3D").bold().foreground(theme.accent.blended(with: theme.background, amount: 1 - presence))
                Text("  " + caption).foreground(theme.foregroundMuted.blended(with: theme.background, amount: 1 - presence))
                Spacer()
                Text(detail).foreground(theme.foregroundMuted.blended(with: theme.background, amount: 1 - presence))
            }
            .padding(.horizontal, 2)
        }
    }

    /// What the caption says under the scene showing at `time`, what its
    /// right-hand side says, and the style the scene is drawn in.
    static func captions(at time: Double) -> (String, String, ShadingStyle) {
        if title.contains(time) || time < title.start {
            return ("Text3D · Turntable", "lit, shaded 3D in a terminal", .image())
        }
        if torus.contains(time) {
            let current = torusStyles.first { $0.cue.contains(time) } ?? torusStyles[0]
            return ("SceneView · Mesh.torus · Turntable", "shading: " + current.name, current.style)
        }
        return ("Mesh.heightField · CameraTour · Fog3D · Label3D", "depth-tested labels", .image())
    }

    /// How present the scene showing at `time` is, 0 to 1.
    static func presence(at time: Double) -> Double {
        if title.contains(time) { return title.presence(at: time, fade: titleFade) }
        if torus.contains(time) { return torus.presence(at: time, fade: torusFade) }
        if terrain.contains(time) { return terrain.presence(at: time, fade: terrainFade) }
        return 0
    }

    static func framing(at time: Double) -> SceneFraming {
        if title.contains(time) {
            // In from further off as it turns, so it arrives as well as turns.
            let approach = Cue(from: title.start, to: title.start + titleTurnLength).eased(at: time, .easeOut)
            return .fit(padding: mix(titlePaddingFar, titlePaddingNear, approach))
        }
        if torus.contains(time) { return .fit(padding: torusPadding) }
        return .camera
    }

    /// A scene coming out of the ground or going back into it: haze of the
    /// background's colour over everything, as thick as the scene is absent.
    static func veil(_ presence: Double) -> Fog3D? {
        presence < 1 ? Fog3D(start: 0, end: veilDepth, density: 1 - presence) : nil
    }

    /// Where the veil is at its thickest: at once, in front of everything.
    static let veilDepth = 1e-3

    // MARK: Title

    static let wordmark = Text3D("TERMINALUI", depth: 3)

    /// The wordmark makes the last part of one weighted turn, from about
    /// edge on to face on, its wobble settling as it comes to rest.
    static let titleTurn = Turntable(period: 6.4, turningShare: 1, wobble: 0.16, roll: 0.05)
    /// How far through the turn it is when it appears: about edge on.
    static let titleTurnFrom = 0.62
    static var titleTurnLength: Double { (1 - titleTurnFrom) * titleTurn.period }
    static let titlePaddingFar = 9.0
    static let titlePaddingNear = 3.0
    /// When the light sweeps across the wordmark's faces, once it rests.
    static let titleSweep = Cue(from: 2.2, to: 4.2)

    static func title(_ scene: inout Scene3D, at seconds: Double, theme: any Theme) {
        // A wide lens, so a light sweeping across the faces lands on each
        // letter at a different moment and the highlight slides along them.
        scene.camera = Camera3D(position: Vector3(0, 0, 60), projection: .perspective(fieldOfView: .pi / 5))
        let turn = titleTurn.rotation(at: (titleTurnFrom * titleTurn.period) + min(seconds, titleTurnLength))
        let sweep = titleSweep.eased(at: seconds)
        scene.lights = [
            .ambient(0.22),
            .directional(toward: Vector3(mix(-0.9, 0.9, sweep), 0.35, 0.65), intensity: 0.85),
            .directional(toward: Vector3(0.5, -0.3, 0.6), intensity: 0.2),
            .rim(0.35),
        ]
        scene.fog = veil(title.presence(at: seconds + title.start, fade: titleFade))
        scene.add(wordmark.mesh, transform: turn.matrix, materials: [
            Material(theme.accent, specular: 0.9, shininess: 16),
            Material(theme.secondary, specular: 0.3),
        ])
    }

    // MARK: Torus

    /// The ring, its tint running once round it and back, so a gradient
    /// material colours it with no seam.
    static let torusMesh: Mesh = {
        var mesh = Mesh.torus(majorRadius: 1, minorRadius: 0.42, majorSegments: 72, minorSegments: 32)
        mesh.tints = mesh.positions.map { position in 0.5 + 0.5 * cos(atan2(position.z, position.x)) }
        return mesh
    }()

    /// Stood on its edge, so a turn about the vertical shows it face on,
    /// then edge on.
    static let standing = Quaternion(axis: .unitZ, angle: 0.35) * Quaternion(axis: .unitX, angle: .pi / 2)
    static let torusPadding = 0.0
    /// Radians a second the key light swings back and forth at.
    static let lightSwing = 0.9

    static func torus(_ scene: inout Scene3D, at seconds: Double, theme: any Theme) {
        scene.camera = Camera3D(position: Vector3(0, 0.6, 4))
        let swing = sin(seconds * lightSwing)
        scene.lights = [
            .ambient(0.16),
            .directional(toward: Vector3(0.8 * swing, 0.6, 0.6), intensity: 0.9),
            .directional(toward: Vector3(-0.6 * swing, -0.4, 0.5), intensity: 0.18),
            .rim(0.4),
        ]
        scene.fog = veil(torus.presence(at: seconds + torus.start, fade: torusFade))
        let turn = Turntable().rotation(at: seconds) * standing
        scene.add(torusMesh, transform: turn.matrix, materials: [
            Material(gradient: [theme.accent, theme.secondary, theme.error], specular: 0.9, shininess: 40),
        ])
    }

    // MARK: Terrain

    static let terrainColumns = 81
    static let terrainSpacing = 0.18
    static let waterLevel = 0.35
    /// Noise lattice cells across the terrain.
    static let terrainScale = 4.0
    static let reliefHeight = 2.6
    static let reliefOffset = 0.2

    static let terrainMesh: Mesh = {
        var heights: [Double] = []
        for row in 0..<terrainColumns {
            for column in 0..<terrainColumns {
                let x = Double(column) / Double(terrainColumns - 1) * terrainScale
                let y = Double(row) / Double(terrainColumns - 1) * terrainScale
                heights.append(max(waterLevel, ValueNoise.fractal(x: x, y: y) * reliefHeight - reliefOffset))
            }
        }
        var mesh = Mesh.heightField(columns: terrainColumns, rows: terrainColumns, spacing: terrainSpacing,
                                    heights: heights)
        // Triangles wholly at the water line are lakes: a material of their own.
        mesh.triangles = mesh.triangles.map { triangle in
            let flat = [triangle.first, triangle.second, triangle.third]
                .allSatisfy { mesh.positions[$0].y <= waterLevel }
            return Mesh.Triangle(triangle.first, triangle.second, triangle.third, material: flat ? 1 : 0)
        }
        return mesh
    }()

    /// The highest points far enough apart to be peaks of their own.
    static let peaks: [Vector3] = {
        let order = terrainMesh.positions.indices.sorted { terrainMesh.positions[$0].y > terrainMesh.positions[$1].y }
        var chosen: [Vector3] = []
        for index in order {
            let point = terrainMesh.positions[index]
            if chosen.allSatisfy({ ($0 - point).length > peakSeparation }) { chosen.append(point) }
            if chosen.count == peakNames.count { break }
        }
        return chosen
    }()

    static let peakSeparation = 3.0
    static let peakNames = ["Summit", "Watch Hill", "Grey Tor"]

    /// High over the lakes, then down and round to look along the valley at
    /// the peaks, easing out of the one stop and into the other.
    static let flight = CameraTour([
        .init(Camera3D(position: Vector3(0, 7.5, 12.5), target: Vector3(0, 0.4, 0)), hold: 0.8, travel: 3.0),
        .init(Camera3D(position: Vector3(8, 3.4, 4), target: Vector3(-1, 0.8, -2)), hold: 2),
    ], loops: false)

    /// The haze over the far ground, once the terrain is in.
    static let haze = Fog3D(start: 6, end: 17, density: 0.8)

    static func terrain(_ scene: inout Scene3D, at seconds: Double, theme: any Theme) {
        scene.camera = flight.camera(at: seconds)
        let presence = terrain.presence(at: seconds + terrain.start, fade: terrainFade)
        // The haze lifts off the ground as the scene comes in: from a wall
        // at the camera back to the far distance.
        scene.fog = Fog3D(start: mix(0, haze.start, presence), end: mix(veilDepth, haze.end, presence),
                          density: mix(1, haze.density, presence))
        scene.lights = [.ambient(0.18), .directional(toward: Vector3(-0.6, 0.7, 0.3), intensity: 0.95), .rim(0.2)]
        scene.add(terrainMesh, materials: [
            Material(gradient: [theme.info, theme.success, theme.success, theme.foregroundMuted,
                                theme.foregroundEmphasis], specular: 0.08),
            Material(theme.info, specular: 0.9, shininess: 40),
        ])
        let ink = theme.foreground.blended(with: theme.background, amount: 1 - presence)
        for (peak, name) in zip(peaks, peakNames) {
            scene.add(Label3D(name, at: peak + Vector3(0, labelLift, 0), colour: ink, bold: true))
        }
    }

    /// How far above a peak its label's point sits.
    static let labelLift = 0.05
}

/// Smooth noise on a lattice of hashed values, summed over octaves —
/// Perlin's fractal sum ("An Image Synthesizer", SIGGRAPH 1985) over value
/// noise — for a terrain that looks like ground and is the same on every run.
enum ValueNoise {
    static let octaves = 5
    /// Each octave's frequency over the last: a little off 2, so the
    /// octaves' lattices never line up.
    static let lacunarity = 2.03
    /// Each octave's amplitude over the last.
    static let persistence = 0.5

    static func fractal(x: Double, y: Double) -> Double {
        var total = 0.0, amplitude = 0.5, frequency = 1.0, weight = 0.0
        for _ in 0..<octaves {
            total += amplitude * value(x: x * frequency, y: y * frequency)
            weight += amplitude
            amplitude *= persistence
            frequency *= lacunarity
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
