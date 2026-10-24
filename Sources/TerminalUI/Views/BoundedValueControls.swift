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
    /// Gauge remainder — the unfilled portion after ``fill``.
    public static let empty = "░"
    /// Stepper decrement affordance.
    public static let decrement = "◂"
    /// Stepper increment affordance.
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
/// Renders as a 20-cell track with a `●` thumb placed proportionally,
/// followed by the numeric value — one row, one stop in the Tab order via
/// the framework's `.focusable` machinery. Left/Right adjust by `step` — or
/// 1% of the range when `step` is nil — and Home/End jump to the bounds.
/// Clicking the track jumps the thumb to that position. Inside a ``Form``
/// the label joins the shared column so the track aligns with sibling
/// controls.
///
/// The continuous member of the bounded-value trio: reach for ``Stepper``
/// when the value is discrete and every increment matters (a count, a
/// width), and ``Gauge`` when the value is read-only state to display
/// rather than a setting to adjust.
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

    /// Creates a slider over a closed range.
    ///
    /// - Parameters:
    ///   - value: The chosen value; clamped into `bounds` on every write.
    ///   - bounds: The range the track spans. Defaults to `0...1`.
    ///   - step: Left/Right increment. `nil` means 1% of the range.
    ///   - label: Optional text before the track; joins the shared column
    ///     inside a ``Form``.
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

    @TerminalEnvironment(\.theme) private var theme

    @_documentation(visibility: internal)
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
        .labelForeground(enabled: isEnabled && scale.isValid, theme: theme)
        .focusable()
        .onClick { relativeX, _ in
            guard interactive else { return }
            // Click coordinates arrive relative to the focusable row, so the
            // track starts after the label *as rendered* — which inside a Form
            // is padded to the shared column, not to `label.count`.
            let offset = relativeX - labelCells
            let lastIndex = defaultTrackWidth - 1
            // Only the track sets the value. Clamped instead, a click on the
            // label set the minimum and one on the value text the maximum.
            guard (0...lastIndex).contains(offset) else { return }
            value.set(scale.value(atFraction: V(offset) / V(lastIndex)))
        }
        .onKeyPress { event in
            guard interactive, !event.isModifiedNavigation else { return .ignored }
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
        FormLabel.rendered(text: label ?? "", width: formLabelWidth, stacks: formStacksRows).displayWidth
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
/// Renders as `◂ value ▸` on one row — one stop in the Tab order via the
/// framework's `.focusable` machinery. Left/Right or `-`/`+` adjust by
/// `step`, and clicking either affordance presses it. The affordance at a
/// bound renders dim, so the limit is visible before the user presses into
/// it. Inside a ``Form`` the label joins the shared column.
///
/// The discrete member of the bounded-value trio: reach for ``Slider``
/// when the value is continuous and its position within the range is what
/// matters, and ``Gauge`` for read-only display. Any `Strideable` value
/// works — counts, sizes, or floating-point values stepped by a fixed
/// stride.
public struct Stepper<V: Strideable>: TerminalView where V.Stride: SignedNumeric {
    let label: String
    let value: Binding<V>
    let lower: V
    let upper: V
    let step: V.Stride
    let boundsAreValid: Bool

    @TerminalEnvironment(\.isEnabled) private var isEnabled
    @TerminalEnvironment(\.formLabelWidth) private var formLabelWidth
    @TerminalEnvironment(\.formStacksRows) private var formStacksRows

    /// Cells the label occupies as drawn, which is where the affordances
    /// begin. Measured through `FormLabel.rendered` rather than re-derived
    /// from `label.count`, because inside a `Form` the label is padded to the
    /// shared column — the mistake that made `Slider`'s track clicks land far
    /// from where the user pressed.
    private var labelWidthAsDrawn: Int {
        FormLabel.rendered(text: label, width: formLabelWidth, stacks: formStacksRows).displayWidth
    }

    /// Creates a stepper over a closed range.
    ///
    /// - Parameters:
    ///   - label: Text before the affordances; joins the shared column
    ///     inside a ``Form``.
    ///   - value: The adjusted value; clamped into `bounds` on every write.
    ///   - bounds: The limits the value cannot leave.
    ///   - step: Stride per press. Defaults to 1.
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

    @TerminalEnvironment(\.theme) private var theme

    @_documentation(visibility: internal)
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
        let step = self.step
        let labelCells = labelWidthAsDrawn

        return FormRow(label: label) {
            HStack {
                Text(SliderGlyph.decrement).labelForeground(enabled: !atLower, theme: theme)
                Text(" \(current) ")
                Text(SliderGlyph.increment).labelForeground(enabled: !atUpper, theme: theme)
            }
        }
        .labelForeground(enabled: isEnabled && boundsAreValid, theme: theme)
        .focusable()
        .onClick { relativeX, _ in
            guard interactive else { return }
            // The affordances are drawn to be pressed, so they have to be
            // pressable. Click coordinates arrive relative to the focusable
            // row, and inside a Form the label is padded to the shared column
            // — the same correction `Slider` makes for its track.
            switch relativeX - labelCells {
            case ..<0: return
            case 0: value.set(clamp(value.get().advanced(by: -step)))
            default:
                // Anything right of the decrement glyph and the value it
                // guards reads as the increment side; the value text is
                // narrow and demanding a single-cell hit would make the
                // control feel broken.
                let incrementColumn = 1 + " \(current) ".count
                if relativeX - labelCells >= incrementColumn {
                    value.set(clamp(value.get().advanced(by: step)))
                }
            }
        }
        .onKeyPress { event in
            guard interactive, !event.isModifiedNavigation else { return .ignored }
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
/// ```swift
/// Gauge(value: 0.62, label: "Disk")
/// ```
///
/// Renders as a 20-cell bar — `█` fill, `░` remainder — followed by the
/// numeric value, on one row. Inside a ``Form`` the label joins the shared
/// column, so gauges align with the interactive rows around them.
///
/// Distinct from ``ProgressBar``, which is the obvious question: a **ProgressBar
/// means "this task is completing"** and implies an end state, while a
/// **Gauge means "this value sits here within its range"** and may move in
/// either direction forever — disk usage, battery, memory pressure. When the
/// user should *set* the value rather than read it, reach for ``Slider`` or
/// ``Stepper``.
///
/// Takes a value rather than a binding and Tab never stops on it: it reports
/// state the app owns, so a stop in the Tab order would do nothing when
/// reached. The arrow row-cursor still visits it, so a form's walk does not
/// strand the rows below.
public struct Gauge<V: BinaryFloatingPoint>: TerminalView {
    let value: V
    let scale: BoundedValueScale<V>
    let label: String?

    @TerminalEnvironment(\.isEnabled) private var isEnabled

    /// Creates a read-only gauge.
    ///
    /// - Parameters:
    ///   - value: The value to display; clamped into `bounds` for rendering.
    ///   - bounds: The range the bar spans. Defaults to `0...1`.
    ///   - label: Optional text before the bar; joins the shared column
    ///     inside a ``Form``.
    public init(value: V, in bounds: ClosedRange<V> = 0...1, label: String? = nil) {
        self.value = value
        self.scale = BoundedValueScale(bounds: bounds)
        self.label = label
    }
    @TerminalEnvironment(\.theme) private var theme


    @_documentation(visibility: internal)
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
        .labelForeground(enabled: isEnabled, theme: theme)
        // Reports state the app owns, so there is nothing here to operate —
        // but it is still a row, and a cursor that stopped above it would
        // strand whatever a form puts below. Arrows visit it; Tab does not.
        .focusable()
        .environment(\.focusIsReadOnly, true)
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
