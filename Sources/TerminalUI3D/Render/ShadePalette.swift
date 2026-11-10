import Foundation
import TerminalUI

/// Every colour one material can be drawn in, worked out the first time it
/// is needed and then looked up: a frame shades tens of thousands of
/// samples, and converting each out of Oklab would cost a cube and three
/// powers apiece.
///
/// A colour is found by three numbers, each quantised to a level:
///
/// - the tone, the light the surface receives: 0 is unlit, 1 lit full on,
///   and above 1 a highlight. Up to 1 the colour is the material's in linear
///   light scaled by the tone, which in Oklab is every coordinate scaled by
///   its cube root — Oklab's lightness is the cube root of LMS cone response
///   (Ottosson, "A perceptual color space for image processing", 2020), and
///   scaling linear light scales LMS. So a shadow keeps its hue, and darkens
///   as an eye sees it darken rather than as the sRGB numbers do. Above 1
///   it is mixed toward white, as a shine is;
/// - the tint, the place along a gradient material;
/// - the fog, the share mixed toward the background — haze with distance,
///   and the part of a cell a shape's edge leaves uncovered.
final class ShadePalette {
    static let toneLevels = 64
    static let maximumTone: Float = 1.5
    static let tintLevels = 16
    static let fogLevels = 16
    /// How far a highlight at the top of the tone range goes toward white.
    static let highlightReach = 0.85
    /// Where a lightness is unknown, it is taken as the dark ground most
    /// terminals have.
    static let assumedGroundLightness: Float = 0

    let material: Material
    let background: Color?
    /// The background in Oklab, or nil when it is the terminal's own.
    private let ground: (Double, Double, Double)?
    /// The gradient's stops in Oklab.
    private let stops: [(Double, Double, Double)]
    let tintLevelCount: Int
    let fogLevelCount: Int
    /// Packed `0xRRGGBB`, or `unfilled`.
    private var packed: [UInt32]
    /// Each colour's Oklab lightness, 0 to 1.
    private var lightness: [Float]
    /// The background's lightness: what a colour's contrast is measured from.
    let groundLightness: Float

    private static let unfilled = UInt32.max

    init(material: Material, background: Color?) {
        self.material = material
        self.background = background
        let resolvedGround = background?.nominalRGB.map { Color.oklab(red: $0.red, green: $0.green, blue: $0.blue) }
        ground = resolvedGround.map { ($0.lightness, $0.greenRed, $0.blueYellow) }
        groundLightness = resolvedGround.map { Float($0.lightness) } ?? Self.assumedGroundLightness
        var stops: [(Double, Double, Double)] = material.colours.compactMap { colour in
            colour.nominalRGB.map {
                let lab = Color.oklab(red: $0.red, green: $0.green, blue: $0.blue)
                return (lab.lightness, lab.greenRed, lab.blueYellow)
            }
        }
        if stops.isEmpty {
            // A material of the terminal's own colours has nothing to shade;
            // mid grey, in Oklab, stands in.
            stops = [(Self.neutralLightness, 0, 0)]
        }
        self.stops = stops
        tintLevelCount = stops.count > 1 ? Self.tintLevels : 1
        fogLevelCount = ground == nil ? 1 : Self.fogLevels
        let count = Self.toneLevels * tintLevelCount * fogLevelCount
        packed = Array(repeating: Self.unfilled, count: count)
        lightness = Array(repeating: 0, count: count)
    }

    /// Oklab's lightness of mid grey.
    private static let neutralLightness = 0.6

    /// Whether fog and edges can be mixed toward the background.
    var mixesTowardGround: Bool { ground != nil }

    @inline(__always)
    func index(tone: Float, tint: Float, fog: Float) -> Int {
        let toneStep = Int((min(max(tone, 0), Self.maximumTone) / Self.maximumTone * Float(Self.toneLevels - 1)).rounded())
        let tintStep = tintLevelCount == 1 ? 0 : Int((min(max(tint, 0), 1) * Float(tintLevelCount - 1)).rounded())
        let fogStep = fogLevelCount == 1 ? 0 : Int((min(max(fog, 0), 1) * Float(fogLevelCount - 1)).rounded())
        return (tintStep * fogLevelCount + fogStep) * Self.toneLevels + toneStep
    }

    @inline(__always)
    func colour(at index: Int) -> Color {
        if packed[index] == Self.unfilled { fill(index) }
        let value = packed[index]
        return .rgb(UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8),
                    UInt8(truncatingIfNeeded: value))
    }

    /// The colour as `0xRRGGBB`.
    @inline(__always)
    func packedColour(at index: Int) -> UInt32 {
        if packed[index] == Self.unfilled { fill(index) }
        return packed[index]
    }

    /// The colour's Oklab lightness, 0 to 1.
    @inline(__always)
    func lightness(at index: Int) -> Float {
        if packed[index] == Self.unfilled { fill(index) }
        return lightness[index]
    }

    /// How far the colour stands out from the background, 0 (not at all)
    /// to 1 (as far as anything can from it).
    @inline(__always)
    func contrast(at index: Int) -> Float {
        let reach = max(groundLightness, 1 - groundLightness)
        return abs(lightness(at: index) - groundLightness) / reach
    }

    /// Whether the background is the darker half of the range: what
    /// decides which way an edge is pushed to stand out.
    var groundIsDark: Bool { groundLightness < Self.middleLightness }

    /// Halfway along Oklab's lightness, black at 0 to white at 1.
    static let middleLightness: Float = 0.5

    private func fill(_ index: Int) {
        let toneStep = index % Self.toneLevels
        let rest = index / Self.toneLevels
        let fogStep = rest % fogLevelCount
        let tintStep = rest / fogLevelCount
        let tone = Double(toneStep) / Double(Self.toneLevels - 1) * Double(Self.maximumTone)
        let tint = tintLevelCount == 1 ? 0 : Double(tintStep) / Double(tintLevelCount - 1)
        let fog = fogLevelCount == 1 ? 0 : Double(fogStep) / Double(fogLevelCount - 1)

        var lab = gradient(at: tint)
        if tone <= 1 {
            let scale = cbrt(tone)
            lab = (lab.0 * scale, lab.1 * scale, lab.2 * scale)
        } else {
            let shine = min(1, (tone - 1) / (Double(Self.maximumTone) - 1)) * Self.highlightReach
            lab = (lab.0 + (1 - lab.0) * shine, lab.1 * (1 - shine), lab.2 * (1 - shine))
        }
        if let ground {
            lab = (lab.0 + (ground.0 - lab.0) * fog, lab.1 + (ground.1 - lab.1) * fog,
                   lab.2 + (ground.2 - lab.2) * fog)
        }
        let colour = Color.fromOklab(lightness: lab.0, greenRed: lab.1, blueYellow: lab.2)
        if let rgb = colour.nominalRGB {
            packed[index] = UInt32(rgb.red) << 16 | UInt32(rgb.green) << 8 | UInt32(rgb.blue)
        } else {
            packed[index] = 0
        }
        lightness[index] = Float(min(1, max(0, lab.0)))
    }

    private func gradient(at tint: Double) -> (Double, Double, Double) {
        guard stops.count > 1 else { return stops[0] }
        let position = tint * Double(stops.count - 1)
        let lower = min(Int(position), stops.count - 2)
        let fraction = position - Double(lower)
        let from = stops[lower], to = stops[lower + 1]
        return (from.0 + (to.0 - from.0) * fraction, from.1 + (to.1 - from.1) * fraction,
                from.2 + (to.2 - from.2) * fraction)
    }
}
