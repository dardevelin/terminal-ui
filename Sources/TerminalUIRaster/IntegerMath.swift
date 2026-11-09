/// The divisions the font and rasterizer code share. Swift's `/` truncates
/// toward zero, which would round a glyph's left and right halves in
/// opposite directions; these round toward negative infinity, so a shape
/// moved by a whole pixel rounds the same way wherever it lands. All of it
/// is on 64-bit `Int`, which is what keeps a glyph the same bytes on
/// arm64 and x86_64.
enum IntegerMath {
    /// ⌊numerator / denominator⌋.
    static func floorDivide(_ numerator: Int, _ denominator: Int) -> Int {
        precondition(denominator != 0, "a division by zero")
        let quotient = numerator / denominator
        return (numerator % denominator != 0) && ((numerator < 0) != (denominator < 0)) ? quotient - 1 : quotient
    }

    /// ⌈numerator / denominator⌉.
    static func ceilDivide(_ numerator: Int, _ denominator: Int) -> Int {
        -floorDivide(-numerator, denominator)
    }

    /// numerator / denominator to the nearest integer, a half rounded up
    /// (toward positive infinity).
    static func roundedDivide(_ numerator: Int, _ denominator: Int) -> Int {
        // n/d + 1/2 is (2n + d) / 2d, whichever sign d has.
        floorDivide(2 * numerator + denominator, 2 * denominator)
    }

    /// ⌊√value⌋, by Newton's iteration on integers (it decreases
    /// monotonically from any start above the root).
    static func squareRoot(_ value: Int) -> Int {
        precondition(value >= 0, "the square root of \(value)")
        guard value > 1 else { return value }
        var estimate = value
        var next = (estimate + 1) / 2
        while next < estimate {
            estimate = next
            next = (estimate + value / estimate) / 2
        }
        return estimate
    }
}
