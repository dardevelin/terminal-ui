import TerminalUI

/// How much of its vector basemap a map draws.
public enum BasemapDetail: Sendable, Equatable {
    /// Everything: areas, lines and names — the Explore map.
    case full
    /// Roads, rivers and names, no areas: what a hybrid map draws over a
    /// picture, which would vanish beneath the areas' fills.
    case linesAndLabels
    /// Nothing of the basemap; only the layers and the map's content.
    case hidden
}

/// How a terrain layer draws its heights.
public struct TerrainStyle: Sendable, Equatable {
    /// Whether slopes are shaded as the sun would light them.
    public var showsHillshade: Bool
    /// Whether lines of equal height are drawn, at the interval the tile's
    /// zoom gives: closer at a closer zoom.
    public var showsContours: Bool
    /// The most a shade moves the ground toward light or dark: 0 shades
    /// nothing, 1 lets a cliff take the theme's ink or ground outright.
    public var shadeStrength: Double

    /// Both, at a strength that leaves the map's own colours readable.
    public static let standard = TerrainStyle(showsHillshade: true, showsContours: true, shadeStrength: 0.55)

    /// A style that shades slopes, draws contours, or both, at `shadeStrength`
    /// from 0 to 1.
    public init(showsHillshade: Bool, showsContours: Bool, shadeStrength: Double) {
        self.showsHillshade = showsHillshade
        self.showsContours = showsContours
        self.shadeStrength = shadeStrength
    }
}

/// What a ``MapView`` draws besides its basemap's own tiles: a picture
/// beneath (imagery), terrain over the areas and beneath the lines, and how
/// much of the basemap shows — the layers a map type is made of
/// (``MapTypeModel/layers``).
///
/// ```swift
/// MapView(camera: $camera, store: basemap)
///     .mapLayers(MapLayers(imagery: imageryStore, basemap: .linesAndLabels))   // hybrid
/// ```
public struct MapLayers: Sendable, Equatable {
    /// Pictures drawn as the ground, beneath everything else.
    public var imagery: MapTileStore?
    /// Heights, drawn as hillshade over the areas and contours beneath the
    /// lines.
    public var terrain: MapTileStore?
    /// How much of the vector basemap is drawn.
    public var basemap: BasemapDetail
    /// How the terrain layer draws its heights, where there is one.
    public var terrainStyle: TerrainStyle

    /// The layers given; with none, the full basemap alone.
    public init(imagery: MapTileStore? = nil, terrain: MapTileStore? = nil, basemap: BasemapDetail = .full,
                terrainStyle: TerrainStyle = .standard) {
        self.imagery = imagery
        self.terrain = terrain
        self.basemap = basemap
        self.terrainStyle = terrainStyle
    }

    /// The basemap alone: the Explore map.
    public static let explore = MapLayers()

    /// Whether two sets of layers are the same: the same stores, by
    /// identity, drawn the same way.
    public static func == (left: MapLayers, right: MapLayers) -> Bool {
        left.imagery === right.imagery && left.terrain === right.terrain && left.basemap == right.basemap
            && left.terrainStyle == right.terrainStyle
    }
}

/// The tiles of one layer a frame draws: the zooms its source has and the
/// tile at hand for an id — what a ``MapTileStore`` gives a frame.
struct MapLayerTiles {
    var zoomRange: ClosedRange<Int>
    var lookup: (TileID) -> RenderTile?

    init(zoomRange: ClosedRange<Int>, lookup: @escaping (TileID) -> RenderTile?) {
        self.zoomRange = zoomRange
        self.lookup = lookup
    }
}

/// A frame's layers, as ``MapRenderer/draw(in:camera:size:zoomRange:content:layers:tiles:)``
/// takes them: ``MapLayers`` with each store's tiles at hand.
struct MapFrameLayers {
    var basemap: BasemapDetail
    var imagery: MapLayerTiles?
    var terrain: MapLayerTiles?
    var terrainStyle: TerrainStyle

    init(basemap: BasemapDetail = .full, imagery: MapLayerTiles? = nil, terrain: MapLayerTiles? = nil,
                terrainStyle: TerrainStyle = .standard) {
        self.basemap = basemap
        self.imagery = imagery
        self.terrain = terrain
        self.terrainStyle = terrainStyle
    }

    /// Names drawn over a picture sit on the theme's ground, a band the
    /// photo's colours cannot drown; over the map's own fills they keep
    /// the fill beneath.
    func labelBackground(in theme: any Theme) -> Color? {
        imagery == nil ? nil : theme.background
    }
}

extension MapRenderer {
    /// The ground of the layers: imagery's pictures, else, beneath a
    /// terrain, the theme's ground — the fill hillshade mixes into where no
    /// area is.
    func drawGround(_ layers: MapFrameLayers, camera: MapCamera, viewport: DotSize, projection: Projection,
                    dots: GraphicsContext, theme: any Theme) {
        if let imagery = layers.imagery {
            let items = plan(camera: camera, viewport: viewport, zoomRange: imagery.zoomRange,
                             projection: projection, dots: dots, countsTiles: false, lookup: imagery.lookup)
            drawPictures(items, projection: projection)
        } else if layers.terrain != nil {
            dots.fill(CanvasRect(x: 0, y: 0, width: viewport.width, height: viewport.height),
                      with: .color(ReliefColours(theme).ground))
        }
    }

    /// Hillshade and contours of the terrain layer, over what is drawn so
    /// far and beneath the lines.
    func drawRelief(_ layers: MapFrameLayers, camera: MapCamera, viewport: DotSize, projection: Projection,
                    dots: GraphicsContext, theme: any Theme) {
        guard let terrain = layers.terrain else { return }
        let style = layers.terrainStyle
        let items = plan(camera: camera, viewport: viewport, zoomRange: terrain.zoomRange, projection: projection,
                         dots: dots, countsTiles: false, lookup: terrain.lookup)
        let colours = ReliefColours(theme)
        if style.showsHillshade, style.shadeStrength > 0 {
            for item in items {
                guard case .elevation(let elevation) = item.tile.content else { continue }
                shade(item, elevation: elevation, projection: projection, strength: style.shadeStrength,
                      colours: colours)
            }
        }
        if style.showsContours {
            for item in items {
                guard case .elevation(let elevation) = item.tile.content else { continue }
                let contours = elevation.contours
                stroke(contours.minor, of: item, projection: projection, with: colours.contour)
                stroke(contours.index, of: item, projection: projection, with: colours.indexContour)
            }
        }
    }

    /// The steps a shade is drawn in each way from flat: enough that a
    /// slope reads as a gradient, few enough that a row is long runs.
    private static let shadeSteps = 10

    /// Hillshade on half cells, as raster tiles are drawn: each takes the
    /// shade under its centre, moved toward the theme's lighter end where
    /// a slope faces the sun and its darker end where it faces away, by
    /// how far it is from flat. Under a turned camera every half cell of
    /// the screen is turned back to where it lies north up, as turned
    /// pictures are, and those outside the tile's square left alone.
    private func shade(_ item: Item, elevation: ElevationContent, projection: Projection, strength: Double,
                       colours: ReliefColours) {
        let halfCell = Double(BrailleCell.dotColumns)
        let viewport = projection.viewport
        let columns = Int(viewport.width / halfCell), rows = Int(viewport.height / halfCell)
        let centreOffset = halfCell / 2
        func range(origin: Double, limit: Int) -> Range<Int> {
            let first = max(0, Int(((origin - centreOffset) / halfCell).rounded(.up)))
            let last = min(limit, Int(((origin + item.side - centreOffset) / halfCell).rounded(.up)))
            return first..<max(first, last)
        }
        let flat = elevation.flatShade
        let litRange = max(1 - flat, .leastNonzeroMagnitude), shadowRange = max(flat, .leastNonzeroMagnitude)
        let steps = Self.shadeSteps
        let turned = projection.isTurned
        let columnRange = turned ? 0..<columns : range(origin: item.originX, limit: columns)
        let rowRange = turned ? 0..<rows : range(origin: item.originY, limit: rows)
        /// The shade's step at a half cell of the screen, 0 where it is
        /// flat or off the tile.
        func level(column: Int, row: Int) -> Int {
            let point = projection.unturned(x: Double(column) * halfCell + centreOffset,
                                            y: Double(row) * halfCell + centreOffset)
            let unitX = (point.x - item.originX) / item.side, unitY = (point.y - item.originY) / item.side
            if turned {
                guard (0..<1).contains(unitX), (0..<1).contains(unitY), item.covers(x: point.x, y: point.y) else {
                    return 0
                }
            }
            let relative = elevation.shade(atUnitX: unitX, y: unitY) - flat
            let fraction = relative >= 0 ? relative / litRange : relative / shadowRange
            return Int((Double(fraction) * Double(steps)).rounded())
        }
        for row in rowRange {
            var runStart = columnRange.lowerBound
            var runLevel = 0
            func flush(until end: Int) {
                guard runLevel != 0, end > runStart else { return }
                var context = item.context
                context.opacity = strength * Double(abs(runLevel)) / Double(steps)
                context.fill(CanvasRect(x: Double(runStart) * halfCell, y: Double(row) * halfCell,
                                        width: Double(end - runStart) * halfCell, height: halfCell),
                             with: .color(runLevel > 0 ? colours.light : colours.dark))
            }
            for column in columnRange {
                let level = level(column: column, row: row)
                if level != runLevel {
                    flush(until: column)
                    runStart = column
                    runLevel = level
                }
            }
            flush(until: columnRange.upperBound)
        }
    }

    /// Contour segments of a tile, in its square, as one hairline stroke,
    /// turned with the camera's bearing as roads are.
    private func stroke(_ segments: [Float], of item: Item, projection: Projection, with colour: Color) {
        guard !segments.isEmpty else { return }
        var path = Path()
        let stride = ContourTracer.valuesPerSegment
        func point(_ index: Int) -> CanvasPoint {
            let turned = projection.turned(x: item.originX + Double(segments[index]) * item.side,
                                           y: item.originY + Double(segments[index + 1]) * item.side)
            return CanvasPoint(x: turned.x, y: turned.y)
        }
        for start in Swift.stride(from: 0, to: segments.count - stride + 1, by: stride) {
            path.move(to: point(start))
            path.addLine(to: point(start + 2))
        }
        item.context.stroke(path, with: .color(colour), lineWidth: 0)
    }
}

/// The colours relief is drawn in, every one of them the theme's own or a
/// mix of them. Slopes the sun lights move toward the lighter of the
/// theme's ground and ink, warmed with its warning hue, and slopes in
/// shadow toward the darker, cooled with its info hue — the warm light and
/// cool shadow of Swiss relief shading (Imhof, *Cartographic Relief
/// Presentation*, 1982), which also keeps a lit slope from reading as a
/// grey building. On a dark theme the ground is lifted a little toward
/// the ink, so a shadow has somewhere darker to go. Contours take the
/// warning hue, the brown of a topographic map, mixed toward the ground so
/// they sit beneath the roads drawn in that hue at full strength.
struct ReliefColours {
    let ground: Color
    let light: Color
    let dark: Color
    let contour: Color
    let indexContour: Color

    /// How far each colour is mixed toward the one it is made from.
    private enum Mix {
        static let contour = 0.45
        static let indexContour = 0.2
        static let warmth = 0.35
        static let coolness = 0.3
        static let darkGroundLift = 0.08
    }

    init(_ theme: any Theme) {
        let background = theme.background, ink = theme.foregroundEmphasis
        let groundIsDark = ReliefColours.lightness(background) < ReliefColours.lightness(ink)
        let lighter = groundIsDark ? ink : background, darker = groundIsDark ? background : ink
        ground = groundIsDark ? background.blended(with: ink, amount: Mix.darkGroundLift) : background
        light = lighter.blended(with: theme.warning, amount: Mix.warmth)
        dark = darker.blended(with: theme.info, amount: Mix.coolness)
        contour = theme.warning.blended(with: background, amount: Mix.contour)
        indexContour = theme.warning.blended(with: background, amount: Mix.indexContour)
    }

    /// Rec. 709 luma of the colour's nominal sRGB, or the middle for a
    /// colour no program can know (the terminal's own).
    private static func lightness(_ colour: Color) -> Double {
        guard let rgb = colour.nominalRGB else { return Luma.middle }
        return Luma.red * Double(rgb.red) + Luma.green * Double(rgb.green) + Luma.blue * Double(rgb.blue)
    }

    /// ITU-R BT.709's luma coefficients.
    private enum Luma {
        static let red = 0.2126
        static let green = 0.7152
        static let blue = 0.0722
        static let middle = 127.5
    }
}
