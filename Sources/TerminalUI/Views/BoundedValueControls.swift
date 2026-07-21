/// Glyphs for the bounded-value trio, named once so a slider track and a gauge
/// fill cannot drift apart.
public enum SliderGlyph {
    /// The draggable position marker.
    public static let thumb = "●"
    /// Track to either side of the thumb.
    public static let track = "─"
    /// Gauge fill and remainder. Distinct from the track: a gauge shows a
    /// quantity, so it reads as a bar rather than a line with a marker.
    public static let fill = "█"
    public static let empty = "░"
    /// Stepper decrement / increment affordances.
    public static let decrement = "◂"
    public static let increment = "▸"
}

/// Default track width, in cells, when nothing constrains the control.
///
/// A slider needs a fixed budget to place its thumb proportionally, and
/// measuring the parent would require a `GeometryReader` whose seeded
/// measurement is wrong for exactly the frames that matter. 20 cells give one
/// thumb position per 5% — finer than the eye resolves in a terminal.
private let defaultTrackWidth = 20

// MARK: - Slider

/// A control for choosing a value from a continuous range.
///
/// ```swift
/// Slider(value: $volume, in: 0...100, step: 5, label: "Volume")
/// ```
///
/// Left/Right adjust by `step` — or 1% of the range when `step` is nil — and
/// Home/End jump to the bounds. Clicking the track jumps the thumb to that
/// position.
///
/// **Dragging the thumb is not supported.** The framework has no `.onDrag`
/// primitive yet, so the control ships keyboard- and click-driven rather than
/// half-wiring a gesture that would appear to work and then not track.
public struct Slider<V: BinaryFloatingPoint>: TerminalView {
    let value: Binding<V>
    let scale: BoundedValueScale<V>
    let step: V?
    let label: String?

    @TerminalEnvironment(\.isEnabled) private var isEnabled
    @TerminalEnvironment(\.formLabelWidth) private var formLabelWidth
    @TerminalEnvironment(\.formStacksRows) private var formStacksRows

    public init(
        value: Binding<V>,
        in bounds: ClosedRange<V> = 0...1,
        step: V? = nil,
        label: String? = nil
    ) {
        self.value = value
        self.scale = BoundedValueScale(bounds: bounds)
        self.step = step
        self.label = label
    }

    /// Bounds as two separate values, for the case a `ClosedRange` cannot
    /// express: `through` below `from`. `ClosedRange` traps on construction, so
    /// without this an inverted range could never reach the component to be
    /// reported. The control warns and renders disabled.
    public init(
        value: Binding<V>,
        from lower: V,
        through upper: V,
        step: V? = nil,
        label: String? = nil
    ) {
        self.value = value
        self.scale = upper >= lower
            ? BoundedValueScale(bounds: lower...upper)
            : BoundedValueScale(invertedLower: lower, upper: upper)
        self.step = step
        self.label = label
    }

    private var isInteractive: Bool {
        isEnabled && scale.isValid && !scale.isDegenerate
    }

    public var body: some TerminalView {
        #if DEBUG
        if !scale.isValid {
            DebugStream.shared.emitWarning(
                .boundedValueInvertedBounds,
                message: """
                    Slider was given an upper bound below its lower bound \
                    (\(scale.lower)...\(scale.upper)). The control renders \
                    disabled. Swap the bounds at the call site — the framework \
                    does not guess which end was intended.
                    """
            )
        }
        #endif

        let scale = self.scale
        let value = self.value
        let step = self.step
        let interactive = isInteractive
        let labelCells = labelWidthAsDrawn

        return FormRow(label: label ?? "") {
            HStack {
                Text(Self.track(fraction: scale.fraction(of: value.get())))
                Text(" \(BoundedValueScale.format(scale.clamp(value.get())))")
            }
        }
        .foreground(isEnabled && scale.isValid ? .default : .gray)
        .focusable()
        .onClick { relativeX, _ in
            guard interactive else { return }
            // Click coordinates arrive relative to the focusable row, so the
            // track starts after the label *as rendered* — which inside a Form
            // is padded to the shared column, not to `label.count`.
            let offset = relativeX - labelCells
            let lastIndex = defaultTrackWidth - 1
            let clamped = max(0, min(lastIndex, offset))
            value.set(scale.value(atFraction: V(clamped) / V(lastIndex)))
        }
        .onKeyPress { event in
            guard interactive else { return .ignored }
            let delta = scale.resolvedStep(step)
            switch event.key {
            case .left:
                value.set(scale.clamp(value.get() - delta))
                return .handled
            case .right:
                value.set(scale.clamp(value.get() + delta))
                return .handled
            case .home:
                value.set(scale.lower)
                return .handled
            case .end:
                value.set(scale.upper)
                return .handled
            default:
                return .ignored
            }
        }
    }

    /// Cells the label occupies as drawn, which is where the track begins.
    private var labelWidthAsDrawn: Int {
        FormLabel.rendered(text: label ?? "", width: formLabelWidth, stacks: formStacksRows).count
    }

    /// The track with the thumb placed proportionally.
    static func track(fraction: V) -> String {
        let lastIndex = defaultTrackWidth - 1
        let position = Int((Double(fraction) * Double(lastIndex)).rounded())
        let clamped = max(0, min(lastIndex, position))
        return String(repeating: SliderGlyph.track, count: clamped)
            + SliderGlyph.thumb
            + String(repeating: SliderGlyph.track, count: lastIndex - clamped)
    }
}

// MARK: - Stepper

/// A control for adjusting a value in discrete steps.
///
/// ```swift
/// Stepper("Tab width", value: $tabWidth, in: 1...16)
/// ```
///
/// Left/Right or `-`/`+` adjust by `step`. The affordance at a bound renders
/// dim, so the limit is visible before the user presses into it.
public struct Stepper<V: Strideable>: TerminalView where V.Stride: SignedNumeric {
    let label: String
    let value: Binding<V>
    let lower: V
    let upper: V
    let step: V.Stride
    let boundsAreValid: Bool

    @TerminalEnvironment(\.isEnabled) private var isEnabled

    public init(
        _ label: String,
        value: Binding<V>,
        in bounds: ClosedRange<V>,
        step: V.Stride = 1
    ) {
        self.label = label
        self.value = value
        self.lower = bounds.lowerBound
        self.upper = bounds.upperBound
        self.step = step
        self.boundsAreValid = true
    }

    /// Bounds that cannot form a `ClosedRange`. See `Slider`'s equivalent.
    public init(
        _ label: String,
        value: Binding<V>,
        from lower: V,
        through upper: V,
        step: V.Stride = 1
    ) {
        self.label = label
        self.value = value
        self.lower = lower
        self.upper = upper
        self.step = step
        self.boundsAreValid = upper >= lower
    }

    private func clamp(_ candidate: V) -> V {
        guard boundsAreValid else { return lower }
        return min(upper, max(lower, candidate))
    }

    private var isInteractive: Bool { isEnabled && boundsAreValid && upper > lower }

    public var body: some TerminalView {
        #if DEBUG
        if !boundsAreValid {
            DebugStream.shared.emitWarning(
                .boundedValueInvertedBounds,
                message: """
                    Stepper "\(label)" was given an upper bound below its lower \
                    bound. The control renders disabled. Swap the bounds at the \
                    call site — the framework does not guess which end was \
                    intended.
                    """
            )
        }
        #endif

        let current = clamp(value.get())
        let atLower = !isInteractive || current <= lower
        let atUpper = !isInteractive || current >= upper
        let value = self.value
        let interactive = isInteractive

        return FormRow(label: label) {
            HStack {
                Text(SliderGlyph.decrement).foreground(atLower ? .gray : .default)
                Text(" \(current) ")
                Text(SliderGlyph.increment).foreground(atUpper ? .gray : .default)
            }
        }
        .foreground(isEnabled && boundsAreValid ? .default : .gray)
        .focusable()
        .onKeyPress { event in
            guard interactive else { return .ignored }
            switch event.key {
            case .left, .character("-"):
                value.set(clamp(value.get().advanced(by: -step)))
                return .handled
            case .right, .character("+"):
                value.set(clamp(value.get().advanced(by: step)))
                return .handled
            default:
                return .ignored
            }
        }
    }
}

// MARK: - Gauge

/// A read-only display of a value within a range.
///
/// Distinct from `ProgressBar`, which is the obvious question: a **ProgressBar
/// means "this task is completing"** and implies an end state, while a
/// **Gauge means "this value sits here within its range"** and may move in
/// either direction forever — disk usage, battery, memory pressure.
///
/// Takes a value rather than a binding and is not focusable: it reports state
/// the app owns, so a stop in the Tab order would do nothing when reached.
public struct Gauge<V: BinaryFloatingPoint>: TerminalView {
    let value: V
    let scale: BoundedValueScale<V>
    let label: String?

    @TerminalEnvironment(\.isEnabled) private var isEnabled

    public init(value: V, in bounds: ClosedRange<V> = 0...1, label: String? = nil) {
        self.value = value
        self.scale = BoundedValueScale(bounds: bounds)
        self.label = label
    }

    public var body: some TerminalView {
        let fraction = scale.fraction(of: value)
        let filled = Int((Double(fraction) * Double(defaultTrackWidth)).rounded())
        return FormRow(label: label ?? "") {
            HStack {
                Text(String(repeating: SliderGlyph.fill, count: max(0, min(defaultTrackWidth, filled))))
                Text(String(repeating: SliderGlyph.empty,
                            count: max(0, defaultTrackWidth - filled)))
                Text(" \(BoundedValueScale.format(scale.clamp(value)))")
            }
        }
        .foreground(isEnabled ? .default : .gray)
    }
}

extension Stepper: _FormRowLabel {
    var formLabelText: String { label }
}

extension Slider: _FormRowLabel {
    /// A slider without a label still occupies a row; an empty string
    /// contributes nothing to the column width, which is correct.
    var formLabelText: String { label ?? "" }
}

extension Gauge: _FormRowLabel {
    var formLabelText: String { label ?? "" }
}
