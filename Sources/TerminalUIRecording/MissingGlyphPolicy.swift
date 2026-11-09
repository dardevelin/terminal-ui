/// The characters a picture drew as boxes because no glyph source had
/// them, and the frames — the runtime's frame numbers — that showed each.
package struct MissingGlyphs: Equatable, Sendable {
    package private(set) var frames: [Character: [Int]] = [:]

    package init() {}

    package var isEmpty: Bool { frames.isEmpty }

    package mutating func add(_ character: Character, frame: Int) {
        if frames[character]?.last != frame { frames[character, default: []].append(frame) }
    }

    /// One line per character, in code point order: `U+4E2D 中 in frames 3, 7`.
    package var lines: [String] {
        frames.sorted { $0.key.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.key.unicodeScalars.map(\.value)) }
            .map { character, frames in
                let codePoints = character.unicodeScalars.map { scalar in
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                }.joined(separator: " ")
                let noun = frames.count == 1 ? "frame" : "frames"
                return "\(codePoints) \(character) in \(noun) \(frames.map(String.init).joined(separator: ", "))"
            }
    }
}

/// What a render does when a glyph is in no font it was given: the last
/// step of the fallback order — a shape, the configured font, each
/// fallback font, the system's cascade, then this.
package enum MissingGlyphPolicy: String, CaseIterable, Sendable {
    /// Ask the system's font cascade, then draw a box. Raster pictures have
    /// no system engine yet, so this draws the box and says so.
    case system
    /// Draw a hollow box and warn, naming each character and its frames.
    case box
    /// Refuse the picture, naming each character and its frames: what the
    /// docs renders use, so no picture ships with a box in it.
    case fail

    /// The warnings `missing` calls for; throws for ``fail``.
    package func outcome(of missing: MissingGlyphs) throws(MissingGlyphError) -> [String] {
        guard !missing.isEmpty else { return [] }
        let list = missing.lines.map { "  " + $0 }.joined(separator: "\n")
        switch self {
        case .fail:
            throw MissingGlyphError(message: "no font has a glyph for:\n\(list)\n"
                + "add a font that has them with --fallback-font PATH, or draw them as boxes with --missing-glyph box")
        case .box:
            return ["no font has a glyph for these, drawn as boxes:\n\(list)"]
        case .system:
            return ["no font has a glyph for these, drawn as boxes — the system font cascade is not available to"
                + " raster pictures yet, so --missing-glyph system draws boxes, as box does:\n\(list)"]
        }
    }
}

package struct MissingGlyphError: Error, CustomStringConvertible {
    package let message: String
    package var description: String { message }
}
