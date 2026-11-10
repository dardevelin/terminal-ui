import Foundation
import TerminalUIIO

/// Street view of the sample town: a photo every ``spacing`` metres along
/// each of its streets, facing along the street, painted from the town
/// itself — no network, the tests' street imagery and the sample's.
public struct SampleStreetImagery: StreetImagery {
    public let name = "Millbrook street view"
    /// How far apart the photos are along a street.
    static let spacing = 40.0
    /// The photos' size: wide, as a street-level camera's frame is.
    static let photoWidth = 160
    static let photoHeight = 90

    /// When the town was photographed: a fixed day, so a test reads it.
    static let captured = Date(timeIntervalSince1970: 1_780_000_000)

    public init() {}

    /// Every photo of the town, street by street.
    static let images: [StreetImage] = {
        var images: [StreetImage] = []
        for (streetIndex, street) in SampleTown.streets.enumerated() {
            let path = street.path
            var walked = 0.0
            var count = 0
            for (start, end) in zip(path, path.dropFirst()) {
                let deltaEast = end.0 - start.0, deltaNorth = end.1 - start.1
                let length = (deltaEast * deltaEast + deltaNorth * deltaNorth).squareRoot()
                guard length > 0 else { continue }
                let heading = CompassBearing.normalised(atan2(deltaEast, deltaNorth) * CompassBearing.south / .pi)
                var along = walked.truncatingRemainder(dividingBy: spacing) == 0 ? 0
                    : spacing - walked.truncatingRemainder(dividingBy: spacing)
                while along <= length {
                    let fraction = along / length
                    let coordinate = SampleTown.coordinate(east: start.0 + deltaEast * fraction,
                                                           north: start.1 + deltaNorth * fraction)
                    images.append(StreetImage(id: "\(streetIndex)-\(count)", coordinate: coordinate, heading: heading,
                                              captured: captured, licence: "CC0, fictional",
                                              attribution: SampleTown.attribution, sequence: street.name))
                    count += 1
                    along += spacing
                }
                walked += length
            }
        }
        return images
    }()

    public func images(near coordinate: GeoCoordinate, within metres: Double) async throws -> [StreetImage] {
        Self.images.filter { $0.coordinate.metres(to: coordinate) <= metres }
            .sorted { $0.coordinate.metres(to: coordinate) < $1.coordinate.metres(to: coordinate) }
    }

    public func neighbours(of image: StreetImage, along bearing: Double) async throws -> StreetImageNeighbours {
        let street = Self.images.filter { $0.sequence == image.sequence }
        guard let index = street.firstIndex(where: { $0.id == image.id }) else { return .none }
        return StreetImageNeighbours(previous: index > 0 ? street[index - 1] : nil,
                                     next: index + 1 < street.count ? street[index + 1] : nil)
    }

    public func photo(of image: StreetImage) async throws -> ImageBuffer {
        try SampleStreetPhoto.paint(image)
    }
}

/// Paints a street-level view: sky, the road running away to a vanishing
/// point, and a row of houses either side, their colours and heights the
/// same each time a place is painted. A photograph's colours, not the
/// theme's.
enum SampleStreetPhoto {
    private enum Palette {
        static let skyTop: [Double] = [92, 140, 206]
        static let skyHorizon: [Double] = [196, 218, 236]
        static let road: [Double] = [78, 80, 84]
        static let kerb: [Double] = [150, 150, 146]
        static let verge: [Double] = [86, 128, 70]
        static let walls: [[Double]] = [[196, 170, 140], [170, 96, 80], [222, 214, 196], [140, 150, 160],
                                        [206, 186, 120]]
        static let roof: [Double] = [96, 60, 52]
        static let window: [Double] = [52, 64, 82]
    }

    /// The frame's proportions: the horizon's height, the road's width at
    /// the bottom edge, and the houses' heights, as shares of the frame.
    private enum Frame {
        static let horizon = 0.55
        static let roadAtBottom = 0.7
        static let houseWidth = 0.12
        static let lowestHouse = 0.25
        static let tallestHouse = 0.45
        static let windowSpacing = 6
        static let windowSize = 3
        static let roofDepth = 3
        static let kerbWidth = 0.03
        /// The road's half-width the nearest houses stand back from.
        static let roadMargin = 0.12
        /// A far house's width as a share of a near one's.
        static let farHouseScale = 0.6
        /// How far below the horizon the nearest house's foot is, as a
        /// share of the ground in view.
        static let nearestHouseDrop = 0.35
        /// The share of plots left empty, so a street is not a wall.
        static let emptyPlots = 0.15
    }

    static func paint(_ image: StreetImage) throws -> ImageBuffer {
        let width = SampleStreetImagery.photoWidth, height = SampleStreetImagery.photoHeight
        let channels = 4
        var rgba = [UInt8](repeating: UInt8.max, count: width * height * channels)
        let place = SampleTown.metres(of: image.coordinate)
        let seed = (Int(place.east.rounded()), Int(place.north.rounded()))
        let horizon = Int(Double(height) * Frame.horizon)
        let centre = Double(width) / 2
        func put(_ x: Int, _ y: Int, _ colour: [Double]) {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return }
            let base = (y * width + x) * channels
            for channel in 0..<colour.count { rgba[base + channel] = UInt8(min(max(colour[channel], 0), Double(UInt8.max))) }
        }
        for y in 0..<height {
            if y < horizon {
                let mix = Double(y) / Double(max(horizon, 1))
                let sky = zip(Palette.skyTop, Palette.skyHorizon).map { $0 + ($1 - $0) * mix }
                for x in 0..<width { put(x, y, sky) }
                continue
            }
            let depth = Double(y - horizon) / Double(max(height - horizon, 1))
            let halfRoad = depth * Double(width) * Frame.roadAtBottom / 2
            let kerb = depth * Double(width) * Frame.kerbWidth
            for x in 0..<width {
                let offset = abs(Double(x) - centre)
                put(x, y, offset < halfRoad ? Palette.road : offset < halfRoad + kerb ? Palette.kerb : Palette.verge)
            }
        }
        // Houses either side, nearer ones taller, drawn far to near.
        let houses = Int(1 / Frame.houseWidth)
        for side in [-1, 1] {
            for slot in stride(from: houses / 2, through: 0, by: -1) {
                let variety = SampleGeometry.hash(seed.0 + slot * side, seed.1 + slot)
                guard variety > Frame.emptyPlots else { continue }
                let near = 1 - Double(slot) / Double(houses / 2 + 1)
                let houseHeight = Int(Double(height) * (Frame.lowestHouse
                    + (Frame.tallestHouse - Frame.lowestHouse) * near * variety))
                let houseWidth = Int(Double(width) * Frame.houseWidth * (Frame.farHouseScale + near))
                let margin = Int(Double(width) * Frame.roadMargin)
                let edge = side < 0 ? Int(centre) - margin - slot * houseWidth / 2 - houseWidth
                    : Int(centre) + margin + slot * houseWidth / 2
                let wall = Palette.walls[Int(variety * Double(Palette.walls.count)) % Palette.walls.count]
                let bottom = horizon + Int(near * Double(height - horizon) * Frame.nearestHouseDrop)
                for y in max(0, bottom - houseHeight)..<min(height, bottom) {
                    for x in edge..<(edge + houseWidth) {
                        let fromTop = y - (bottom - houseHeight)
                        let isRoof = fromTop < Frame.roofDepth
                        let isWindow = !isRoof && (x - edge) % Frame.windowSpacing < Frame.windowSize
                            && fromTop % Frame.windowSpacing < Frame.windowSize && fromTop > Frame.windowSpacing
                        put(x, y, isRoof ? Palette.roof : isWindow ? Palette.window : wall)
                    }
                }
            }
        }
        return try ImageBuffer(rgba: rgba, width: width, height: height)
    }
}
