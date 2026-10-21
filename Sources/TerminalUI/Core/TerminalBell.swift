import Synchronization

/// The terminal's bell: rung from any thread, sounded by the frame loop.
///
/// Ringing marks the bell pending and wakes the loop. The next frame writes
/// BEL with its own bytes; BEL draws nothing, so a ring whose frame changed
/// no cell — or that no frame follows — is written on its own. Rings
/// between two frames sound once; a terminal would run them together anyway.
final class TerminalBell: Sendable {
    /// BEL, the C0 control a terminal answers with a beep or a visual flash
    /// (ECMA-48, ECMA-6).
    static let sequence: StaticString = "\u{07}"

    private let pending = Atomic<Bool>(false)
    private let wake: WakeSignal

    init(wake: WakeSignal) {
        self.wake = wake
    }

    func ring() {
        pending.store(true, ordering: .releasing)
        wake.wake()
    }

    var isPending: Bool {
        pending.load(ordering: .acquiring)
    }

    /// Whether the bell was rung since the last take, clearing it.
    func take() -> Bool {
        pending.exchange(false, ordering: .acquiringAndReleasing)
    }
}

/// Rings the terminal's bell. Read it with `@TerminalEnvironment(\.bell)`
/// in `body` and call it from a handler:
///
///     @TerminalEnvironment(\.bell) private var bell
///     // in a key handler:
///     bell()
///
/// A running app writes BEL to its terminal after the frame; outside one it
/// does nothing. Replace it for a subtree to signal some other way — the
/// `.bell` boundary feedback rings whichever action is in effect:
///
///     .environment(\.bell, BellAction { flashStatusLine() })
public struct BellAction: Sendable {
    private let action: @Sendable () -> Void

    /// An action that runs `action` when rung.
    public init(_ action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    /// Rings the bell.
    public func callAsFunction() {
        action()
    }
}
