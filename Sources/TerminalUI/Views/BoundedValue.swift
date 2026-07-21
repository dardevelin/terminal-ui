/// The value model behind `Slider`, `Stepper` and `Gauge`.
///
/// The three controls differ in how they *look* and which input they accept,
/// but they answer the same questions: where does this value sit in its range,
/// what is the nearest legal value, and how is a number written. Stating that
/// once is why the trio ships as one unit — three copies of these rules would
/// disagree the first time one of them was fixed.
///
/// Degenerate ranges are answered rather than rejected. A control whose model
/// is briefly nonsensical still has to render something, and returning a
/// defined answer here is what keeps every call site free of `guard` clauses.
struct BoundedValueScale<Value: BinaryFloatingPoint> {
    let lower: Value
    let upper: Value
    /// False when the caller passed `upper < lower` — a programmer error the
    /// components report and disable on, rather than silently swapping the
    /// ends and rendering something the caller never asked for.
    let isValid: Bool

    init(bounds: ClosedRange<Value>) {
        self.lower = bounds.lowerBound
        self.upper = bounds.upperBound
        self.isValid = true
    }

    /// Build a scale from bounds that could not form a `ClosedRange`.
    ///
    /// `ClosedRange` traps on `upper < lower`, so an inverted range cannot
    /// reach the components as a range value. Components accepting raw bounds
    /// use this to record the mistake and keep rendering.
    init(invertedLower lower: Value, upper: Value) {
        self.lower = lower
        self.upper = upper
        self.isValid = false
    }

    /// A range with exactly one legal value. Legal, but nothing can move.
    var isDegenerate: Bool { upper == lower }

    var span: Value { upper - lower }

    /// Where `value` sits between the bounds, as 0...1.
    ///
    /// A degenerate range reports 1.0 — the single legal value is, in every
    /// sense that matters to a track or a fill, "all the way". Dividing by the
    /// zero span instead would produce a NaN that silently poisons layout.
    func fraction(of value: Value) -> Value {
        guard isValid else { return 0 }
        guard !isDegenerate else { return 1 }
        return (clamp(value) - lower) / span
    }

    /// The nearest legal value. Out-of-range input is corrected, never
    /// rejected: the caller's model may legitimately be mid-edit.
    func clamp(_ value: Value) -> Value {
        guard isValid else { return lower }
        return min(upper, max(lower, value))
    }

    /// The value at `fraction` along the range — the inverse of `fraction(of:)`,
    /// used to turn a click position into a value.
    func value(atFraction fraction: Value) -> Value {
        guard isValid, !isDegenerate else { return lower }
        return clamp(lower + span * fraction)
    }

    /// The adjustment applied by one arrow press.
    ///
    /// A nil step means "give me something sensible for this range", which is
    /// 1% — one hundred presses to cross the control, matching the granularity
    /// a mouse-less user expects from a slider.
    func resolvedStep(_ step: Value?) -> Value {
        if let step, step > 0 { return step }
        return span / 100
    }

    /// Shared numeric formatting.
    ///
    /// Whole numbers lose their decimal point and fractions keep up to two
    /// places, so a slider and a gauge showing the same number always agree.
    /// Written by hand rather than with `NumberFormatter`, which is
    /// locale-sensitive and would make rendered output vary by host.
    ///
    /// `%g` is deliberately **not** used: it counts *significant* digits, so it
    /// truncates a real value (12.5 → "12") and switches to scientific notation
    /// past three digits (1234.5 → "1.2e+03"). A slider over `0...5000` steps by
    /// 50 by default, so both faults were reachable by ordinary use.
    static func format(_ value: Value) -> String {
        let double = Double(value)
        if double == double.rounded() { return String(Int(double)) }
        // Two decimal places, with trailing zeros trimmed so 0.50 reads "0.5".
        var text = String(format: "%.2f", double)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
