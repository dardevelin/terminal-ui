import Foundation

/// What a region pack holds, kept beside its tiles as `manifest.json`.
public struct RegionPackManifest: Sendable, Codable, Equatable {
    /// The layout this code writes; a pack of another is not read.
    public static let currentFormat = 1

    /// The layout the pack was written in, ``currentFormat`` for one this
    /// code can read.
    public var format: Int
    /// The name the pack was downloaded as.
    public var name: String
    /// The box the pack's tiles cover.
    public var bounds: GeoRect
    /// The shallowest zoom the pack holds.
    public var minimumZoom: Int
    /// The deepest zoom the pack holds.
    public var maximumZoom: Int
    /// The tile source's name.
    public var source: String
    /// The credit the source's data requires.
    public var attribution: String
    /// When the pack was first downloaded; a resume or refresh keeps it.
    public var created: Date
    /// Tiles on disk.
    public var tileCount: Int
    /// Their bytes, as fetched.
    public var byteCount: Int
    /// Whether every tile of the region has been fetched: false while a
    /// download runs, and after one that stopped, until it is resumed.
    public var isComplete: Bool
    /// Raster layers downloaded over the same region — imagery, terrain —
    /// each under `layers/<kind>/` (RegionPackLayers.swift). Absent from a
    /// pack written before layers were, which reads as none: the format
    /// is unchanged, and a reader that knows no layers ignores the key.
    public var layers: [RegionPackLayer]?
    /// How the source's feature ids name the map data's elements; absent
    /// from a pack written before it was kept, which reads as opaque.
    public var featureIdentifiers: FeatureIdentifiers?

    /// The zooms the pack holds, from ``minimumZoom`` to ``maximumZoom``.
    public var zoomRange: ClosedRange<Int> { minimumZoom...max(minimumZoom, maximumZoom) }

    /// A manifest in the current format, with no layers and opaque feature
    /// ids.
    public init(name: String, bounds: GeoRect, zoomRange: ClosedRange<Int>, source: String, attribution: String,
                created: Date, tileCount: Int = 0, byteCount: Int = 0, isComplete: Bool = false) {
        self.format = RegionPackManifest.currentFormat
        self.name = name
        self.bounds = bounds
        self.minimumZoom = zoomRange.lowerBound
        self.maximumZoom = zoomRange.upperBound
        self.source = source
        self.attribution = attribution
        self.created = created
        self.tileCount = tileCount
        self.byteCount = byteCount
        self.isComplete = isComplete
    }
}

/// A downloaded region on disk: a directory holding `manifest.json` and
/// `tiles/<z>/<x>/<y>.mvt`, each tile the source's bytes as fetched.
public struct RegionPack: Sendable, Equatable {
    /// The pack's directory.
    public let directory: URL
    /// What the pack holds.
    public let manifest: RegionPackManifest

    static let manifestFileName = "manifest.json"
    static let tilesDirectoryName = "tiles"
    static let tileExtension = "mvt"

    /// The pack in `directory` described by `manifest`, taken as given:
    /// nothing is read or written.
    public init(directory: URL, manifest: RegionPackManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    /// Reads the pack in `directory`.
    public init(directory: URL) throws {
        let url = directory.appendingPathComponent(RegionPack.manifestFileName)
        let manifest: RegionPackManifest
        do {
            manifest = try RegionPack.decoder.decode(RegionPackManifest.self, from: Data(contentsOf: url))
        } catch {
            throw RegionPackError.invalidManifest(url)
        }
        guard manifest.format == RegionPackManifest.currentFormat else {
            throw RegionPackError.invalidManifest(url)
        }
        self.init(directory: directory, manifest: manifest)
    }

    var tilesDirectory: URL { directory.appendingPathComponent(RegionPack.tilesDirectoryName) }

    func tileURL(for tile: TileID) -> URL {
        tilesDirectory
            .appendingPathComponent(String(tile.zoom))
            .appendingPathComponent(String(tile.x))
            .appendingPathComponent("\(tile.y).\(RegionPack.tileExtension)")
    }

    /// Whether the pack covers a tile: in its zooms and its box.
    public func covers(_ tile: TileID) -> Bool {
        manifest.zoomRange.contains(tile.zoom) && tile.bounds.intersects(manifest.bounds)
    }

    /// The tiles the pack has on disk, deepest zoom first.
    func storedTiles() -> [TileID] {
        let files = FileManager.default
        var tiles: [TileID] = []
        let zooms = ((try? files.contentsOfDirectory(atPath: tilesDirectory.path)) ?? []).compactMap { Int($0) }
        for zoom in zooms.sorted(by: >) {
            let zoomDirectory = tilesDirectory.appendingPathComponent(String(zoom))
            let columns = ((try? files.contentsOfDirectory(atPath: zoomDirectory.path)) ?? []).compactMap { Int($0) }
            for column in columns.sorted() {
                let columnDirectory = zoomDirectory.appendingPathComponent(String(column))
                let names = (try? files.contentsOfDirectory(atPath: columnDirectory.path)) ?? []
                let rows = names.compactMap { name -> Int? in
                    let suffix = ".\(RegionPack.tileExtension)"
                    return name.hasSuffix(suffix) ? Int(name.dropLast(suffix.count)) : nil
                }
                for row in rows.sorted() {
                    tiles.append(TileID(zoom: zoom, x: column, y: row))
                }
            }
        }
        return tiles
    }

    func writeManifest(_ manifest: RegionPackManifest) throws {
        let data = try RegionPack.encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent(RegionPack.manifestFileName), options: .atomic)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Why a pack could not be read, made or downloaded.
public enum RegionPackError: Error, Sendable, Equatable {
    /// The region at those zooms is more tiles than the downloader allows.
    case tooManyTiles(count: Int, limit: Int)
    /// A pack's `manifest.json` is missing, unreadable, or of another format.
    case invalidManifest(URL)
    /// Another pack already uses the directory this name maps to.
    case nameConflict(String)
    /// The name has no letters or digits to name a directory with.
    case invalidName(String)
}

/// The directory packs live in, one subdirectory each.
public struct RegionPackStore: Sendable {
    /// The directory holding the packs.
    public let directory: URL

    /// A store of the packs in `directory`, which need not exist yet.
    public init(directory: URL = RegionPackStore.defaultDirectory()) {
        self.directory = directory
    }

    /// Where packs go by default: `~/Library/Application Support/
    /// TerminalUIMaps/packs` on macOS; `$XDG_DATA_HOME/terminalui-maps/packs`
    /// elsewhere, `XDG_DATA_HOME` defaulting to `~/.local/share` as the XDG
    /// Base Directory Specification 0.8 sets.
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        #if canImport(Darwin)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("TerminalUIMaps").appendingPathComponent("packs")
        #else
        return xdgDirectory(environment: environment)
        #endif
    }

    /// The XDG location, on any platform.
    static func xdgDirectory(environment: [String: String]) -> URL {
        let dataHome: URL
        if let configured = environment["XDG_DATA_HOME"], configured.hasPrefix("/") {
            dataHome = URL(fileURLWithPath: configured)
        } else {
            let home = environment["HOME"] ?? NSHomeDirectory()
            dataHome = URL(fileURLWithPath: home).appendingPathComponent(".local/share")
        }
        return dataHome.appendingPathComponent("terminalui-maps").appendingPathComponent("packs")
    }

    /// Every readable pack, by name.
    public func list() throws -> [RegionPack] {
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else { return [] }
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return entries.compactMap { try? RegionPack(directory: $0) }
            .sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    /// The pack of a name, or nil.
    public func pack(named name: String) throws -> RegionPack? {
        let candidate = try directory(forName: name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        let pack = try RegionPack(directory: candidate)
        return pack.manifest.name == name ? pack : nil
    }

    /// Removes a pack and every tile in it.
    public func delete(_ pack: RegionPack) throws {
        try FileManager.default.removeItem(at: pack.directory)
    }

    /// The directory a pack of `name` lives in: the name lowercased, every
    /// run of characters other than ASCII letters and digits one hyphen.
    public func directory(forName name: String) throws -> URL {
        var slug = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.last == "-" { slug.removeLast() }
        guard !slug.isEmpty else { throw RegionPackError.invalidName(name) }
        return directory.appendingPathComponent(slug)
    }
}
