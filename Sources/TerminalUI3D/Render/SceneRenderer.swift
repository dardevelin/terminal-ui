import Foundation
import TerminalUI

/// Draws a ``Scene3D`` into a canvas, and keeps what it draws with — its
/// sample buffers, its shaded palettes — from frame to frame, so a frame
/// allocates nothing per sample. A ``SceneView`` holds one for as long as it
/// is on screen.
///
/// The scene is rendered at braille resolution — two samples across a cell
/// and four down, about square on a terminal's cells — with a depth buffer,
/// back faces culled and triangles cut at the near plane. Each sample is
/// then lit once, by the scene's lights, and fogged by its depth; the
/// silhouette and creases are found where coverage, depth or the surface's
/// direction jumps between neighbours; and the ``ShadingStyle`` turns the
/// samples into cells.
///
/// Package access: TerminalUIMaps draws a realistic map's buildings with it,
/// over the map it has drawn.
package final class SceneRenderer {
    let rasterizer = SceneRasterizer()
    let tone = SampleBuffer<Float>(0)
    private let fog = SampleBuffer<Float>(0)
    /// ``EdgeKind`` bits per sample.
    private let edges = SampleBuffer<UInt8>(0)
    /// Which way across each edge sample the discontinuity lies.
    private let edgeGradientX = SampleBuffer<Float>(0)
    private let edgeGradientY = SampleBuffer<Float>(0)
    /// Each covered sample's lit colour, `0xRRGGBB`.
    private let colours = SampleBuffer<UInt32>(0)
    /// The ground in linear light, when it is a colour: what a cell's bare
    /// part is mixed toward.
    private var groundLinear: (red: Float, green: Float, blue: Float)?

    private var palettes: [ShadePalette] = []
    private var paletteMaterials: [Material] = []
    private var paletteGround: Color?
    private var frameMaterials: [Material] = []
    private var doubleSided: [Bool] = []
    private var specular: [Float] = []
    private var shininess: [Float] = []
    private var emission: [Float] = []

    /// The last frame's transform from the scene to clip space, and its
    /// size in samples: what ``project(_:)`` maps through.
    private var lastViewProjection = Matrix4.identity
    private var lastView = Matrix4.identity
    private var lastSampleWidth = 0
    private var lastSampleHeight = 0

    package init() {}

    // MARK: - Drawing

    /// Draw `scene` into `context`, over a canvas of `size` cells, in
    /// `shading`, placed by `framing`.
    package func draw(_ scene: Scene3D, in context: GraphicsContext, size: CanvasSize,
                      shading: ShadingStyle = .image(), framing: SceneFraming = .camera) {
        let columns = Int(size.width.rounded(.down)), rows = Int(size.height.rounded(.down))
        guard columns > 0, rows > 0 else { return }
        let sampleWidth = columns * Grid.columnsPerCell, sampleHeight = rows * Grid.rowsPerCell
        let theme = context.environment.theme

        if let background = scene.background {
            context.fill(CanvasRect(x: 0, y: 0, width: Double(columns), height: Double(rows)),
                         with: .color(background))
        }
        let ground = scene.background ?? theme.background
        preparePalettes(for: scene, ground: ground, fallback: theme.accent)
        groundLinear = ground.nominalRGB.map {
            (LinearLight.fromByte[Int($0.red)], LinearLight.fromByte[Int($0.green)], LinearLight.fromByte[Int($0.blue)])
        }

        let camera = framing.camera(for: scene, columns: columns, rows: rows)
        rasterizer.begin(width: sampleWidth, height: sampleHeight, far: camera.far)
        let view = camera.viewMatrix
        let aspect = Double(sampleWidth) / Double(sampleHeight)
        let projection = camera.projection.matrix(aspect: aspect, near: camera.near, far: camera.far)
        lastView = view
        lastViewProjection = projection * view
        lastSampleWidth = sampleWidth
        lastSampleHeight = sampleHeight

        var materialBase = 0
        for model in scene.models {
            let count = max(1, model.materials.count)
            // Past the most materials a sample can name, the rest of the
            // scene's models have no palette to be drawn in.
            guard materialBase + count <= doubleSided.count else { break }
            rasterizer.draw(model, modelView: view * model.transform, projection: projection,
                            materials: materialBase..<(materialBase + count), doubleSided: doubleSided)
            materialBase += count
        }

        light(scene, view: view, projection: projection, perspective: camera.projection.isPerspective)
        if shading.needsEdges {
            findEdges()
        } else {
            edges.reset(count: sampleWidth * sampleHeight, to: 0)
        }

        switch shading.kind {
        case .image, .halfBlock:
            colourise(darkeningCreases: shading.drawsOutlines)
        default:
            break
        }

        switch shading.kind {
        case .image(let fill):
            resolveImage(fill, columns: columns, rows: rows, into: context)
        case .characterRamp(let ramp):
            resolveRamp(ramp, columns: columns, rows: rows, outlines: shading.drawsOutlines, into: context)
        case .halfBlock:
            resolveHalfBlocks(columns: columns, rows: rows, into: context)
        case .braille(let fill):
            resolveBraille(fill, columns: columns, rows: rows, outlines: shading.drawsOutlines, into: context)
        case .hybrid(let ramp):
            resolveHybrid(ramp, columns: columns, rows: rows, outlines: shading.drawsOutlines, into: context)
        }
        placeLabels(scene.labels, columns: columns, rows: rows, theme: theme, into: context)
    }

    /// How far from the eye, along the view, the nearest surface the last
    /// frame drew at a sample lies — braille dots, two across a cell and
    /// four down — or nil where none covers it. What a caller drawing over
    /// the scene tests its own points against: TerminalUIMaps hides a road
    /// behind a hill so.
    package func depth(atSampleX x: Int, y: Int) -> Double? {
        guard x >= 0, y >= 0, x < rasterizer.width, y < rasterizer.height else { return nil }
        let index = y * rasterizer.width + x
        guard rasterizer.material.pointer[index] != SceneRasterizer.uncovered else { return nil }
        return Double(rasterizer.depth.pointer[index])
    }

    /// Where `point` in the scene fell on the last frame drawn, in cells
    /// from the canvas's top-left corner, and how far in front of the camera
    /// it is — or nil when it is behind the camera or no frame has been
    /// drawn. Labels are placed with it.
    func project(_ point: Vector3) -> (position: CanvasPoint, depth: Double)? {
        guard lastSampleWidth > 0, lastSampleHeight > 0 else { return nil }
        let clip = lastViewProjection * Vector4(point, 1)
        guard clip.w > 0 else { return nil }
        let viewPoint = lastView * Vector4(point, 1)
        let normalisedX = clip.x / clip.w, normalisedY = clip.y / clip.w
        let sampleX = (normalisedX + 1) / 2 * Double(lastSampleWidth)
        let sampleY = (1 - normalisedY) / 2 * Double(lastSampleHeight)
        return (CanvasPoint(x: sampleX / Double(Grid.columnsPerCell), y: sampleY / Double(Grid.rowsPerCell)),
                -viewPoint.z)
    }

    // MARK: - Materials

    private func preparePalettes(for scene: Scene3D, ground: Color, fallback: Color) {
        frameMaterials.removeAll(keepingCapacity: true)
        for model in scene.models {
            if model.materials.isEmpty {
                frameMaterials.append(Material(fallback))
            } else {
                frameMaterials.append(contentsOf: model.materials)
            }
        }
        if frameMaterials.count > Int(SceneRasterizer.uncovered) {
            frameMaterials.removeLast(frameMaterials.count - Int(SceneRasterizer.uncovered))
        }
        if frameMaterials != paletteMaterials || ground != paletteGround {
            // A palette whose material and ground are unchanged keeps the
            // colours it has worked out.
            var reused: [ShadePalette] = []
            for material in frameMaterials {
                if let existing = palettes.first(where: { $0.material == material && $0.background == ground }) {
                    reused.append(existing)
                } else {
                    reused.append(ShadePalette(material: material, background: ground))
                }
            }
            palettes = reused
            paletteMaterials = frameMaterials
            paletteGround = ground
        }
        doubleSided = frameMaterials.map(\.isDoubleSided)
        specular = frameMaterials.map { Float(min(1, max(0, $0.specular))) }
        shininess = frameMaterials.map { Float(max(1, $0.shininess)) }
        emission = frameMaterials.map { Float($0.emission) }
    }

    // MARK: - Lighting

    private func light(_ scene: Scene3D, view: Matrix4, projection: Matrix4, perspective: Bool) {
        let width = rasterizer.width, height = rasterizer.height
        let count = width * height
        tone.reset(count: count, to: 0)
        fog.reset(count: count, to: 0)

        var ambient: Float = 0
        var directions: [(x: Float, y: Float, z: Float, intensity: Float)] = []
        var rims: [(intensity: Float, power: Float)] = []
        for light in scene.lights {
            switch light.kind {
            case .ambient:
                ambient += Float(light.intensity)
            case .directional(let direction):
                let toward = view.transformDirection(direction).normalized
                directions.append((Float(toward.x), Float(toward.y), Float(toward.z), Float(light.intensity)))
            case .rim(let power):
                rims.append((Float(light.intensity), Float(max(0, power))))
            }
        }
        let fogStart = Float(scene.fog?.start ?? 0)
        let fogSpan = Float(max(Double.ulpOfOne, (scene.fog?.end ?? 1) - (scene.fog?.start ?? 0)))
        let fogDensity = Float(min(1, max(0, scene.fog?.density ?? 0)))
        let hasFog = scene.fog != nil && fogDensity > 0
        // The view ray through a sample: x and y in normalised device
        // coordinates over the projection's focal scales, z = −1.
        let rayScaleX = perspective ? Float(1 / projection.column0.x) : 0
        let rayScaleY = perspective ? Float(1 / projection.column1.y) : 0

        let depth = rasterizer.depth.pointer, materials = rasterizer.material.pointer
        let normalXs = rasterizer.normalX.pointer, normalYs = rasterizer.normalY.pointer
        let normalZs = rasterizer.normalZ.pointer
        let tonePointer = tone.pointer, fogPointer = fog.pointer
        let maximumTone = ShadePalette.maximumTone
        for row in 0..<height {
            let rayY = (1 - (Float(row) + 0.5) / Float(height) * 2) * rayScaleY
            for column in 0..<width {
                let index = row * width + column
                let material = Int(materials[index])
                guard material != Int(SceneRasterizer.uncovered) else { continue }
                var normalX = normalXs[index], normalY = normalYs[index], normalZ = normalZs[index]
                let length = (normalX * normalX + normalY * normalY + normalZ * normalZ).squareRoot()
                if length > 0 {
                    normalX /= length
                    normalY /= length
                    normalZ /= length
                }
                // Toward the eye: back along the view ray.
                var viewX: Float = 0, viewY: Float = 0, viewZ: Float = 1
                if perspective {
                    let rayX = ((Float(column) + 0.5) / Float(width) * 2 - 1) * rayScaleX
                    let rayLength = (rayX * rayX + rayY * rayY + 1).squareRoot()
                    viewX = -rayX / rayLength
                    viewY = -rayY / rayLength
                    viewZ = 1 / rayLength
                }
                let facing = max(0, normalX * viewX + normalY * viewY + normalZ * viewZ)
                var lit = ambient + emission[material]
                let shine = specular[material], exponent = shininess[material]
                for light in directions {
                    let diffuse = normalX * light.x + normalY * light.y + normalZ * light.z
                    guard diffuse > 0 else { continue }
                    lit += diffuse * light.intensity
                    if shine > 0 {
                        var halfX = light.x + viewX, halfY = light.y + viewY, halfZ = light.z + viewZ
                        let halfLength = (halfX * halfX + halfY * halfY + halfZ * halfZ).squareRoot()
                        if halfLength > 0 {
                            halfX /= halfLength
                            halfY /= halfLength
                            halfZ /= halfLength
                        }
                        let alignment = max(0, normalX * halfX + normalY * halfY + normalZ * halfZ)
                        // Blinn–Phong ("Models of Light Reflection for
                        // Computer Synthesized Pictures", SIGGRAPH 1977): a
                        // true power, so a high exponent gives a small
                        // highlight that visibly travels as the model turns.
                        // Its strength is Schlick's Fresnel ("An Inexpensive
                        // BRDF Model for Physically-based Rendering",
                        // Eurographics 1994), F₀ + (1 − F₀)(1 − h·v)⁵ with the
                        // material's specular as F₀: a surface shines more
                        // as the light grazes it toward the eye.
                        if alignment > 0 {
                            let grazing = 1 - max(0, halfX * viewX + halfY * viewY + halfZ * viewZ)
                            let squared = grazing * grazing
                            let fresnel = shine + (1 - shine) * squared * squared * grazing
                            lit += fresnel * pow(alignment, exponent) * light.intensity
                        }
                    }
                }
                for rim in rims {
                    lit += rim.intensity * Self.power(1 - facing, rim.power)
                }
                tonePointer[index] = min(maximumTone, lit)
                if hasFog {
                    fogPointer[index] = min(1, max(0, (depth[index] - fogStart) / fogSpan)) * fogDensity
                }
            }
        }
    }

    /// `base` to the `exponent`, by multiplication for the small whole
    /// powers a rim light is given.
    @inline(__always)
    private static func power(_ base: Float, _ exponent: Float) -> Float {
        switch exponent {
        case 1: return base
        case 2: return base * base
        case 3: return base * base * base
        case 4:
            let square = base * base
            return square * square
        default: return pow(base, exponent)
        }
    }

    // MARK: - Edges

    /// What makes a sample an edge.
    enum EdgeKind {
        /// The shape ends beside it.
        static let silhouette: UInt8 = 1
        /// The surface folds, or another lies far behind it.
        static let crease: UInt8 = 2
    }

    /// Depth that jumps by more than this share of the nearer depth between
    /// neighbouring samples is one surface in front of another.
    static let depthEdgeShare: Float = 0.12
    /// Normals further apart than this cosine — about 50° — meet at a crease.
    static let creaseCosine: Float = 0.64

    private func findEdges() {
        let width = rasterizer.width, height = rasterizer.height
        let count = width * height
        edges.reset(count: count, to: 0)
        edgeGradientX.reset(count: count, to: 0)
        edgeGradientY.reset(count: count, to: 0)
        let depth = rasterizer.depth.pointer, materials = rasterizer.material.pointer
        let normalX = rasterizer.normalX.pointer, normalY = rasterizer.normalY.pointer
        let normalZ = rasterizer.normalZ.pointer
        let flags = edges.pointer, gradientX = edgeGradientX.pointer, gradientY = edgeGradientY.pointer
        let uncovered = SceneRasterizer.uncovered
        // Each pair of neighbours once: right, down, and the two diagonals
        // below. Every flagged sample's gradient points toward the far side.
        let offsets: [(Int, Int)] = [(1, 0), (0, 1), (1, 1), (-1, 1)]

        @inline(__always)
        func mark(_ index: Int, _ kind: UInt8, _ towardX: Float, _ towardY: Float) {
            flags[index] |= kind
            gradientX[index] += towardX
            gradientY[index] += towardY
        }

        for row in 0..<height {
            for column in 0..<width {
                let index = row * width + column
                let covered = materials[index] != uncovered
                for (offsetX, offsetY) in offsets {
                    let neighbourColumn = column + offsetX, neighbourRow = row + offsetY
                    guard neighbourColumn >= 0, neighbourColumn < width, neighbourRow < height else { continue }
                    let neighbour = neighbourRow * width + neighbourColumn
                    let neighbourCovered = materials[neighbour] != uncovered
                    let towardX = Float(offsetX), towardY = Float(offsetY)
                    switch (covered, neighbourCovered) {
                    case (false, false):
                        continue
                    case (true, false):
                        mark(index, EdgeKind.silhouette, towardX, towardY)
                    case (false, true):
                        mark(neighbour, EdgeKind.silhouette, -towardX, -towardY)
                    case (true, true):
                        let near = min(depth[index], depth[neighbour])
                        if abs(depth[index] - depth[neighbour]) > Self.depthEdgeShare * near {
                            if depth[index] < depth[neighbour] {
                                mark(index, EdgeKind.crease, towardX, towardY)
                            } else {
                                mark(neighbour, EdgeKind.crease, -towardX, -towardY)
                            }
                            continue
                        }
                        let alignment = (normalX[index] * normalX[neighbour] + normalY[index] * normalY[neighbour]
                                         + normalZ[index] * normalZ[neighbour])
                        let lengths = ((normalX[index] * normalX[index] + normalY[index] * normalY[index]
                                        + normalZ[index] * normalZ[index])
                                       * (normalX[neighbour] * normalX[neighbour]
                                          + normalY[neighbour] * normalY[neighbour]
                                          + normalZ[neighbour] * normalZ[neighbour])).squareRoot()
                        if lengths > 0, alignment < Self.creaseCosine * lengths {
                            mark(index, EdgeKind.crease, towardX, towardY)
                            mark(neighbour, EdgeKind.crease, -towardX, -towardY)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Cells

    /// The sample grid's shape within a cell.
    enum Grid {
        static let columnsPerCell = 2
        static let rowsPerCell = 4
        static let samplesPerCell = columnsPerCell * rowsPerCell
        /// Sample rows in each half of a cell.
        static let rowsPerHalf = 2
        /// Samples in each half of a cell.
        static let samplesPerHalf = columnsPerCell * rowsPerHalf
    }

    /// What the samples of a block — a cell, or half of one — add up to.
    struct BlockSummary {
        var covered = 0
        var tone: Float = 0
        var fog: Float = 0
        var tint: Float = 0
        /// The material of the nearest sample.
        var material = Int(SceneRasterizer.uncovered)
        var nearest = Float.infinity
        var silhouettes = 0
        var creases = 0
        var gradientX: Float = 0
        var gradientY: Float = 0
        /// Sum of the rows, within the block, of its edge samples.
        var edgeRows = 0

        var edgeCount: Int { max(silhouettes, creases) }
    }

    @inline(__always)
    private func summarise(column: Int, row: Int, columns: Int, rows: Int) -> BlockSummary {
        var summary = BlockSummary()
        let width = rasterizer.width
        let materials = rasterizer.material.pointer, depth = rasterizer.depth.pointer
        let tonePointer = tone.pointer, fogPointer = fog.pointer, tintPointer = rasterizer.tint.pointer
        let flags = edges.pointer, gradientX = edgeGradientX.pointer, gradientY = edgeGradientY.pointer
        for sampleRow in 0..<rows {
            let base = (row + sampleRow) * width + column
            for sampleColumn in 0..<columns {
                let index = base + sampleColumn
                let material = materials[index]
                guard material != SceneRasterizer.uncovered else { continue }
                summary.covered += 1
                summary.tone += tonePointer[index]
                summary.fog += fogPointer[index]
                summary.tint += tintPointer[index]
                if depth[index] < summary.nearest {
                    summary.nearest = depth[index]
                    summary.material = Int(material)
                }
                let flag = flags[index]
                if flag != 0 {
                    if flag & EdgeKind.silhouette != 0 { summary.silhouettes += 1 }
                    if flag & EdgeKind.crease != 0 { summary.creases += 1 }
                    // Doubled angles, so gradients pointing either way
                    // across the same line add up rather than cancel.
                    let towardX = gradientX[index], towardY = gradientY[index]
                    summary.gradientX += towardX * towardX - towardY * towardY
                    summary.gradientY += 2 * towardX * towardY
                    summary.edgeRows += sampleRow
                }
            }
        }
        if summary.covered > 0 {
            let share = 1 / Float(summary.covered)
            summary.tone *= share
            summary.fog *= share
            summary.tint *= share
        }
        return summary
    }

    /// The character an edge across a cell is drawn with, from the doubled
    /// angle of the direction across it.
    private static func edgeGlyph(_ summary: BlockSummary) -> Character {
        // Halving the doubled angle: the line across which the change is.
        let angle = atan2(summary.gradientY, summary.gradientX) / 2
        let acrossX = cos(angle), acrossY = sin(angle)
        // Within 22.5° of an axis it is that axis; tan 22.5° = √2 − 1.
        let axisLimit: Float = 0.414_213_56
        if abs(acrossY) <= axisLimit * abs(acrossX) { return "|" }
        if abs(acrossX) <= axisLimit * abs(acrossY) {
            let meanRow = Float(summary.edgeRows) / Float(max(1, summary.edgeCount))
            return meanRow >= Float(Grid.rowsPerCell) / 2 ? "_" : "-"
        }
        // Across toward the lower right, y down: the line runs up to the right.
        return acrossX * acrossY > 0 ? "/" : "\\"
    }

    /// The fewest edge samples in a cell that make it an edge rather than
    /// a corner grazed.
    private static let edgeSamplesPerCell = 2
    /// How far an edge character's tone is pushed away from the cell's to
    /// stand out: brighter over a dark ground, darker over a light one.
    private static let edgeToneLift: Float = 0.7
    private static let edgeToneDrop: Float = 0.3
    /// Over a ground nothing can be mixed toward, a half cell the shape
    /// covers less of than this is left bare rather than drawn whole.
    private static let majorityCoverage: Float = 0.5
    /// How dark a half-block crease is drawn, as a share of its tone.
    private static let creaseShade: Float = 0.45

    private func resolveRamp(_ ramp: CharacterRamp, columns: Int, rows: Int, outlines: Bool,
                             into context: GraphicsContext) {
        let characters = ramp.characters
        context.drawCells(columns: columns, rows: rows) { column, row in
            let summary = summarise(column: column * Grid.columnsPerCell, row: row * Grid.rowsPerCell,
                                    columns: Grid.columnsPerCell, rows: Grid.rowsPerCell)
            guard summary.covered > 0 else { return nil }
            return rampCell(summary, characters: characters, outlines: outlines)
        }
    }

    /// A cell as the ramp style draws it: an edge character where an edge
    /// crosses it, otherwise a ramp character by how far its shade stands
    /// out from the ground and how much of it the shape covers.
    @inline(__always)
    private func rampCell(_ summary: BlockSummary, characters: [Character], outlines: Bool) -> CanvasCell? {
        let palette = palettes[summary.material]
        if outlines, summary.edgeCount >= Self.edgeSamplesPerCell {
            let edgeTone = palette.groundIsDark ? summary.tone + Self.edgeToneLift : summary.tone * Self.edgeToneDrop
            let index = palette.index(tone: edgeTone, tint: summary.tint, fog: summary.fog)
            return CanvasCell(Self.edgeGlyph(summary), foreground: palette.colour(at: index))
        }
        let index = palette.index(tone: summary.tone, tint: summary.tint, fog: summary.fog)
        let coverage = Float(summary.covered) / Float(Grid.samplesPerCell)
        var level = Int((palette.contrast(at: index) * coverage * Float(characters.count - 1)).rounded())
        if summary.covered >= Self.edgeSamplesPerCell { level = max(1, level) }
        guard level > 0 else { return nil }
        return CanvasCell(characters[min(level, characters.count - 1)], foreground: palette.colour(at: index))
    }

    /// How far a hybrid cell's fill is mixed toward the ground: a dim
    /// version of the shade, so the character over it in the full shade
    /// stands out on any ground.
    private static let fillGroundShare: Float = 0.55
    /// The fewest of a cell's eight samples the shape must cover for a
    /// hybrid cell to be filled.
    private static let fillCoverage = 6
    /// How dark a hybrid cell's fill is drawn, as a share of its tone,
    /// where the ground is the terminal's own and nothing can be mixed
    /// toward it.
    private static let fillToneShare: Float = 0.35

    private func resolveHybrid(_ ramp: CharacterRamp, columns: Int, rows: Int, outlines: Bool,
                               into context: GraphicsContext) {
        let characters = ramp.characters
        let steps = Float(characters.count - 1)
        context.drawCells(columns: columns, rows: rows) { column, row in
            let summary = summarise(column: column * Grid.columnsPerCell, row: row * Grid.rowsPerCell,
                                    columns: Grid.columnsPerCell, rows: Grid.rowsPerCell)
            guard summary.covered > 0 else { return nil }
            // Where the shape's edge leaves much of the cell bare, a fill
            // would square the outline off: the character alone draws it.
            guard summary.covered >= Self.fillCoverage else {
                return rampCell(summary, characters: characters, outlines: outlines)
            }
            let palette = palettes[summary.material]
            let fill: Color
            if palette.mixesTowardGround {
                let groundShare = 1 - (1 - summary.fog) * (1 - Self.fillGroundShare)
                fill = palette.colour(at: palette.index(tone: summary.tone, tint: summary.tint, fog: groundShare))
            } else {
                fill = palette.colour(at: palette.index(tone: summary.tone * Self.fillToneShare,
                                                        tint: summary.tint, fog: summary.fog))
            }
            let index = palette.index(tone: summary.tone, tint: summary.tint, fog: summary.fog)
            if outlines, summary.edgeCount >= Self.edgeSamplesPerCell {
                let edgeTone = palette.groundIsDark ? summary.tone + Self.edgeToneLift
                                                    : summary.tone * Self.edgeToneDrop
                let edge = palette.colour(at: palette.index(tone: edgeTone, tint: summary.tint, fog: summary.fog))
                return CanvasCell(Self.edgeGlyph(summary), foreground: edge, background: fill)
            }
            let level = max(1, Int((palette.contrast(at: index) * steps).rounded()))
            return CanvasCell(characters[min(level, characters.count - 1)], foreground: palette.colour(at: index),
                              background: fill)
        }
    }

    /// Every covered sample's colour, looked up once: the image styles
    /// average colours, not tones, so a cell across two materials, or a
    /// gradient, is the mix of what is there.
    private func colourise(darkeningCreases: Bool) {
        let count = rasterizer.width * rasterizer.height
        colours.reset(count: count, to: 0)
        let materials = rasterizer.material.pointer, flags = edges.pointer
        let tonePointer = tone.pointer, fogPointer = fog.pointer, tintPointer = rasterizer.tint.pointer
        let output = colours.pointer
        var currentMaterial = -1
        var palette: ShadePalette?
        for index in 0..<count {
            let material = Int(materials[index])
            guard material != Int(SceneRasterizer.uncovered) else { continue }
            if material != currentMaterial {
                currentMaterial = material
                palette = palettes[material]
            }
            guard let palette else { continue }
            var shade = tonePointer[index]
            if darkeningCreases, flags[index] & EdgeKind.crease != 0 { shade *= Self.creaseShade }
            output[index] = palette.packedColour(at: palette.index(tone: shade, tint: tintPointer[index],
                                                                  fog: fogPointer[index]))
        }
    }

    /// Linear-light sums of some samples' colours.
    struct LightSum {
        var red: Float = 0
        var green: Float = 0
        var blue: Float = 0
        var count = 0

        @inline(__always)
        mutating func merge(_ other: LightSum) {
            red += other.red
            green += other.green
            blue += other.blue
            count += other.count
        }

        @inline(__always)
        mutating func add(_ packed: UInt32) {
            red += LinearLight.fromByte[Int(packed >> 16 & 0xFF)]
            green += LinearLight.fromByte[Int(packed >> 8 & 0xFF)]
            blue += LinearLight.fromByte[Int(packed & 0xFF)]
            count += 1
        }

        /// The mean colour, with `bare` more shares of `ground` mixed in.
        func colour(bare: Int = 0, ground: (red: Float, green: Float, blue: Float)? = nil) -> Color {
            var red = self.red, green = self.green, blue = self.blue, shares = count
            if bare > 0, let ground {
                red += ground.red * Float(bare)
                green += ground.green * Float(bare)
                blue += ground.blue * Float(bare)
                shares += bare
            }
            let scale = 1 / Float(max(1, shares))
            return .rgb(LinearLight.byte(red * scale), LinearLight.byte(green * scale), LinearLight.byte(blue * scale))
        }
    }

    /// The upper half block, whose foreground is a cell's top half and
    /// background its bottom (U+2580).
    static let upperHalf: Character = "\u{2580}"

    private func resolveImage(_ fill: ShadingStyle.ImageFill, columns: Int, rows: Int,
                              into context: GraphicsContext) {
        let width = rasterizer.width
        let materials = rasterizer.material.pointer, samples = colours.pointer
        let uncovered = SceneRasterizer.uncovered
        let ground = groundLinear
        context.drawCells(columns: columns, rows: rows) { column, row in
            var upper = LightSum(), lower = LightSum()
            var pattern: UInt32 = 0
            let firstRow = row * Grid.rowsPerCell, firstColumn = column * Grid.columnsPerCell
            for dotRow in 0..<Grid.rowsPerCell {
                for dotColumn in 0..<Grid.columnsPerCell {
                    let index = (firstRow + dotRow) * width + firstColumn + dotColumn
                    guard materials[index] != uncovered else { continue }
                    pattern |= Self.brailleBits[dotRow * Grid.columnsPerCell + dotColumn]
                    if dotRow < Grid.rowsPerHalf {
                        upper.add(samples[index])
                    } else {
                        lower.add(samples[index])
                    }
                }
            }
            let covered = upper.count + lower.count
            guard covered > 0 else { return nil }
            // A cell the shape covers whole, or any cell over a ground the
            // renderer can mix toward, is two pixels, each its samples'
            // mean with the bare part the ground's. A cell at the edge over
            // a ground it cannot know keeps the edge's shape in dots.
            guard fill == .solid, covered == Grid.samplesPerCell || ground != nil else {
                var all = upper
                all.merge(lower)
                return Self.brailleCell(pattern, all.colour())
            }
            let top = upper.colour(bare: Grid.samplesPerHalf - upper.count, ground: ground)
            let bottom = lower.colour(bare: Grid.samplesPerHalf - lower.count, ground: ground)
            return top == bottom ? CanvasCell(" ", background: top)
                                 : CanvasCell(Self.upperHalf, foreground: top, background: bottom)
        }
    }

    @inline(__always)
    private static func brailleCell(_ pattern: UInt32, _ colour: Color) -> CanvasCell? {
        guard let scalar = Unicode.Scalar(brailleBase + pattern) else { return nil }
        return CanvasCell(Character(scalar), foreground: colour)
    }

    private func resolveHalfBlocks(columns: Int, rows: Int, into context: GraphicsContext) {
        let width = rasterizer.width
        let materials = rasterizer.material.pointer, samples = colours.pointer
        let uncovered = SceneRasterizer.uncovered
        let ground = groundLinear
        context.fillHalfCells(columns: columns, halfRows: rows * 2) { column, halfRow in
            var sum = LightSum()
            let firstRow = halfRow * Grid.rowsPerHalf, firstColumn = column * Grid.columnsPerCell
            for sampleRow in 0..<Grid.rowsPerHalf {
                for sampleColumn in 0..<Grid.columnsPerCell {
                    let index = (firstRow + sampleRow) * width + firstColumn + sampleColumn
                    if materials[index] != uncovered { sum.add(samples[index]) }
                }
            }
            guard sum.count > 0 else { return nil }
            // The part the shape leaves bare is the ground's: mixed in where
            // the ground is a colour, and where it is not, a half cell the
            // shape covers less than half of is left bare.
            if ground == nil, Float(sum.count) / Float(Grid.samplesPerHalf) < Self.majorityCoverage { return nil }
            return sum.colour(bare: Grid.samplesPerHalf - sum.count, ground: ground)
        }
    }

    /// Thresholds for ordered dithering over a cell's 2 × 4 dots: the first
    /// two columns of Bayer's 4 × 4 matrix, in sixteenths ("An optimum
    /// method for two-level rendition of continuous-tone pictures", ICC
    /// 1973), indexed `row * 2 + column`.
    private static let ditherThresholds: [Float] = [0, 8, 12, 4, 3, 11, 15, 7].map { ($0 + 0.5) / 16 }
    /// The bit each dot sets in a braille pattern, indexed `row * 2 +
    /// column`: dots 1 4 / 2 5 / 3 6 / 7 8 (Unicode, U+2800 block).
    private static let brailleBits: [UInt32] = [0x01, 0x08, 0x02, 0x10, 0x04, 0x20, 0x40, 0x80]
    private static let brailleBase: UInt32 = 0x2800

    private func resolveBraille(_ fill: ShadingStyle.BrailleFill, columns: Int, rows: Int, outlines: Bool,
                                into context: GraphicsContext) {
        let width = rasterizer.width
        let materials = rasterizer.material.pointer
        let tonePointer = tone.pointer, fogPointer = fog.pointer, tintPointer = rasterizer.tint.pointer
        let flags = edges.pointer
        context.drawCells(columns: columns, rows: rows) { column, row in
            let summary = summarise(column: column * Grid.columnsPerCell, row: row * Grid.rowsPerCell,
                                    columns: Grid.columnsPerCell, rows: Grid.rowsPerCell)
            guard summary.covered > 0 else { return nil }
            let palette = palettes[summary.material]
            var pattern: UInt32 = 0
            for dotRow in 0..<Grid.rowsPerCell {
                for dotColumn in 0..<Grid.columnsPerCell {
                    let index = (row * Grid.rowsPerCell + dotRow) * width + column * Grid.columnsPerCell + dotColumn
                    let material = materials[index]
                    guard material != SceneRasterizer.uncovered else { continue }
                    let dot = dotRow * Grid.columnsPerCell + dotColumn
                    let lit: Bool
                    switch fill {
                    case .silhouette:
                        lit = true
                    case .edges:
                        lit = flags[index] != 0
                    case .dithered:
                        if outlines, flags[index] != 0 {
                            lit = true
                        } else {
                            let samplePalette = palettes[Int(material)]
                            let sampleIndex = samplePalette.index(tone: tonePointer[index],
                                                                  tint: tintPointer[index], fog: fogPointer[index])
                            lit = samplePalette.contrast(at: sampleIndex) > Self.ditherThresholds[dot]
                        }
                    }
                    if lit { pattern |= Self.brailleBits[dot] }
                }
            }
            guard pattern != 0, let scalar = Unicode.Scalar(Self.brailleBase + pattern) else { return nil }
            var shade = summary.tone
            if fill == .edges {
                // A line a dot thin reads only in a strong colour: bright
                // over a dark ground, dark over a light one.
                shade = palette.groundIsDark ? max(shade, 1) : min(shade, Self.edgeToneDrop)
            }
            let index = palette.index(tone: shade, tint: summary.tint, fog: summary.fog)
            return CanvasCell(Character(scalar), foreground: palette.colour(at: index))
        }
    }

    // MARK: - Labels

    /// How much nearer than a label's point a surface must be to hide it,
    /// as a share of the point's depth: a point on a surface is not hidden
    /// by that surface.
    static let occlusionShare: Float = 0.04
    /// The mark drawn on a labelled point.
    static let pointMark = "\u{2022}"

    private func placeLabels(_ labels: [Label3D], columns: Int, rows: Int, theme: any Theme,
                             into context: GraphicsContext) {
        guard !labels.isEmpty else { return }
        var taken: [(left: Int, top: Int, right: Int, bottom: Int)] = []
        func free(_ left: Int, _ top: Int, _ width: Int) -> Bool {
            guard left >= 0, top >= 0, left + width <= columns, top < rows else { return false }
            // A cell of room either side, so two labels never read as one.
            for rect in taken where top <= rect.bottom && top >= rect.top
                && left - 1 <= rect.right && left + width + 1 > rect.left {
                return false
            }
            return true
        }
        for label in labels {
            guard let projected = project(label.position), projected.depth > 0 else { continue }
            let cellX = Int(projected.position.x.rounded(.down)), cellY = Int(projected.position.y.rounded(.down))
            guard cellX >= 0, cellX < columns, cellY >= 0, cellY < rows, isVisible(projected) else { continue }
            let width = label.text.displayWidth
            let candidates = [(cellX + 1, cellY), (cellX - width, cellY),
                              (cellX - width / 2, cellY - 1), (cellX - width / 2, cellY + 1)]
            guard let spot = candidates.first(where: { free($0.0, $0.1, width) }) else { continue }
            taken.append((spot.0, spot.1, spot.0 + width - 1, spot.1))
            taken.append((cellX, cellY, cellX, cellY))
            let colour = label.colour ?? theme.foreground
            if label.marksPoint {
                context.draw(Text(TextSpan(Self.pointMark, foreground: colour, bold: true)),
                             at: CanvasPoint(x: Double(cellX), y: Double(cellY)), anchor: .topLeading)
            }
            context.draw(Text(TextSpan(label.text, foreground: colour, bold: label.bold)),
                         at: CanvasPoint(x: Double(spot.0), y: Double(spot.1)), anchor: .topLeading)
        }
    }

    /// Whether nothing stands in front of a projected point: some sample
    /// round it is no nearer than the point, or covers nothing.
    private func isVisible(_ projected: (position: CanvasPoint, depth: Double)) -> Bool {
        let width = rasterizer.width, height = rasterizer.height
        let centreX = Int((projected.position.x * Double(Grid.columnsPerCell)).rounded(.down))
        let centreY = Int((projected.position.y * Double(Grid.rowsPerCell)).rounded(.down))
        let limit = Float(projected.depth) * (1 - Self.occlusionShare)
        let depth = rasterizer.depth.pointer
        for row in (centreY - 1)...(centreY + 1) where row >= 0 && row < height {
            for column in (centreX - 1)...(centreX + 1) where column >= 0 && column < width
                && depth[row * width + column] >= limit {
                return true
            }
        }
        return false
    }
}

/// The sRGB transfer function (IEC 61966-2-1) as tables: averaging colours
/// is adding light, which only linear values do correctly — the mean of an
/// sRGB black and white is a grey that looks too dark.
enum LinearLight {
    /// Each sRGB byte's linear value, 0 to 1.
    static let fromByte: [Float] = (0...Int(UInt8.max)).map { byte in
        let encoded = Float(byte) / Float(UInt8.max)
        return encoded <= decodeThreshold ? encoded / linearSlope
                                          : pow((encoded + offset) / scale, exponent)
    }

    /// Linear values to sRGB bytes, in this many even steps.
    static let encodeSteps = 4096
    static let toByte: [UInt8] = (0...encodeSteps).map { step in
        let linear = Float(step) / Float(encodeSteps)
        let encoded = linear <= encodeThreshold ? linear * linearSlope
                                                : scale * pow(linear, 1 / exponent) - offset
        return UInt8(max(0, min(Float(UInt8.max), (encoded * Float(UInt8.max)).rounded())))
    }

    @inline(__always)
    static func byte(_ linear: Float) -> UInt8 {
        toByte[Int((min(1, max(0, linear)) * Float(encodeSteps)).rounded())]
    }

    static let decodeThreshold: Float = 0.04045
    static let encodeThreshold: Float = 0.0031308
    static let linearSlope: Float = 12.92
    static let offset: Float = 0.055
    static let scale: Float = 1.055
    static let exponent: Float = 2.4
}
