/// A press of a mouse button, as the focus engine routes it: where it
/// landed, which button, how many presses in a row it ends, and the
/// modifiers held.
struct PointerPress {
    let x: Int
    let y: Int
    var button: MouseButton = .left
    /// 1 for a single click, 2 for the second of a double click; see
    /// `ClickCounter`.
    var count = 1
    var modifiers: KeyModifiers = []
}

/// Counts presses into clicks the way platforms do — AppKit's
/// `NSEvent.clickCount`: a press of the same button on the same cell soon
/// after the last one continues its run; anything else starts a new one.
struct ClickCounter {
    /// macOS's default double-click interval, and GTK's
    /// `gtk-double-click-time` rounded up from 400 ms.
    static let interval = Duration.milliseconds(500)

    private var last: (button: MouseButton, x: Int, y: Int, at: ContinuousClock.Instant, count: Int)?

    /// The click count of a press of `button` at (`x`, `y`) at `time`.
    mutating func count(_ button: MouseButton, x: Int, y: Int,
                        at time: ContinuousClock.Instant) -> Int {
        var count = 1
        if let last, last.button == button, last.x == x, last.y == y,
           time - last.at <= Self.interval {
            count = last.count + 1
        }
        last = (button, x, y, time, count)
        return count
    }
}

/// What a tap gesture waits for, and what it does.
struct TapRecognizer {
    let count: Int
    let modifiers: KeyModifiers?
    let action: () -> Void

    /// A single tap takes every left click, as a button does, however
    /// quickly they come; a double tap takes the second of a pair, a triple
    /// the third. Required modifiers must be exactly the ones held; with
    /// none required, any are.
    func accepts(_ press: PointerPress) -> Bool {
        guard press.button == .left else { return false }
        guard count == 1 || press.count == count else { return false }
        return modifiers.map { $0 == press.modifiers } ?? true
    }
}

/// A click, or a run of clicks, on a view: SwiftUI's `TapGesture`.
///
/// Attach one with ``TerminalView/gesture(_:)-(TapGesture)`` — or, for a
/// plain tap, ``TerminalView/onTapGesture(count:perform:)``:
///
/// ```swift
/// Text(file.name)
///     .gesture(TapGesture().modifiers(.ctrl).onEnded { addToSelection(file) })
///     .onTapGesture(count: 2) { open(file) }
///     .onTapGesture { select(file) }
/// ```
///
/// A tap happens on the press, as everything the mouse does in a
/// terminal does. A press reaches the deepest tap gesture under it that
/// waits for it; one that does not — a double tap, on a first click —
/// leaves it to the gesture declared after it. A single tap takes every
/// click, so declare it last, as in SwiftUI: declared first, it takes the
/// second click of a double click too, and the double tap never sees one.
/// Above, the first click selects and the second opens.
///
/// Terminals keep some modifiers for themselves: most select text on
/// Shift+click, and some on Alt+click. Ctrl+click reaches the app in
/// every terminal that reports the mouse.
public struct TapGesture {
    /// How many clicks in a row the gesture waits for: 1 for a tap, 2 for
    /// a double tap.
    public let count: Int
    var requiredModifiers: KeyModifiers?
    var action: () -> Void = {}

    /// A gesture that waits for `count` clicks in a row.
    public init(count: Int = 1) {
        self.count = max(1, count)
    }

    /// The gesture with `action` to run when it happens.
    public func onEnded(_ action: @escaping () -> Void) -> TapGesture {
        var gesture = self
        gesture.action = action
        return gesture
    }

    /// The gesture, taking only clicks made with exactly `modifiers` held.
    /// Without this it takes a click with any held.
    public func modifiers(_ modifiers: KeyModifiers) -> TapGesture {
        var gesture = self
        gesture.requiredModifiers = modifiers
        return gesture
    }

    var recognizer: TapRecognizer {
        TapRecognizer(count: count, modifiers: requiredModifiers, action: action)
    }
}

/// Payload of `.gesture(_:)` for a ``TapGesture``.
public struct TapGestureModifier: ViewModifier {
    @_documentation(visibility: internal)
    public typealias ModifierType = Void
    /// The gesture the view waits for.
    public let gesture: TapGesture
}

extension TerminalView {
    /// Run `gesture`'s action when the view is tapped as it describes: a
    /// count of clicks in a row, with modifiers held. See ``TapGesture``.
    public func gesture(_ gesture: TapGesture) -> ModifiedView<Self, TapGestureModifier> {
        ModifiedView(content: self, modifier: TapGestureModifier(gesture: gesture))
    }

    /// Run `action` when the view is clicked `count` times in a row —
    /// SwiftUI's `onTapGesture(count:perform:)`. A single tap takes every
    /// click; `count: 2` the second of a double click. See ``TapGesture``.
    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void)
        -> ModifiedView<Self, TapGestureModifier> {
        gesture(TapGesture(count: count).onEnded(action))
    }
}
