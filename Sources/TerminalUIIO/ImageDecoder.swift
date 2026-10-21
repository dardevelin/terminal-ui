import Foundation

// Protocol seam for image decoders. No default decoder ships;
// consumers supply their own (swift-png, swift-image,
// or domain-specific formats) by conforming this protocol.
//
// Typed throws (`throws(ImageDecodeError)`) so consumers see the
// failure mode without dynamic-cast chains. Each decoder is
// responsible for sniffing format from the data's magic bytes
// and producing a well-formed ImageBuffer.

public protocol ImageDecoder: Sendable {
    func decode(_ data: Data) throws(ImageDecodeError) -> ImageBuffer
}

/// Failure modes for image decode. Each case carries the
/// information a consumer needs to surface a helpful error.
public enum ImageDecodeError: Error, Sendable {
    /// Input data's magic bytes didn't match a supported format.
    case unsupportedFormat(magic: [UInt8])
    /// Input data's format was recognised but the bytes were
    /// malformed.
    case malformedData(reason: String)
}
