/// Encodes a `VectorTile` as Mapbox Vector Tile 2.1 bytes — what the
/// sample source serves, so the code that reads a real server's tiles reads
/// its tiles too.
///
/// Rings are written as given: a polygon feature built with
/// `VectorFeature(polygons:)` is already wound as the spec requires. Each
/// layer's keys and values are written once, in first-use order.
public enum VectorTileEncoder {
    public static func encode(_ tile: VectorTile) -> [UInt8] {
        var writer = ProtobufWriter()
        for layer in tile.layers {
            writer.writeBytesField(TileField.layers, encode(layer))
        }
        return writer.bytes
    }

    private static func encode(_ layer: VectorLayer) -> [UInt8] {
        var keys: [String] = []
        var keyIndices: [String: UInt32] = [:]
        var values: [VectorValue] = []
        var valueIndices: [VectorValue: UInt32] = [:]
        var features: [[UInt8]] = []
        for feature in layer.features {
            var tags: [UInt32] = []
            for key in feature.properties.keys.sorted() {
                guard let value = feature.properties[key] else { continue }
                let keyIndex = keyIndices[key] ?? {
                    keys.append(key)
                    keyIndices[key] = UInt32(keys.count - 1)
                    return UInt32(keys.count - 1)
                }()
                let valueIndex = valueIndices[value] ?? {
                    values.append(value)
                    valueIndices[value] = UInt32(values.count - 1)
                    return UInt32(values.count - 1)
                }()
                tags += [keyIndex, valueIndex]
            }
            features.append(encode(feature, tags: tags))
        }

        var writer = ProtobufWriter()
        writer.writeVarintField(LayerField.version, UInt64(layer.version))
        writer.writeStringField(LayerField.name, layer.name)
        for feature in features { writer.writeBytesField(LayerField.features, feature) }
        for key in keys { writer.writeStringField(LayerField.keys, key) }
        for value in values { writer.writeBytesField(LayerField.values, encode(value)) }
        writer.writeVarintField(LayerField.extent, UInt64(layer.extent))
        return writer.bytes
    }

    private static func encode(_ value: VectorValue) -> [UInt8] {
        var writer = ProtobufWriter()
        switch value {
        case .string(let text): writer.writeStringField(ValueField.string, text)
        case .float(let number): writer.writeFixed32Field(ValueField.float, number.bitPattern)
        case .double(let number): writer.writeFixed64Field(ValueField.double, number.bitPattern)
        case .int(let number) where number < 0: writer.writeVarintField(ValueField.sint, ZigZag.encode(number))
        case .int(let number): writer.writeVarintField(ValueField.int, UInt64(number))
        case .uint(let number): writer.writeVarintField(ValueField.uint, number)
        case .bool(let flag): writer.writeVarintField(ValueField.bool, flag ? 1 : 0)
        }
        return writer.bytes
    }

    private static func encode(_ feature: VectorFeature, tags: [UInt32]) -> [UInt8] {
        var writer = ProtobufWriter()
        if let id = feature.id { writer.writeVarintField(FeatureField.id, id) }
        writer.writePackedField(FeatureField.tags, tags)
        writer.writeVarintField(FeatureField.type, UInt64(feature.kind.rawValue))
        writer.writePackedField(FeatureField.geometry, geometry(of: feature))
        return writer.bytes
    }

    /// The command stream of MVT 2.1 §4.3 for a feature's rings.
    static func geometry(of feature: VectorFeature) -> [UInt32] {
        var integers: [UInt32] = []
        var cursor = TilePoint(x: 0, y: 0)
        func append(_ point: TilePoint) {
            integers.append(ZigZag.encode(point.x &- cursor.x))
            integers.append(ZigZag.encode(point.y &- cursor.y))
            cursor = point
        }
        switch feature.kind {
        case .point:
            let points = feature.rings.flatMap { $0 }
            guard !points.isEmpty else { return [] }
            integers.append(GeometryCommand.integer(GeometryCommand.moveTo, count: UInt32(points.count)))
            points.forEach(append)
        case .lineString, .polygon, .unknown:
            for ring in feature.rings {
                guard let first = ring.first, ring.count >= 2 else { continue }
                integers.append(GeometryCommand.integer(GeometryCommand.moveTo, count: 1))
                append(first)
                integers.append(GeometryCommand.integer(GeometryCommand.lineTo, count: UInt32(ring.count - 1)))
                ring.dropFirst().forEach(append)
                if feature.kind == .polygon {
                    integers.append(GeometryCommand.integer(GeometryCommand.closePath, count: 1))
                }
            }
        }
        return integers
    }
}
