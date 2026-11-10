import Foundation
import Testing
@testable import TerminalUI
import TerminalUI3D

// A scene drawn into cells: what covers which cell, in which colour, and
// with which glyph, for each shading style.

private let theme = DarkTestTheme()

private func lightness(_ colour: Color?) -> Double {
    guard let rgb = colour?.nominalRGB else { return -1 }
    return Color.oklab(red: rgb.red, green: rgb.green, blue: rgb.blue).lightness
}

/// A scene with one model, seen from `distance` down the z axis.
private func scene(_ mesh: Mesh, transform: Matrix4 = .identity, materials: [Material] = [],
                   distance: Double = 5) -> Scene3D {
    var scene = Scene3D(camera: Camera3D(position: Vector3(0, 0, distance)))
    scene.add(mesh, transform: transform, materials: materials)
    return scene
}

@MainActor
private func draw(_ scene: Scene3D, _ shading: ShadingStyle, width: Int = 40, height: Int = 20,
                  theme: any Theme = theme) -> CellBuffer {
    renderedBuffer(SceneView(scene, shading: shading), width: width, height: height, theme: theme)
}

/// The colour a half-block cell shows in its top half.
private func topColour(_ cell: Cell) -> Color? {
    switch cell.character {
    case "\u{2580}": cell.style.foreground
    case "\u{2584}": cell.style.background
    default: cell.style.background
    }
}

@Suite("Scenes drawn into cells")
@MainActor
struct SceneRenderingTests {

    @Test func aCubeCoversTheMiddleAndNotTheCorners() {
        let buffer = draw(scene(.cube(size: 2), transform: Quaternion(axis: Vector3(1, 1, 0), angle: 0.6).matrix),
                          .halfBlock)
        #expect(topColour(buffer[20, 10]) != nil)
        #expect(buffer[0, 0].style.background == nil && buffer[0, 0].character == " ")
        #expect(buffer[39, 19].style.background == nil && buffer[39, 19].character == " ")
    }

    @Test func aTriangleFacingAwayIsCulledUnlessItsMaterialIsDoubleSided() {
        // Wound clockwise as the camera sees it: its back is toward it.
        let backward = Mesh(positions: [Vector3(-1, -1, 0), Vector3(0, 1, 0), Vector3(1, -1, 0)],
                            triangles: [Mesh.Triangle(0, 1, 2)])
        #expect(draw(scene(backward, materials: [Material(theme.accent)]), .halfBlock).drawnCells == 0)
        let doubleSided = draw(scene(backward, materials: [Material(theme.accent, isDoubleSided: true)]),
                               .halfBlock)
        #expect(doubleSided.drawnCells > 20)
    }

    @Test func theNearerSurfaceHidesTheFurther() {
        var both = Scene3D(camera: Camera3D(position: Vector3(0, 0, 6)))
        // The far box added last: drawn after, it must still lose.
        both.add(.cube(size: 1), transform: .translation(Vector3(0, 0, 1)),
                 materials: [Material(theme.accent, specular: 0)])
        both.add(.cube(size: 3), transform: .translation(Vector3(0, 0, -2)),
                 materials: [Material(theme.primary, specular: 0)])
        let middle = topColour(draw(both, .halfBlock)[20, 10])
        let accentOnly = topColour(draw(scene(.cube(size: 1), transform: .translation(Vector3(0, 0, 1)),
                                              materials: [Material(theme.accent, specular: 0)], distance: 6),
                                        .halfBlock)[20, 10])
        #expect(middle == accentOnly)
    }

    @Test func aTriangleThroughTheCameraIsCutAtTheNearPlane() {
        // From well behind the camera to well in front of it.
        let floor = Mesh(positions: [Vector3(-3, -1, 10), Vector3(3, -1, 10), Vector3(0, -1, -20)],
                         triangles: [Mesh.Triangle(0, 1, 2)])
        let buffer = draw(scene(floor, materials: [Material(theme.accent, isDoubleSided: true)]), .halfBlock)
        #expect(buffer.drawnCells > 0)
        #expect(topColour(buffer[20, 19]) != nil, "the floor reaches the foot of the view")
        #expect(topColour(buffer[20, 2]) == nil, "and nothing above the horizon")
    }

    @Test func aFaceTowardTheLightIsBrighterThanOneAway() {
        var lit = scene(.cube(size: 2), transform: Quaternion(axis: .unitY, angle: .pi / 4).matrix,
                        materials: [Material(theme.accent, specular: 0)])
        lit.lights = [.ambient(0.1), .directional(toward: Vector3(-1, 0, 0.2))]
        let buffer = draw(lit, .halfBlock)
        // The cube turned 45°: its left face toward the light, its right away.
        #expect(lightness(topColour(buffer[16, 10])) > lightness(topColour(buffer[24, 10])) + 0.2)
    }

    @Test func fogMixesWhatIsFarTowardTheBackground() {
        let near = scene(.cube(size: 1), materials: [Material(theme.accent, specular: 0)], distance: 3)
        var fogged = near
        fogged.fog = Fog3D(start: 0.5, end: 3, density: 1)
        let clear = lightness(topColour(draw(near, .halfBlock)[20, 10]))
        let hazy = lightness(topColour(draw(fogged, .halfBlock)[20, 10]))
        #expect(abs(hazy - lightness(theme.background)) < abs(clear - lightness(theme.background)))
    }

    @Test func aModelWithNoMaterialIsDrawnInTheAccent() {
        let plain = draw(scene(.cube(size: 2)), .halfBlock)
        let accent = draw(scene(.cube(size: 2), materials: [Material(theme.accent)]), .halfBlock)
        #expect(topColour(plain[20, 10]) == topColour(accent[20, 10]))
    }

    @Test func eachStyleDrawsWithItsOwnGlyphs() {
        let torus = scene(.torus(), transform: Quaternion(axis: .unitX, angle: 1.1).matrix,
                          materials: [Material(theme.accent)], distance: 3.4)
        let rampGlyphs = Set(CharacterRamp.standard.characters + ["|", "-", "_", "/", "\\"])

        let ramp = draw(torus, .characterRamp())
        let rampCells = ramp.allCells.filter { $0.character != " " }
        #expect(rampCells.count > 50)
        #expect(rampCells.allSatisfy { rampGlyphs.contains($0.character) && $0.style.background == nil })

        let braille = draw(torus, .braille()).allCells.filter { $0.character != " " }
        #expect(braille.count > 50)
        #expect(braille.allSatisfy { (0x2800...0x28FF).contains($0.character.unicodeScalars.first!.value) })

        let blocks = draw(torus, .halfBlock).allCells.filter { $0.style.background != nil || $0.character != " " }
        #expect(blocks.count > 50)
        #expect(blocks.allSatisfy { ["\u{2580}", "\u{2584}", " "].contains($0.character) })

        let hybrid = draw(torus, .hybrid()).allCells
        #expect(hybrid.contains { $0.style.background != nil && $0.character != " " },
                "a hybrid cell is a fill with a character over it")
    }

    @Test func outlinesDrawTheSilhouetteWithEdgeCharacters() {
        let sphere = scene(.sphere(), materials: [Material(theme.accent)], distance: 3.5)
        // Not "-", which the standard ramp shades with too.
        let edges: Set<Character> = ["|", "_", "/", "\\"]
        let outlined = draw(sphere, .characterRamp()).allCells.filter { edges.contains($0.character) }
        let plain = draw(sphere, .characterRamp().outlines(false)).allCells.filter { edges.contains($0.character) }
        #expect(outlined.count > 10)
        #expect(plain.count < outlined.count / 4)
        // Down the sides of a sphere the edge runs upright.
        let rows = draw(sphere, .characterRamp()).rowTexts
        let middle = rows.count / 2
        #expect(rows[middle].contains("|"), "\(rows)")
    }

    @Test func aRampReadsAsInkOnALightGround() {
        // A lit face is near the light ground and a shadowed one far from
        // it: in ink, the shadow is the denser.
        var lit = scene(.cube(size: 2), transform: Quaternion(axis: .unitY, angle: .pi / 4).matrix,
                        materials: [Material(LightTestTheme().accent, specular: 0)])
        lit.lights = [.ambient(0.1), .directional(toward: Vector3(-1, 0, 0.2))]
        let ramp = CharacterRamp.standard.characters
        func density(_ cell: Cell) -> Int { ramp.firstIndex(of: cell.character) ?? -1 }
        let dark = draw(lit, .characterRamp().outlines(false), theme: DarkTestTheme())
        let light = draw(lit, .characterRamp().outlines(false), theme: LightTestTheme())
        #expect(density(dark[16, 10]) > density(dark[24, 10]))
        #expect(density(light[16, 10]) < density(light[24, 10]))
    }

    @Test func aLabelShowsBesideItsPointUnlessSomethingHidesIt() {
        var open = Scene3D(camera: Camera3D(position: Vector3(0, 0, 6)))
        open.add(Label3D("peak", at: Vector3(0, 0, 0)))
        #expect(draw(open, .halfBlock).rowTexts.contains { $0.contains("peak") })

        var hidden = open
        hidden.add(.cube(size: 2), transform: .translation(Vector3(0, 0, 2)), materials: [Material(theme.accent)])
        #expect(!draw(hidden, .halfBlock).rowTexts.contains { $0.contains("peak") })

        var onSurface = Scene3D(camera: Camera3D(position: Vector3(0, 0, 6)))
        onSurface.add(.cube(size: 2), materials: [Material(theme.accent)])
        onSurface.add(Label3D("face", at: Vector3(0, 0, 1)))
        #expect(draw(onSurface, .halfBlock).rowTexts.contains { $0.contains("face") },
                "a point on a surface is not hidden by it")
    }

    @Test func labelsThatWouldOverlapGiveWayToTheFirst() {
        var crowded = Scene3D(camera: Camera3D(position: Vector3(0, 0, 6)))
        crowded.add(Label3D("first", at: Vector3(0, 0, 0)))
        for offset in [0.01, 0.02, 0.03, 0.04] {
            crowded.add(Label3D("later", at: Vector3(offset, 0, 0)))
        }
        let rows = draw(crowded, .halfBlock).rowTexts
        #expect(rows.contains { $0.contains("first") })
        #expect(rows.joined().components(separatedBy: "later").count - 1 < 4)
    }

    @Test func aRendererProjectsAPointWhereTheFrameDrewIt() throws {
        let renderer = SceneRenderer()
        let raster = CanvasRaster()
        raster.begin(width: 40, height: 20, inheritedGround: nil)
        var environment = EnvironmentValues()
        environment.theme = theme
        let context = GraphicsContext(raster: raster, environment: environment)
        #expect(renderer.project(.zero) == nil, "nothing is drawn yet")
        renderer.draw(Scene3D(camera: Camera3D(position: Vector3(0, 0, 5))), in: context,
                      size: CanvasSize(width: 40, height: 20), shading: .halfBlock)
        let centre = try #require(renderer.project(.zero))
        #expect(abs(centre.position.x - 20) < 1e-9 && abs(centre.position.y - 10) < 1e-9)
        #expect(abs(centre.depth - 5) < 1e-9)
        #expect(renderer.project(Vector3(0, 0, 9)) == nil, "behind the camera")
    }

    @Test func aSceneBackgroundFillsTheCanvas() {
        var scene = Scene3D()
        scene.background = theme.background
        let buffer = draw(scene, .characterRamp())
        #expect(buffer[0, 0].style.background == theme.background)
    }
}

private extension CellBuffer {
    var allCells: [Cell] {
        var cells: [Cell] = []
        for y in 0..<height {
            for x in 0..<width { cells.append(self[x, y]) }
        }
        return cells
    }
}
