/// Protocol Buffers' wire types (protobuf encoding guide, "Message
/// Structure"): the low three bits of every field's key.
enum WireType: UInt64 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

/// The shape of a base-128 varint: seven payload bits a byte, the high bit
/// set on every byte but the last, at most ten bytes for 64 bits.
private enum Varint {
    static let payloadMask: UInt8 = 0x7F
    static let continuationBit: UInt8 = 0x80
    static let payloadBits = 7
    static let maximumBytes = 10
}

/// A field key: field number shifted over the three wire-type bits.
private enum FieldKey {
    static let wireTypeBits = 3
    static let wireTypeMask: UInt64 = 0b111
}

/// Why a protobuf message could not be read.
public enum ProtobufError: Error, Sendable, Equatable {
    /// The message ended inside a field.
    case truncated
    /// A varint ran past ten bytes.
    case overlongVarint
    /// A field key named field 0, or a wire type that does not exist.
    case invalidKey(UInt64)
    /// A group, the deprecated wire types 3 and 4, which no vector tile uses.
    case unsupportedGroup
    /// A length-delimited field longer than what is left of the message.
    case lengthOutOfRange(UInt64)
}

/// Reads one protobuf message from a byte array without copying it: a
/// length-delimited field is a reader over the same array. Every read is
/// bounds-checked and throws rather than traps, so malformed bytes are an
/// error and never a crash.
struct ProtobufReader {
    private let bytes: [UInt8]
    private(set) var position: Int
    private let end: Int

    init(_ bytes: [UInt8]) {
        self.init(bytes, range: 0..<bytes.count)
    }

    private init(_ bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        self.position = range.lowerBound
        self.end = range.upperBound
    }

    var isAtEnd: Bool { position >= end }

    /// The next field's number and wire type, or nil at the end.
    mutating func nextField() throws(ProtobufError) -> (number: UInt64, wireType: WireType)? {
        guard !isAtEnd else { return nil }
        let key = try readVarint()
        let number = key >> FieldKey.wireTypeBits
        guard number != 0, let wireType = WireType(rawValue: key & FieldKey.wireTypeMask) else {
            throw .invalidKey(key)
        }
        return (number, wireType)
    }

    mutating func readVarint() throws(ProtobufError) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<Varint.maximumBytes {
            guard position < end else { throw .truncated }
            let byte = bytes[position]
            position += 1
            value |= UInt64(byte & Varint.payloadMask) << UInt64(index * Varint.payloadBits)
            if byte & Varint.continuationBit == 0 { return value }
        }
        throw .overlongVarint
    }

    mutating func readFixed32() throws(ProtobufError) -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: UInt32.bitWidth, by: UInt8.bitWidth) {
            guard position < end else { throw .truncated }
            value |= UInt32(bytes[position]) << UInt32(shift)
            position += 1
        }
        return value
    }

    mutating func readFixed64() throws(ProtobufError) -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: UInt64.bitWidth, by: UInt8.bitWidth) {
            guard position < end else { throw .truncated }
            value |= UInt64(bytes[position]) << UInt64(shift)
            position += 1
        }
        return value
    }

    /// A reader over the next length-delimited field's payload.
    mutating func readMessage() throws(ProtobufError) -> ProtobufReader {
        let length = try readVarint()
        guard length <= UInt64(end - position) else { throw .lengthOutOfRange(length) }
        let start = position
        position += Int(length)
        return ProtobufReader(bytes, range: start..<position)
    }

    mutating func readBytes() throws(ProtobufError) -> ArraySlice<UInt8> {
        let field = try readMessage()
        return bytes[field.position..<field.end]
    }

    mutating func readString() throws(ProtobufError) -> String {
        String(decoding: try readBytes(), as: UTF8.self)
    }

    /// A repeated varint field: packed (one length-delimited run), or, as
    /// parsers must also accept, one value per field.
    mutating func readPackedVarints(wireType: WireType, into values: inout [UInt32]) throws(ProtobufError) {
        switch wireType {
        case .lengthDelimited:
            var packed = try readMessage()
            while !packed.isAtEnd {
                values.append(UInt32(truncatingIfNeeded: try packed.readVarint()))
            }
        case .varint:
            values.append(UInt32(truncatingIfNeeded: try readVarint()))
        default:
            try skip(wireType)
        }
    }

    mutating func skip(_ wireType: WireType) throws(ProtobufError) {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            try advance(by: UInt64.bitWidth / UInt8.bitWidth)
        case .fixed32:
            try advance(by: UInt32.bitWidth / UInt8.bitWidth)
        case .lengthDelimited:
            _ = try readMessage()
        case .startGroup, .endGroup:
            throw .unsupportedGroup
        }
    }

    private mutating func advance(by count: Int) throws(ProtobufError) {
        guard end - position >= count else { throw .truncated }
        position += count
    }
}

/// Writes a protobuf message.
struct ProtobufWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeVarint(_ value: UInt64) {
        var remaining = value
        while remaining >= UInt64(Varint.continuationBit) {
            bytes.append(UInt8(truncatingIfNeeded: remaining) | Varint.continuationBit)
            remaining >>= UInt64(Varint.payloadBits)
        }
        bytes.append(UInt8(remaining))
    }

    mutating func writeKey(_ number: UInt64, _ wireType: WireType) {
        writeVarint(number << UInt64(FieldKey.wireTypeBits) | wireType.rawValue)
    }

    mutating func writeVarintField(_ number: UInt64, _ value: UInt64) {
        writeKey(number, .varint)
        writeVarint(value)
    }

    mutating func writeFixed32Field(_ number: UInt64, _ value: UInt32) {
        writeKey(number, .fixed32)
        for shift in stride(from: 0, to: UInt32.bitWidth, by: UInt8.bitWidth) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func writeFixed64Field(_ number: UInt64, _ value: UInt64) {
        writeKey(number, .fixed64)
        for shift in stride(from: 0, to: UInt64.bitWidth, by: UInt8.bitWidth) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func writeBytesField(_ number: UInt64, _ payload: some Collection<UInt8>) {
        writeKey(number, .lengthDelimited)
        writeVarint(UInt64(payload.count))
        bytes.append(contentsOf: payload)
    }

    mutating func writeStringField(_ number: UInt64, _ text: String) {
        writeBytesField(number, Array(text.utf8))
    }

    mutating func writePackedField(_ number: UInt64, _ values: [UInt32]) {
        guard !values.isEmpty else { return }
        var packed = ProtobufWriter()
        for value in values { packed.writeVarint(UInt64(value)) }
        writeBytesField(number, packed.bytes)
    }
}

/// Zig-zag encoding (protobuf `sint32`/`sint64`): signed integers mapped to
/// unsigned so small magnitudes stay short — 0, −1, 1, −2 … become 0, 1, 2,
/// 3 ….
enum ZigZag {
    static func decode(_ value: UInt64) -> Int64 {
        Int64(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
    }

    static func decode(_ value: UInt32) -> Int32 {
        Int32(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
    }

    static func encode(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> (Int64.bitWidth - 1)))
    }

    static func encode(_ value: Int32) -> UInt32 {
        UInt32(bitPattern: (value << 1) ^ (value >> (Int32.bitWidth - 1)))
    }
}
