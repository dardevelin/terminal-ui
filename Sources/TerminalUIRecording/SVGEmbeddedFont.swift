/// A TrueType font carried inside an SVG as `data:` URLs in `@font-face`
/// rules (CSS Fonts Level 4 §4; `font/ttf`, RFC 8081), so the picture's
/// text is drawn in it wherever the file is opened, an `<img>` included,
/// which may load nothing from outside the document.
package struct SVGEmbeddedFont: Sendable {
    /// One file of the family, at the weight it is drawn for.
    package struct Face: Sendable {
        /// The CSS weight (CSS Fonts §2.2): 400 regular, 700 bold.
        package var weight: Int
        package var trueType: [UInt8]

        package init(weight: Int, trueType: [UInt8]) {
            self.weight = weight
            self.trueType = trueType
        }
    }

    /// The name the rules give the family, put first in the font stack.
    package var family: String
    package var faces: [Face]

    package init(family: String, faces: [Face]) {
        self.family = family
        self.faces = faces
    }

    package static let regularWeight = 400
    package static let boldWeight = 700

    /// An `@font-face` rule a face, a line each.
    var fontFaceRules: String {
        faces.map { face in
            "@font-face{font-family:\"\(family)\";font-weight:\(face.weight);"
                + "src:url(data:font/ttf;base64,\(Base64.encoded(face.trueType))) format(\"truetype\")}\n"
        }.joined()
    }
}

/// Base 64 as RFC 4648 §4 defines it: the standard alphabet, `=` padding,
/// no line breaks, which a `data:` URL takes as it is (RFC 2397).
enum Base64 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    private static let padding = UInt8(ascii: "=")
    /// Three bytes make four characters of six bits each.
    private static let groupBytes = 3
    private static let sextetMask: UInt32 = 0x3F
    private static let sextetBits: UInt32 = 6
    private static let byteBits: UInt32 = 8

    static func encoded(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count + groupBytes - 1) / groupBytes * (groupBytes + 1))
        var index = 0
        while index < bytes.count {
            let count = min(groupBytes, bytes.count - index)
            var group: UInt32 = 0
            for offset in 0..<groupBytes {
                group <<= byteBits
                if offset < count { group |= UInt32(bytes[index + offset]) }
            }
            // A group of n bytes gives n + 1 characters; `=` fills the four.
            for position in 0...groupBytes {
                if position <= count {
                    let shift = sextetBits * UInt32(groupBytes - position)
                    output.append(alphabet[Int((group >> shift) & sextetMask)])
                } else {
                    output.append(padding)
                }
            }
            index += groupBytes
        }
        return String(decoding: output, as: UTF8.self)
    }
}
