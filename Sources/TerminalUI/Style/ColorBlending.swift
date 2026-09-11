import Foundation
import TerminalInk

// Color arithmetic: blending two colors and building ramps between them.
//
// Interpolation happens in Oklab, not sRGB. Mixing sRGB channels directly
// passes through a muddy, desaturated middle — the classic blue-to-yellow
// ramp that turns grey halfway — because sRGB is not perceptually uniform and
// equal numeric steps are not equal visual steps. Oklab is built so they are,
// which is what makes an eight-cell gradient across a wordmark read as one
// smooth sweep rather than a bright end and a dead middle.
//
// Oklab rather than HCL (which Lip Gloss and go-colorful use): the transform
// is a pair of matrix multiplies with a cube root between them, it needs no
// gamut clamping for interpolation, and it has no hue channel — so there is no
// "which way round the wheel" decision to get wrong when two stops sit on
// opposite sides of it.
//
// Coefficients are Björn Ottosson's published sRGB↔Oklab transform
// (https://bottosson.github.io/posts/oklab/). They are the specification, not
// tuned values, and are grouped here rather than inlined so the matrices can
// be read against the source.

/// The sRGB ↔ Oklab transform, as published.
private enum Oklab {
    /// sRGB transfer function threshold and constants (IEC 61966-2-1).
    static let gammaThreshold = 0.04045
    static let gammaLinearThreshold = 0.0031308
    static let gammaSlope = 12.92
    static let gammaOffset = 0.055
    static let gammaScale = 1.055
    static let gammaExponent = 2.4

    /// Linear sRGB → LMS cone response.
    static let toLMS = (
        l: (0.4122214708, 0.5363325363, 0.0514459929),
        m: (0.2119034982, 0.6806995451, 0.1073969566),
        s: (0.0883024619, 0.2817188376, 0.6299787005)
    )

    /// Cube-rooted LMS → Oklab.
    static let toLab = (
        L: (0.2104542553, 0.7936177850, -0.0040720468),
        a: (1.9779984951, -2.4285922050, 0.4505937099),
        b: (0.0259040371, 0.7827717662, -0.8086757660)
    )

    /// Oklab → cube-rooted LMS.
    static let toLMSPrime = (
        l: (1.0, 0.3963377774, 0.2158037573),
        m: (1.0, -0.1055613458, -0.0638541728),
        s: (1.0, -0.0894841775, -1.2914855480)
    )

    /// LMS → linear sRGB.
    static let toLinear = (
        r: (4.0767416621, -3.3077115913, 0.2309699292),
        g: (-1.2684380046, 2.6097574011, -0.3413193965),
        b: (-0.0041960863, -0.7034186147, 1.7076147010)
    )

    /// One channel, sRGB-encoded (0…1) → linear.
    static func linearize(_ channel: Double) -> Double {
        channel <= gammaThreshold
            ? channel / gammaSlope
            : pow((channel + gammaOffset) / gammaScale, gammaExponent)
    }

    /// One channel, linear → sRGB-encoded (0…1).
    static func encode(_ channel: Double) -> Double {
        channel <= gammaLinearThreshold
            ? channel * gammaSlope
            : gammaScale * pow(channel, 1 / gammaExponent) - gammaOffset
    }

    static func fromRGB(_ rgb: (red: UInt8, green: UInt8, blue: UInt8)) -> (Double, Double, Double) {
        let r = linearize(Double(rgb.red) / 255)
        let g = linearize(Double(rgb.green) / 255)
        let b = linearize(Double(rgb.blue) / 255)

        let l = cbrt(toLMS.l.0 * r + toLMS.l.1 * g + toLMS.l.2 * b)
        let m = cbrt(toLMS.m.0 * r + toLMS.m.1 * g + toLMS.m.2 * b)
        let s = cbrt(toLMS.s.0 * r + toLMS.s.1 * g + toLMS.s.2 * b)

        return (toLab.L.0 * l + toLab.L.1 * m + toLab.L.2 * s,
                toLab.a.0 * l + toLab.a.1 * m + toLab.a.2 * s,
                toLab.b.0 * l + toLab.b.1 * m + toLab.b.2 * s)
    }

    static func toRGB(_ lab: (Double, Double, Double)) -> (UInt8, UInt8, UInt8) {
        let (lightness, greenRed, blueYellow) = lab

        let lPrime = toLMSPrime.l.0 * lightness + toLMSPrime.l.1 * greenRed + toLMSPrime.l.2 * blueYellow
        let mPrime = toLMSPrime.m.0 * lightness + toLMSPrime.m.1 * greenRed + toLMSPrime.m.2 * blueYellow
        let sPrime = toLMSPrime.s.0 * lightness + toLMSPrime.s.1 * greenRed + toLMSPrime.s.2 * blueYellow

        let l = lPrime * lPrime * lPrime
        let m = mPrime * mPrime * mPrime
        let s = sPrime * sPrime * sPrime

        // Interpolating between two in-gamut colors can still land marginally
        // outside it through floating-point drift, so each channel is clamped
        // rather than trusted — an unclamped 1.0000001 wraps to 0 in UInt8.
        func channel(_ value: Double) -> UInt8 {
            UInt8(max(0, min(255, (encode(value) * 255).rounded())))
        }

        return (channel(toLinear.r.0 * l + toLinear.r.1 * m + toLinear.r.2 * s),
                channel(toLinear.g.0 * l + toLinear.g.1 * m + toLinear.g.2 * s),
                channel(toLinear.b.0 * l + toLinear.b.1 * m + toLinear.b.2 * s))
    }
}

extension Color {
    /// This color as an exact sRGB triple, or `nil` when it has none.
    ///
    /// Named palette entries resolve to xterm's defaults — a stand-in, since
    /// what the terminal paints for ``Color/red`` is the user's business.
    /// ``Color/default`` resolves to nothing at all: it means "whatever the
    /// terminal uses when no color is set", which is not a value this process
    /// can know.
    public var nominalRGB: (red: UInt8, green: UInt8, blue: UInt8)? {
        asInkColor.nominalRGB
    }

    /// This color mixed toward `other`, in Oklab.
    ///
    /// `amount` is the distance travelled: `0` returns this color, `1`
    /// returns `other`, `0.5` the perceptual midpoint. Values outside `0...1`
    /// are clamped rather than extrapolated.
    ///
    /// The result is always an exact ``Color/rgb(_:_:_:)``, because a blend
    /// between palette slots is not itself a palette slot. That means
    /// blending **leaves the user's terminal theme behind** — deliberate, and
    /// the reason to reach for it only where an exact ramp is the point.
    /// Terminals without truecolor degrade the result the same way they
    /// degrade any other `.rgb` value.
    ///
    /// When either end has no resolvable value — ``Color/default`` — there is
    /// nothing to interpolate, so the nearer end is returned unchanged.
    ///
    /// ```swift
    /// Color.rgb(124, 92, 255).blended(with: .rgb(61, 219, 217), amount: 0.5)
    /// ```
    public func blended(with other: Color, amount: Double) -> Color {
        let t = max(0, min(1, amount))
        guard let start = nominalRGB, let end = other.nominalRGB else {
            return t < 0.5 ? self : other
        }
        let from = Oklab.fromRGB(start)
        let to = Oklab.fromRGB(end)
        let mixed = (from.0 + (to.0 - from.0) * t,
                     from.1 + (to.1 - from.1) * t,
                     from.2 + (to.2 - from.2) * t)
        let (r, g, b) = Oklab.toRGB(mixed)
        return .rgb(r, g, b)
    }

    /// `count` colors stepping evenly from this color to `other`, inclusive
    /// of both ends.
    ///
    /// A ramp of 1 is just this color; a ramp of 0 is empty. The endpoints
    /// are always exact, so a ramp and a pair of `blended` calls at 0 and 1
    /// agree.
    ///
    /// ```swift
    /// let ramp = Color.rgb(124, 92, 255).ramp(to: .rgb(255, 122, 198), count: 12)
    /// ```
    public func ramp(to other: Color, count: Int) -> [Color] {
        guard count > 1 else { return count == 1 ? [self] : [] }
        return (0..<count).map { step in
            blended(with: other, amount: Double(step) / Double(count - 1))
        }
    }

    /// `count` colors stepping through every stop in order.
    ///
    /// Segments share the total evenly, so a three-stop ramp of 9 spends 5
    /// colors reaching the middle stop and 5 reaching the end, the middle one
    /// shared. Fewer than two stops falls back to the single-stop behaviour
    /// of ``ramp(to:count:)``.
    public static func ramp(through stops: [Color], count: Int) -> [Color] {
        guard count > 0 else { return [] }
        guard stops.count > 1 else { return stops.first.map { Array(repeating: $0, count: count) } ?? [] }
        guard count > 1 else { return [stops[0]] }

        let segments = Double(stops.count - 1)
        return (0..<count).map { step in
            // Position along the whole ramp, scaled into segment space: the
            // integer part picks the segment, the fraction the position in it.
            let position = Double(step) / Double(count - 1) * segments
            let index = min(Int(position), stops.count - 2)
            return stops[index].blended(with: stops[index + 1], amount: position - Double(index))
        }
    }
}
