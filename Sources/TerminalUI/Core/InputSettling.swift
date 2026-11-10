import Observation
import Synchronization

/// Brings the graph up to date between two input events of one batch, when
/// the first may have moved where the second goes.
///
/// A frame's events are handled together, and the graph is updated only
/// when the frame is drawn. A key that closed a presentation left focus
/// inside it until then, so a key typed straight after it — a scripted
/// client's, a fast typist's over SSH — went to the closed presentation and
/// was lost; one typed after a push reached the link that pushed and pushed
/// again. As in SwiftUI, each event should see the views the ones before it
/// left.
///
/// Updating before every key would do that, and cost a burst of typing an
/// update a key: 108 characters into a wrapped prompt, under Thread
/// Sanitizer, never finished. So the update is made only when an earlier
/// event may have presented or dismissed something, which is when a key's
/// destination moves without the focus engine moving it:
///
/// - state `content()` read changed: the root builds its presentations from
///   it, and it is watched as a body is (``build(_:)``);
/// - a body due to run again holds a presentation's host, `.modal` and every
///   presentation built on it — a sheet, an alert, a menu, an inspector, a
///   `NavigationStack`'s pushed screen — whose `isPresented` it may decide.
///
/// Typing changes the state of the field it goes to, whose body holds no
/// presentation, so a burst of it updates nothing. Focus the engine moved
/// itself — Tab, a click — needs no update for the next key to follow it.
/// A focused view that its own body removes is not seen: at a body's grain
/// that is the field being typed into, and where focus would go then is the
/// first focusable, a guess the frame makes as well.
@MainActor
final class InputSettling {
    private let contentChanged = ContentChange()
    /// Whether a watch on what `content()` read is in place and has not
    /// fired.
    private var watchingContent = false

    /// Builds the root view, watching the state `content()` reads, so a
    /// change to it says the root must be built again.
    ///
    /// A watch lasts until what it watches changes, so one is set only when
    /// none is in place: set on every build, the root's watches would pile
    /// up, a frame at a time, on state that did not change.
    func build<Content>(_ content: () -> Content) -> Content {
        guard !watchingContent || contentChanged.fired else { return content() }
        contentChanged.reset()
        watchingContent = true
        let change = contentChanged
        return withObservationTracking(content, onChange: { change.fire() })
    }

    /// Updates `graph` for `focusEngine` when an event since the last frame
    /// or settle may have moved where the next key goes, as the frame
    /// would: from the root when `content()`'s state changed, else a drain
    /// of the bodies due. Returns whether it updated.
    @discardableResult
    func settle<Content: TerminalView>(_ graph: AttributeGraph, for focusEngine: FocusEngine,
                                       content: () -> Content) -> Bool {
        guard let root = graph.root else { return false }
        graph.focusMoved(to: focusEngine.keyboardFocusID)
        let rebuildsRoot = contentChanged.fired
        guard rebuildsRoot || graph.dueBodiesHoldPresentations else { return false }
        focusEngine.clearHandlers()
        if rebuildsRoot {
            graph.update(from: build(content))
        } else {
            graph.drain()
        }
        focusEngine.reindex(graph.root ?? root)
        return true
    }
}

/// Raised, on whatever thread changed it, when state the root's
/// `content()` read has changed since it was last built.
private final class ContentChange: Sendable {
    private let state = Atomic<Bool>(false)
    func fire() { state.store(true, ordering: .releasing) }
    func reset() { state.store(false, ordering: .releasing) }
    var fired: Bool { state.load(ordering: .acquiring) }
}
