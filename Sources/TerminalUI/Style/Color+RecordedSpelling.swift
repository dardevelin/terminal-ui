// How a `.tuirec` recording log spells a colour (RecordingLog.swift): nil
// for the terminal's own, the 16 palette names, `idx:N`, `rgb:rrggbb`. The
// debug runtime's recorder writes these and swtui's renderers read them
// back, so both directions live here, over one table. Not debug-only: a
// release build of swtui renders recordings too.

extension Color {
    /// The 16 palette colours in ANSI order — palette slot `i` is entry
    /// `i` — by the names the log spells them with, which are their case
    /// names.
    package static let recordedNames: [(color: Color, name: String)] = [
        (.black, "black"), (.red, "red"), (.green, "green"), (.yellow, "yellow"),
        (.blue, "blue"), (.magenta, "magenta"), (.cyan, "cyan"), (.white, "white"),
        (.gray, "gray"), (.brightRed, "brightRed"), (.brightGreen, "brightGreen"),
        (.brightYellow, "brightYellow"), (.brightBlue, "brightBlue"),
        (.brightMagenta, "brightMagenta"), (.brightCyan, "brightCyan"), (.brightWhite, "brightWhite"),
    ]

    /// How the log spells this colour: nil for the terminal's own, a palette
    /// name, `idx:N`, or `rgb:rrggbb`. Kept as encoded, not resolved: which
    /// red `.red` is belongs to the palette a picture is rendered with.
    package var recordedSpelling: String? {
        switch self {
        case .default: return nil
        case .ansi256(let index): return RecordedSpelling.indexed + String(index)
        case .rgb(let red, let green, let blue):
            return RecordedSpelling.rgb + [red, green, blue].map { component in
                let hex = String(component, radix: RecordedSpelling.hexRadix)
                return hex.count == 1 ? "0" + hex : hex
            }.joined()
        default:
            return Self.recordedNames.first { $0.color == self }?.name
        }
    }

    /// The colour a log's spelling names, or nil for one it cannot: the
    /// inverse of ``recordedSpelling`` for every colour but `.default`,
    /// which the log spells as `null`, not as a string.
    package init?(recordedSpelling spelling: String) {
        if let named = Self.recordedNames.first(where: { $0.name == spelling }) {
            self = named.color
        } else if spelling.hasPrefix(RecordedSpelling.indexed) {
            let digits = spelling.dropFirst(RecordedSpelling.indexed.count)
            guard digits.allSatisfy(RecordedSpelling.decimalDigits.contains), digits == "0" || digits.first != "0",
                  let index = UInt8(digits) else { return nil }
            self = .ansi256(index)
        } else if spelling.hasPrefix(RecordedSpelling.rgb) {
            let hex = Array(spelling.utf8.dropFirst(RecordedSpelling.rgb.count))
            guard hex.count == RecordedSpelling.rgbHexDigits else { return nil }
            var channels: [UInt8] = []
            for start in stride(from: 0, to: hex.count, by: RecordedSpelling.channelHexDigits) {
                let pair = String(decoding: hex[start..<start + RecordedSpelling.channelHexDigits], as: UTF8.self)
                guard pair.utf8.allSatisfy(RecordedSpelling.isLowercaseHexDigit),
                      let channel = UInt8(pair, radix: RecordedSpelling.hexRadix) else { return nil }
                channels.append(channel)
            }
            self = .rgb(channels[0], channels[1], channels[2])
        } else {
            return nil
        }
    }
}

/// The spelling's parts: a prefix, then a decimal index or six lowercase
/// hex digits, two per channel, red first — what the writer emits, and
/// nothing else, so a spelling reads back to the one colour it was made from.
private enum RecordedSpelling {
    static let indexed = "idx:"
    static let rgb = "rgb:"
    static let hexRadix = 16
    static let channelHexDigits = 2
    static let rgbHexDigits = 6
    static let decimalDigits: ClosedRange<Character> = "0"..."9"

    static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }
}
