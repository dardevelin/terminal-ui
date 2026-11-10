/// Why a vector tile could not be decoded.
enum VectorTileError: Error, Sendable, Equatable {
    case protobuf(ProtobufError)
    case gzip(GZipError)
    /// A layer without the name the spec requires.
    case missingLayerName
    /// A layer whose extent is zero or does not fit 32 bits.
    case invalidExtent(UInt64)
    /// A layer of a version other than 1 or 2.
    case unsupportedVersion(UInt64)
    /// A `Value` message with no value, or more than one.
    case invalidValue
    /// A feature's tags: an odd count, or an index past the keys or values.
    case invalidTags
    /// A feature's geometry broke the command grammar of MVT 2.1 §4.3.
    case invalidGeometry(GeometryProblem)

    enum GeometryProblem: Error, Sendable, Equatable {
        /// A command id other than MoveTo (1), LineTo (2) and ClosePath (7).
        case unknownCommand(UInt32)
        /// A command count the grammar does not allow there.
        case invalidCount(command: UInt32, count: UInt32)
        /// Fewer parameter integers left than the command's count needs.
        case missingParameters
        /// LineTo or ClosePath before any MoveTo.
        case noCurrentPath
        /// ClosePath in a point or line feature, or a LineTo in a point one.
        case commandNotAllowed(command: UInt32)
        /// A polygon ring that does not end in ClosePath.
        case unclosedRing
        /// A cursor position past the signed 32-bit range §4.3.3 requires.
        case coordinateOutOfRange
    }
}

/// The field numbers of `vector_tile.proto`, MVT 2.1.
enum TileField {
    static let layers: UInt64 = 3
}

enum LayerField {
    static let name: UInt64 = 1
    static let features: UInt64 = 2
    static let keys: UInt64 = 3
    static let values: UInt64 = 4
    static let extent: UInt64 = 5
    static let version: UInt64 = 15
}

enum FeatureField {
    static let id: UInt64 = 1
    static let tags: UInt64 = 2
    static let type: UInt64 = 3
    static let geometry: UInt64 = 4
}

enum ValueField {
    static let string: UInt64 = 1
    static let float: UInt64 = 2
    static let double: UInt64 = 3
    static let int: UInt64 = 4
    static let uint: UInt64 = 5
    static let sint: UInt64 = 6
    static let bool: UInt64 = 7
}

/// MVT 2.1 §4.3.1: a command integer is the command id in the low three
/// bits and the count of parameter pairs above them.
enum GeometryCommand {
    static let moveTo: UInt32 = 1
    static let lineTo: UInt32 = 2
    static let closePath: UInt32 = 7
    static let idBits: UInt32 = 3
    static let idMask: UInt32 = 0b111
    static let parametersPerPoint = 2

    static func integer(_ id: UInt32, count: UInt32) -> UInt32 {
        (id & idMask) | count << idBits
    }
}

/// Decodes Mapbox Vector Tile 2.1 bytes, gzip-compressed or not.
enum VectorTileDecoder {
    /// The versions this decoder reads: 1, whose rings may wind either way,
    /// and 2.
    private static let supportedVersions: ClosedRange<UInt64> = 1...2

    static func decode(_ bytes: [UInt8]) throws(VectorTileError) -> VectorTile {
        var raw = bytes
        if GZip.isCompressed(bytes) {
            do { raw = try GZip.decompress(bytes) } catch { throw .gzip(error) }
        }
        do {
            var reader = ProtobufReader(raw)
            var layers: [VectorLayer] = []
            while let field = try reader.nextField() {
                if field.number == TileField.layers, field.wireType == .lengthDelimited {
                    var layer = try reader.readMessage()
                    layers.append(try decodeLayer(&layer))
                } else {
                    try reader.skip(field.wireType)
                }
            }
            return VectorTile(layers: layers)
        } catch let error as ProtobufError {
            throw .protobuf(error)
        } catch let error as VectorTileError {
            throw error
        } catch {
            preconditionFailure("decoding throws only ProtobufError and VectorTileError")
        }
    }

    /// A feature before its tags are resolved: a layer's keys and values may
    /// come after its features.
    private struct PendingFeature {
        var id: UInt64?
        var tags: [UInt32] = []
        var type: UInt64 = 0
        var geometry: [UInt32] = []
    }

    private static func decodeLayer(_ reader: inout ProtobufReader) throws -> VectorLayer {
        var name: String?
        var version: UInt64 = 1
        var extent = UInt64(VectorLayer.defaultExtent)
        var keys: [String] = []
        var values: [VectorValue] = []
        var pending: [PendingFeature] = []
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (LayerField.name, .lengthDelimited):
                name = try reader.readString()
            case (LayerField.version, .varint):
                version = try reader.readVarint()
            case (LayerField.extent, .varint):
                extent = try reader.readVarint()
            case (LayerField.keys, .lengthDelimited):
                keys.append(try reader.readString())
            case (LayerField.values, .lengthDelimited):
                var value = try reader.readMessage()
                values.append(try decodeValue(&value))
            case (LayerField.features, .lengthDelimited):
                var feature = try reader.readMessage()
                pending.append(try decodePendingFeature(&feature))
            default:
                try reader.skip(field.wireType)
            }
        }
        guard let name else { throw VectorTileError.missingLayerName }
        guard supportedVersions.contains(version) else { throw VectorTileError.unsupportedVersion(version) }
        guard extent > 0, extent <= UInt64(UInt32.max) else { throw VectorTileError.invalidExtent(extent) }
        var features: [VectorFeature] = []
        features.reserveCapacity(pending.count)
        for feature in pending {
            features.append(try resolve(feature, keys: keys, values: values))
        }
        return VectorLayer(name: name, version: Int(version), extent: Int(extent), features: features)
    }

    private static func decodeValue(_ reader: inout ProtobufReader) throws -> VectorValue {
        var value: VectorValue?
        while let field = try reader.nextField() {
            let decoded: VectorValue?
            switch (field.number, field.wireType) {
            case (ValueField.string, .lengthDelimited): decoded = .string(try reader.readString())
            case (ValueField.float, .fixed32): decoded = .float(Float(bitPattern: try reader.readFixed32()))
            case (ValueField.double, .fixed64): decoded = .double(Double(bitPattern: try reader.readFixed64()))
            case (ValueField.int, .varint): decoded = .int(Int64(bitPattern: try reader.readVarint()))
            case (ValueField.uint, .varint): decoded = .uint(try reader.readVarint())
            case (ValueField.sint, .varint): decoded = .int(ZigZag.decode(try reader.readVarint()))
            case (ValueField.bool, .varint): decoded = .bool(try reader.readVarint() != 0)
            default:
                try reader.skip(field.wireType)
                decoded = nil
            }
            if let decoded {
                guard value == nil else { throw VectorTileError.invalidValue }
                value = decoded
            }
        }
        guard let value else { throw VectorTileError.invalidValue }
        return value
    }

    private static func decodePendingFeature(_ reader: inout ProtobufReader) throws -> PendingFeature {
        var feature = PendingFeature()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (FeatureField.id, .varint):
                feature.id = try reader.readVarint()
            case (FeatureField.type, .varint):
                feature.type = try reader.readVarint()
            case (FeatureField.tags, _):
                try reader.readPackedVarints(wireType: field.wireType, into: &feature.tags)
            case (FeatureField.geometry, _):
                try reader.readPackedVarints(wireType: field.wireType, into: &feature.geometry)
            default:
                try reader.skip(field.wireType)
            }
        }
        return feature
    }

    private static func resolve(_ feature: PendingFeature, keys: [String],
                                values: [VectorValue]) throws(VectorTileError) -> VectorFeature {
        guard feature.tags.count.isMultiple(of: 2) else { throw .invalidTags }
        var properties: [String: VectorValue] = [:]
        properties.reserveCapacity(feature.tags.count / 2)
        var index = 0
        while index < feature.tags.count {
            let keyIndex = Int(feature.tags[index])
            let valueIndex = Int(feature.tags[index + 1])
            guard keyIndex < keys.count, valueIndex < values.count else { throw .invalidTags }
            properties[keys[keyIndex]] = values[valueIndex]
            index += 2
        }
        let kind = VectorFeature.Kind(rawValue: Int(clamping: feature.type)) ?? .unknown
        let rings: [[TilePoint]]
        do {
            rings = try decodeGeometry(feature.geometry, kind: kind)
        } catch {
            throw .invalidGeometry(error)
        }
        return VectorFeature(id: feature.id, kind: kind, rings: rings, properties: properties)
    }

    /// MVT 2.1 §4.3: commands move a cursor that starts at (0, 0) for each
    /// feature; parameters are zig-zag deltas from it. A point feature is
    /// MoveTo(n ≥ 1); a line is MoveTo(1) LineTo(n ≥ 1), repeated; a
    /// polygon ring is MoveTo(1) LineTo(n ≥ 1) ClosePath(1), repeated.
    static func decodeGeometry(_ integers: [UInt32],
                               kind: VectorFeature.Kind) throws(VectorTileError.GeometryProblem) -> [[TilePoint]] {
        var rings: [[TilePoint]] = []
        var points: [TilePoint] = []
        var current: [TilePoint]?
        var currentClosed = false
        var cursorX: Int64 = 0
        var cursorY: Int64 = 0
        var index = 0

        func finishPath() throws(VectorTileError.GeometryProblem) {
            guard let path = current else { return }
            if kind == .polygon, !currentClosed { throw .unclosedRing }
            rings.append(path)
            current = nil
            currentClosed = false
        }

        while index < integers.count {
            let command = integers[index] & GeometryCommand.idMask
            let count = integers[index] >> GeometryCommand.idBits
            index += 1
            switch command {
            case GeometryCommand.moveTo, GeometryCommand.lineTo:
                guard count >= 1 else { throw .invalidCount(command: command, count: count) }
                let parameterCount = Int(count) * GeometryCommand.parametersPerPoint
                guard integers.count - index >= parameterCount else { throw .missingParameters }
                if command == GeometryCommand.moveTo {
                    if kind != .point {
                        guard count == 1 else { throw .invalidCount(command: command, count: count) }
                        try finishPath()
                        current = []
                    }
                } else {
                    guard kind != .point else { throw .commandNotAllowed(command: command) }
                    guard current != nil, !currentClosed else { throw .noCurrentPath }
                }
                for _ in 0..<count {
                    cursorX += Int64(ZigZag.decode(integers[index]))
                    cursorY += Int64(ZigZag.decode(integers[index + 1]))
                    index += GeometryCommand.parametersPerPoint
                    guard let x = Int32(exactly: cursorX), let y = Int32(exactly: cursorY) else {
                        throw .coordinateOutOfRange
                    }
                    if kind == .point {
                        points.append(TilePoint(x: x, y: y))
                    } else {
                        current?.append(TilePoint(x: x, y: y))
                    }
                }
            case GeometryCommand.closePath:
                guard count == 1 else { throw .invalidCount(command: command, count: count) }
                guard kind == .polygon || kind == .unknown else { throw .commandNotAllowed(command: command) }
                guard current != nil, !currentClosed else { throw .noCurrentPath }
                currentClosed = true
            default:
                throw .unknownCommand(command)
            }
        }
        try finishPath()
        if kind == .point, !points.isEmpty { rings.append(points) }
        return rings
    }
}
