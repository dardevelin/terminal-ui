/// A terrain tile made ready to draw: the shade of every sample and the
/// contours at the tile's own interval, worked out once when the tile
/// lands, off the main actor, so a frame only samples and strokes.
struct ElevationContent: Sendable {
    let elevation: ElevationTile
    /// Each sample's shade under ``Hillshade/standard`` lighting, its slopes
    /// exaggerated for the tile's zoom.
    let shades: [Float]
    /// The shade flat ground takes under that lighting.
    let flatShade: Float
    let contours: ContourTracer.Contours

    init(_ elevation: ElevationTile, id: TileID) {
        self.elevation = elevation
        var lighting = Hillshade.standard
        lighting.exaggeration = ElevationContent.exaggeration(forZoom: id.zoom)
        let tileMetres = WebMercator.metresPerWorldUnit(atLatitude: id.bounds.center.latitude)
            / Double(TileID.tilesPerSide(atZoom: id.zoom))
        shades = lighting.shades(of: elevation, cellSize: tileMetres / Double(elevation.width))
        flatShade = Float(lighting.flat)
        let reduction = max(1, elevation.width / ElevationContent.contourSamples)
        contours = ContourTracer.trace(elevation.reduced(by: reduction),
                                       interval: ContourTracer.interval(forZoom: id.zoom))
    }

    /// The shade at a point of the unit square: the nearest sample's.
    func shade(atUnitX unitX: Double, y unitY: Double) -> Float {
        let x = min(max(Int(unitX * Double(elevation.width)), 0), elevation.width - 1)
        let y = min(max(Int(unitY * Double(elevation.height)), 0), elevation.height - 1)
        return shades[y * elevation.width + x]
    }

    /// The samples a side contours are traced at: two dots a sample for a
    /// tile drawn at its own zoom (256 dots across), fine enough to follow a
    /// valley and coarse enough that a line is not the data's noise.
    static let contourSamples = 128

    /// Slopes look flatter the further out a map is, where a hill is a few
    /// dots across: the exaggeration rises a quarter for each zoom out from
    /// 13, where the ground is shown as steep as it is.
    static func exaggeration(forZoom zoom: Int) -> Double {
        let trueScaleZoom = 13, stepPerZoom = 0.25
        return 1 + Double(max(0, trueScaleZoom - zoom)) * stepPerZoom
    }
}
