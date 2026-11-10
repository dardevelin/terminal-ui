import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUI3D

// Easing, the turntable and the camera tour are pure functions of time;
// framing is a function of the scene and the view's shape. The image style
// is read through the cells it draws.

private let theme = DarkTestTheme()

@MainActor
private func draw(_ scene: Scene3D, _ shading: ShadingStyle, framing: SceneFraming = .camera,
                  width: Int = 60, height: Int = 20, theme: any Theme = theme) -> CellBuffer {
    renderedBuffer(SceneView(scene, shading: shading).framing(framing), width: width, height: height, theme: theme)
}

/// The columns and rows any cell draws in.
private func extent(_ buffer: CellBuffer) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
    var columns: [Int] = [], rows: [Int] = []
    for y in 0..<buffer.height {
        for x in 0..<buffer.width where buffer[x, y].character != " " || buffer[x, y].style.background != nil {
            columns.append(x)
            rows.append(y)
        }
    }
    guard let left = columns.min(), let right = columns.max(), let top = rows.min(), let bottom = rows.max()
    else { return nil }
    return (left...right, top...bottom)
}

@Suite("Motion, framing and the image style")
@MainActor
struct MotionAndFramingTests {

    @Test func smootherstepStartsAndStopsWithoutAJolt() {
        #expect(Easing.smootherstep(0) == 0 && Easing.smootherstep(1) == 1)
        #expect(Easing.smootherstep(0.5) == 0.5)
        #expect(Easing.smootherstep(-3) == 0 && Easing.smootherstep(4) == 1)
        // Its slope at the ends is nothing: a hundredth in, it has barely moved.
        #expect(Easing.smootherstep(0.01) < 1e-4)
        #expect(Easing.smoothstep(0.25) == 0.15625)
    }

    @Test func aTurntableTurnsWholeTurnsAndRestsBetween() {
        let table = Turntable(period: 4, turningShare: 0.75, wobble: 0, roll: 0)
        #expect(table.angle(at: 0) == 0)
        #expect(abs(table.angle(at: 1.5) - .pi) < 1e-12, "halfway through its turn, half a turn")
        // Resting from three seconds in to the end of the period.
        #expect(abs(table.angle(at: 3.2) - 2 * .pi) < 1e-12)
        #expect(abs(table.angle(at: 3.9) - 2 * .pi) < 1e-12)
        #expect(abs(table.angle(at: 5.5) - 3 * .pi) < 1e-12)
        let still = table.rotation(at: 3.5).rotate(.unitX)
        #expect((still - .unitX).length < 1e-9, "a whole turn and at rest")
    }

    @Test func aTurntableWobblesOnlyWhileTurning() {
        let table = Turntable(period: 4, turningShare: 0.75, wobble: 0.2, roll: 0)
        // A quarter turn in, the wobble tips the axis off vertical.
        let tipped = table.rotation(at: 0.75).rotate(.unitY)
        #expect(abs(tipped.y) < 1 - 1e-6)
        let atRest = table.rotation(at: 3.5).rotate(.unitY)
        #expect((atRest - .unitY).length < 1e-9)
    }

    @Test func aTourHoldsAtEachStopAndEasesBetween() {
        let tour = CameraTour([
            .init(Camera3D(position: Vector3(0, 0, 10)), hold: 1, travel: 2),
            .init(Camera3D(position: Vector3(10, 0, 0)), hold: 1, travel: 2),
        ])
        #expect(tour.duration == 6)
        #expect(tour.camera(at: 0.5).position == Vector3(0, 0, 10))
        #expect(tour.camera(at: 2).position == Vector3(5, 0, 5), "halfway there, eased to the middle")
        #expect(tour.camera(at: 3.5).position == Vector3(10, 0, 0))
        #expect(tour.camera(at: 6.5).position == Vector3(0, 0, 10), "and round again")
        let once = CameraTour(tour.stops, loops: false)
        #expect(once.camera(at: 50).position == Vector3(10, 0, 0))
    }

    @Test func fitFillsTheViewWithTheSceneAndKeepsItRound() throws {
        // A small sphere far off: through the camera as it is, a dot.
        var scene = Scene3D(camera: Camera3D(position: Vector3(0, 0, 40)))
        scene.add(.sphere(radius: 1), materials: [Material(theme.accent)])
        let distant = try #require(extent(draw(scene, .image())))
        #expect(distant.rows.count < 4)

        let fitted = try #require(extent(draw(scene, .image(), framing: .fit(padding: 1))))
        // One cell of padding top and bottom of twenty rows.
        #expect(fitted.rows.lowerBound <= 2 && fitted.rows.upperBound >= 17, "\(fitted)")
        // Round: as many rows tall as half as many columns wide.
        let across = Double(fitted.columns.count) / 2, down = Double(fitted.rows.count)
        #expect(abs(across - down) <= 2, "\(fitted)")
    }

    @Test func fitAimsAtTheSceneWhereverItIs() throws {
        var scene = Scene3D(camera: Camera3D(position: Vector3(0, 0, 10)))
        scene.add(.cube(size: 2), transform: .translation(Vector3(30, -12, 4)), materials: [Material(theme.accent)])
        #expect(extent(draw(scene, .image())) == nil, "off the view as the camera stands")
        let fitted = try #require(extent(draw(scene, .image(), framing: .fit())))
        #expect(fitted.columns.contains(30) && fitted.rows.contains(10))
    }

    @Test func fitKeepsAWideThingWide() throws {
        // A long flat bar: the fit is limited by its height, not a sphere
        // round its length, as long as the bar fits across.
        var scene = Scene3D(camera: Camera3D(position: Vector3(0, 0, 50)))
        scene.add(.box(width: 10, height: 1, depth: 1), materials: [Material(theme.accent)])
        let fitted = try #require(extent(draw(scene, .image(), framing: .fit(padding: 0), width: 120, height: 20)))
        #expect(fitted.columns.count > 60, "\(fitted)")
    }

    @Test func anOrthographicFitTakesTheHeightThatFits() throws {
        var scene = Scene3D(camera: Camera3D(position: Vector3(0, 0, 10), projection: .orthographic(height: 100)))
        scene.add(.sphere(radius: 1), materials: [Material(theme.accent)])
        let fitted = try #require(extent(draw(scene, .image(), framing: .fit(padding: 1))))
        #expect(fitted.rows.count >= 16)
    }

    @Test func theImageStyleIsTwoPixelsACellAndBlendsItsEdgeTowardAKnownGround() {
        var scene = Scene3D(camera: Camera3D(position: Vector3(0, 0, 5)))
        scene.add(.sphere(), materials: [Material(theme.accent, specular: 0)])
        let buffer = draw(scene, .image(), framing: .fit(padding: 1))
        var characters = Set<Character>()
        var blended = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let cell = buffer[x, y]
                characters.insert(cell.character)
                // An edge cell: its top or bottom colour between the
                // sphere's and the ground's.
                if cell.character == "\u{2580}", cell.style.background == theme.background
                    || cell.style.foreground == theme.background { blended += 1 }
            }
        }
        #expect(characters.isSubset(of: [" ", "\u{2580}"]), "\(characters)")
        #expect(!characters.contains { (0x2800...0x28FF).contains($0.unicodeScalars.first!.value) })
        #expect(blended > 0)
    }

    @Test func overAnUnknownGroundTheImageKeepsItsEdgeInDots() {
        struct TerminalGround: Theme {}
        var scene = Scene3D(camera: Camera3D(position: Vector3(0, 0, 5)))
        scene.add(.sphere(), materials: [Material(theme.accent)])
        let buffer = draw(scene, .image(), framing: .fit(padding: 1), theme: TerminalGround())
        var dots = 0, blocks = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let scalar = buffer[x, y].character.unicodeScalars.first!.value
                if (0x2801...0x28FF).contains(scalar) { dots += 1 }
                if buffer[x, y].character == "\u{2580}" || buffer[x, y].style.background != nil { blocks += 1 }
            }
        }
        #expect(dots > 5, "the outline in dots")
        #expect(blocks > dots, "the inside solid")
    }

    @Test func theDotsImageIsBrailleThroughout() {
        var scene = Scene3D(camera: Camera3D(position: Vector3(0, 0, 5)))
        scene.add(.sphere(), materials: [Material(theme.accent)])
        let buffer = draw(scene, .image(.dots), framing: .fit(padding: 1))
        for y in 0..<buffer.height {
            for x in 0..<buffer.width where buffer[x, y].character != " " {
                #expect((0x2800...0x28FF).contains(buffer[x, y].character.unicodeScalars.first!.value))
                #expect(buffer[x, y].style.background == nil)
            }
        }
        #expect(buffer.drawnCells > 50)
    }

    @Test func averagingIsDoneInLinearLight() {
        // Black and white samples average to the grey that looks halfway:
        // linear 0.5, sRGB 188 — not the 128 that averaging the bytes gives.
        #expect(LinearLight.byte((LinearLight.fromByte[0] + LinearLight.fromByte[255]) / 2) == 188)
        #expect(LinearLight.byte(LinearLight.fromByte[77]) == 77)
    }
}
