import TerminalUI

/// An sRGB colour, one byte a channel.
package struct RGB: Hashable, Sendable, CustomStringConvertible {
    package var red: UInt8
    package var green: UInt8
    package var blue: UInt8

    package init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xRRGGBB`, as colour schemes are published.
    package init(hex: UInt32) {
        self.init(UInt8(truncatingIfNeeded: hex >> RGBLayout.redShift),
                  UInt8(truncatingIfNeeded: hex >> RGBLayout.greenShift),
                  UInt8(truncatingIfNeeded: hex))
    }

    /// `#rrggbb`, lowercase: how asciicast's theme and CSS write a colour.
    package var hexString: String {
        "#" + [red, green, blue].map { channel in
            let hex = String(channel, radix: RGBLayout.hexRadix)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    package var description: String { hexString }
}

private enum RGBLayout {
    static let redShift: UInt32 = 16
    static let greenShift: UInt32 = 8
    static let hexRadix = 16
}

/// The colours a picture of a recording is drawn in: what the terminal it
/// pretends to be would show for each colour the app asked for.
///
/// A recording keeps colours as the app encoded them, so a palette decides:
///
/// - the terminal's own foreground (``Color/default`` or none) is the
///   palette's ``foreground``;
/// - the terminal's own background is the window background the app set
///   (OSC 11), when it set one, else the palette's ``background``;
/// - the 16 named colours and `ansi256(0…15)` are the palette's ``ansi``
///   slots — the part of a terminal's palette its theme changes;
/// - `ansi256(16…255)` is xterm's 6×6×6 cube and grey ramp, which no theme
///   changes;
/// - `rgb` is itself.
package struct RecordingPalette: Equatable, Sendable {
    /// What `--palette` calls it.
    package var name: String
    package var foreground: RGB
    package var background: RGB
    /// The 16 ANSI slots: black, red, green, yellow, blue, magenta, cyan,
    /// white, then their bright forms — ``Color``'s order, `.gray` eighth.
    package var ansi: [RGB]

    /// The slots a terminal's theme sets (ECMA-48 SGR 30–37 and 90–97).
    package static let ansiSlots = 16

    package init(name: String, foreground: RGB, background: RGB, ansi: [RGB]) {
        precondition(ansi.count == Self.ansiSlots, "a palette has \(Self.ansiSlots) ANSI colours")
        self.name = name
        self.foreground = foreground
        self.background = background
        self.ansi = ansi
    }

    /// Catppuccin Mocha's terminal scheme, which the docs are drawn in: its
    /// `text` on its `base`, and its `ansiColors`, normal then bright.
    /// Taken from catppuccin/palette v1.8.0, `palette.json`, flavour
    /// `mocha` (https://github.com/catppuccin/palette/blob/v1.8.0/palette.json).
    package static let catppuccinMocha = RecordingPalette(
        name: "catppuccin-mocha",
        foreground: RGB(hex: 0xCDD6F4), background: RGB(hex: 0x1E1E2E),
        ansi: [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
            0x585B70, 0xF37799, 0x89D88B, 0xEBD391, 0x74A8FC, 0xF2AEDE, 0x6BD7CA, 0xBAC2DE,
        ].map(RGB.init(hex:)))

    /// xterm's default 16 colours, as the framework's nominal table holds
    /// them (``Color/nominalRGB``), its white on its black: the dark ground
    /// the framework's apps are drawn for, where xterm's own resource
    /// default would be black on white.
    package static let xterm: RecordingPalette = {
        let ansi = (0..<UInt8(ansiSlots)).map { RGB(nominal: .ansi256($0)) }
        return RecordingPalette(name: "xterm", foreground: ansi[ANSISlot.white],
                                background: ansi[ANSISlot.black], ansi: ansi)
    }()

    /// Every palette `--palette` offers.
    package static let all: [RecordingPalette] = [.catppuccinMocha, .xterm]

    package static func named(_ name: String) -> RecordingPalette? {
        all.first { $0.name == name }
    }

    /// What a cell's text shows in: `color` nil or ``Color/default`` is the
    /// terminal's own foreground.
    package func foreground(_ color: Color?) -> RGB {
        color.flatMap(rgb) ?? foreground
    }

    /// What a cell's background shows: `color` nil or ``Color/default`` is
    /// the terminal's own, which the window background the app set, if any,
    /// replaces.
    package func background(_ color: Color?, windowBackground: Color?) -> RGB {
        color.flatMap(rgb) ?? defaultBackground(windowBackground: windowBackground)
    }

    /// The terminal's own background: the one the app set, else the palette's.
    package func defaultBackground(windowBackground: Color?) -> RGB {
        windowBackground.flatMap(rgb) ?? background
    }

    /// The colour `color` names; nil for ``Color/default``, which names
    /// whichever the terminal uses.
    package func rgb(_ color: Color) -> RGB? {
        switch color {
        case .default:
            return nil
        case .rgb(let red, let green, let blue):
            return RGB(red, green, blue)
        case .ansi256(let index) where Int(index) < Self.ansiSlots:
            return ansi[Int(index)]
        case .ansi256:
            return RGB(nominal: color)
        default:
            guard let slot = Color.recordedNames.firstIndex(where: { $0.color == color }) else { return nil }
            return ansi[slot]
        }
    }
}

/// Slots the xterm palette's ground is taken from.
private enum ANSISlot {
    static let black = 0
    static let white = 7
}

extension RGB {
    /// The colour's nominal sRGB, from TerminalInk's table, for a colour
    /// that has one: every one but ``Color/default``.
    fileprivate init(nominal color: Color) {
        let rgb = color.nominalRGB ?? (0, 0, 0)
        self.init(rgb.red, rgb.green, rgb.blue)
    }
}
