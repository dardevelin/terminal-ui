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
    var button = MouseButton.left
    let count: Int
    let modifiers: KeyModifiers?
    let action: (PointerPress) -> Void

    /// A single tap takes every click of its button, as a button does,
    /// however quickly they come; a double tap takes the second of a pair,
    /// a triple the third. Required modifiers must be exactly the ones
    /// held; with none required, any are.
    func accepts(_ press: PointerPress) -> Bool {
        guard press.button == button else { return false }
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
    var button = MouseButton.left
    var action: (PointerPress) -> Void = { _ in }

    /// A gesture that waits for `count` clicks in a row.
    public init(count: Int = 1) {
        self.count = max(1, count)
    }

    /// The gesture with `action` to run when it happens.
    public func onEnded(_ action: @escaping () -> Void) -> TapGesture {
        var gesture = self
        gesture.action = { _ in action() }
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
        TapRecognizer(button: button, count: count, modifiers: requiredModifiers, action: action)
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

    /// Run `action` with the press when the view is clicked with the
    /// secondary button: what opens a context menu.
    func onSecondaryClick(perform action: @escaping (PointerPress) -> Void)
        -> ModifiedView<Self, TapGestureModifier> {
        var tap = TapGesture()
        tap.button = .right
        tap.action = action
        return gesture(tap)
    }

    /// Run `action` when the view is clicked `count` times in a row —
    /// SwiftUI's `onTapGesture(count:perform:)`. A single tap takes every
    /// click; `count: 2` the second of a double click. See ``TapGesture``.
    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void)
        -> ModifiedView<Self, TapGestureModifier> {
        gesture(TapGesture(count: count).onEnded(action))
    }
}

/// A press followed by motion with the button held, until it is released:
/// SwiftUI's `DragGesture`.
///
/// ```swift
/// Text("▐ handle ▌")
///     .gesture(DragGesture()
///         .onChanged { drag in width = startWidth + drag.translation.width }
///         .onEnded { _ in startWidth = width })
/// ```
///
/// The drag belongs to the deepest view under the press with a drag
/// gesture, and follows the pointer wherever it goes — out of the view
/// too — until the button comes up. A press is still a click as well:
/// a tap gesture on the same view sees it. Locations are in cells,
/// relative to where the view was when the press landed.
public struct DragGesture {
    /// Where a drag has got to.
    public struct Value: Equatable, Sendable {
        /// Where the press landed.
        public let startLocation: Point
        /// Where the pointer is now.
        public let location: Point

        /// How far the pointer has moved since the press.
        public var translation: Size {
            Size(width: location.x - startLocation.x, height: location.y - startLocation.y)
        }
    }

    /// How many cells the pointer must move, along either axis, before the
    /// drag begins; 0 begins it at the press.
    public let minimumDistance: Int
    var changed: (Value) -> Void = { _ in }
    var ended: (Value) -> Void = { _ in }

    /// A drag that begins once the pointer has moved `minimumDistance`
    /// cells from the press.
    public init(minimumDistance: Int = 1) {
        self.minimumDistance = max(0, minimumDistance)
    }

    /// The gesture with `action` to run each time the pointer moves.
    public func onChanged(_ action: @escaping (Value) -> Void) -> DragGesture {
        var gesture = self
        gesture.changed = action
        return gesture
    }

    /// The gesture with `action` to run when the button comes up after the
    /// drag began.
    public func onEnded(_ action: @escaping (Value) -> Void) -> DragGesture {
        var gesture = self
        gesture.ended = action
        return gesture
    }
}

/// Payload of `.gesture(_:)` for a ``DragGesture``.
public struct DragGestureModifier: ViewModifier {
    @_documentation(visibility: internal)
    public typealias ModifierType = Void
    /// The drag the view follows.
    public let gesture: DragGesture
}

extension TerminalView {
    /// Follow a drag that starts on this view. See ``DragGesture``.
    public func gesture(_ gesture: DragGesture) -> ModifiedView<Self, DragGestureModifier> {
        ModifiedView(content: self, modifier: DragGestureModifier(gesture: gesture))
    }
}

/// A drag in progress: begun by a left press, moved by motion with the
/// button held, ended by its release. What it moves is its own — a drag
/// gesture, a scrollbar, a split's divider — through `changed` and `ended`,
/// given the pointer's cell.
struct DragSession {
    let startX: Int
    let startY: Int
    let minimumDistance: Int
    let changed: (_ x: Int, _ y: Int) -> Void
    var ended: (_ x: Int, _ y: Int) -> Void = { _, _ in }
    /// Whether the pointer has gone `minimumDistance` from the press.
    var begun = false

    /// Whether (`x`, `y`) is far enough from the press for the drag to
    /// begin.
    func reaches(x: Int, y: Int) -> Bool {
        max(abs(x - startX), abs(y - startY)) >= minimumDistance
    }
}
