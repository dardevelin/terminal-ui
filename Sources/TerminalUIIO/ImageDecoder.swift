import Foundation

// Typed throws (`throws(ImageDecodeError)`) so consumers see the
// failure mode without dynamic-cast chains.

/// Decodes an image file's bytes into an ``ImageBuffer``.
///
/// Two decoders ship, in pure Swift so every system decodes alike:
/// ``PNGDecoder`` and ``JPEGDecoder``. Conform another type to read
/// another format — WebP, progressive JPEG, a domain's own. A decoder
/// checks the format's magic bytes itself, throws
/// ``ImageDecodeError/unsupportedFormat(magic:)`` when they are not its
/// format's, and ``ImageDecodeError/malformedData(reason:)`` when the
/// bytes are its format's but cannot be decoded; it never traps on them.
public protocol ImageDecoder: Sendable {
    /// Decode `data`, a whole image file, into straight RGBA.
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

extension ImageDecodeError {
    /// The refusal of an image whose header claims more pixels than its
    /// decoder allows — the same words from every decoder, so a reader
    /// can tell a size it may raise the limit for from a broken file.
    static func tooManyPixels(format: String, width: Int, height: Int, maximum: Int) -> ImageDecodeError {
        .malformedData(reason: "\(format): \(width)×\(height) is more pixels than the decoder allows (\(maximum))")
    }
}
