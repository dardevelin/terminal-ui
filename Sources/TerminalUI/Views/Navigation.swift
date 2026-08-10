import Foundation
import Observation

/// A container that presents a stack of screens, one level at a time, with a
/// back path out the way the user came.
///
/// ```swift
/// NavigationStack(path: $path) {
///     List { NavigationLink(value: item) { Text(item.name) } }
/// }
/// .navigationDestination(for: Item.self) { item in
///     DetailScreen(item)
/// }
/// ```
///
/// A `NavigationLink` (or a programmatic `path.append`) pushes a value; the
/// stack resolves it to a screen through a matching
/// `.navigationDestination(for:)`. **Esc pops** — the terminal-native
/// counterpart to Enter pushing — and popping restores focus to the link that
/// pushed, so a long list does not lose the user's place.
///
/// In terminal terms a push *replaces* the screen: the pushed content is
/// presented over a blank base with a title row (set via
/// `.navigationTitle(_:)`) above it, so the covered level never bleeds
/// through. Reach for a stack when screens form a drill-down hierarchy;
/// use `.modal` for a transient overlay the user dismisses back to the
/// same screen, and `TabView` for peer screens with no hierarchy.
///
/// Two path modes: the bound initialiser drives display from a caller's
/// `Binding<[D]>` — pushes and Esc write back through it, and mutating the
/// array programmatically navigates. The unbound initialiser lets the
/// stack own its path (a ``NavigationPathStore``) when no outside code
/// needs to steer.
///
/// **Mount policy: the root and the top screen are mounted; intermediate
/// levels are not.** SwiftUI keeps every level mounted, but nesting a modal
/// inside a modal's content centres it on that sub-buffer rather than the
/// screen — the same limitation `.modal` has inside a `ScrollView` — so a stack
/// of live modals does not composite. Since only the top screen is ever
/// visible, the difference is invisible except that an intermediate screen's
/// `@Observable` state is reconstructed when the user drills back into it
/// rather than preserved. Lifting this waits on modal-in-modal compositing.
///
/// A pushed screen confines focus the same way a presented modal does — the
/// covered parent is unreachable while a child is up — reusing the modal
/// containment machinery rather than a parallel one.
public struct NavigationStack<Root: TerminalView>: TerminalView {
    let root: Root
    /// External path, or nil when the stack owns its path via `store`.
    let boundPath: NavigationPathBinding?

    @TerminalState private var internalStore = NavigationPathStore()
    @TerminalEnvironment(\.navigationDestinations) private var destinations

    /// Path-bound: display follows the caller's array and Esc updates it.
    public init<D: Hashable>(path: Binding<[D]>, @TerminalViewBuilder root: () -> Root) {
        self.root = root()
        self.boundPath = NavigationPathBinding(path)
    }

    /// Unbound: the stack owns its path. Links push, Esc pops, no external
    /// binding to thread through.
    public init(@TerminalViewBuilder root: () -> Root) {
        self.root = root()
        self.boundPath = nil
    }

    public var body: some TerminalView {
        let destinations = self.destinations
        let path = boundPath ?? NavigationPathBinding(store: internalStore)
        let pushAction = NavigationPushAction { value in path.append(value) }

        // The top element resolves to the visible screen. An unresolved element
        // renders a warning rather than a blank screen — a consumer bug, not an
        // empty state.
        let topScreen: (any TerminalView)? = path.top.map { top in
            destinations.screen(for: top) ?? Self.unresolved(top)
        }
        let title = topScreen.map { NavigationTitle.firstTitle(in: $0) }
            ?? NavigationTitle.firstTitle(in: root)

        return _NavigationHost(
            root: _TabContentRelay(view: root),
            topScreen: topScreen,
            title: title,
            pop: { path.removeLast() }
        )
        .environment(\.navigationPush, pushAction)
    }

    #if DEBUG
    private static func unresolved(_ value: any Hashable) -> any TerminalView {
        DebugStream.shared.emitWarning(
            .navigationNoDestination,
            message: """
                NavigationStack pushed a value of type \(type(of: value)) with no \
                matching .navigationDestination(for: \(type(of: value)).self). The \
                screen cannot be built. Register a destination for that type.
                """
        )
        return Text("(no destination for \(type(of: value)))").foreground(.gray)
    }
    #else
    private static func unresolved(_ value: any Hashable) -> any TerminalView {
        Text("(no destination)").foreground(.gray)
    }
    #endif
}

/// Erases the element type of a `NavigationStack`'s path, so the stack can
/// drive display and Esc without carrying `D` through its whole body. Bridges
/// either a caller's `Binding<[D]>` or the stack's own `NavigationPathStore`.
struct NavigationPathBinding {
    private let readElements: () -> [any Hashable]
    private let doAppend: (any Hashable) -> Void
    private let doRemoveLast: () -> Void

    init<D: Hashable>(_ binding: Binding<[D]>) {
        readElements = { binding.get() }
        doAppend = { value in
            guard let typed = value as? D else { return }
            binding.set(binding.get() + [typed])
        }
        doRemoveLast = {
            var array = binding.get()
            guard !array.isEmpty else { return }
            array.removeLast()
            binding.set(array)
        }
    }

    init(store: NavigationPathStore) {
        readElements = { store.elements }
        doAppend = { store.append($0) }
        doRemoveLast = { store.removeLast() }
    }

    var top: (any Hashable)? { readElements().last }
    func append(_ value: any Hashable) { doAppend(value) }
    func removeLast() { doRemoveLast() }
}

/// Presents the top screen as a modal over the root.
///
/// The modal reuses `containmentDepth` stamping so the covered root is
/// unreachable by Tab, `isContainingFocus` reports a screen is up, and the
/// modal machinery restores focus to the link that pushed on pop. Its base is a
/// full-screen blank while a screen is up, so the root does not bleed through
/// the presented content — navigation *replaces* the screen rather than
/// floating over it. Esc, handled on the presented content, pops.
struct _NavigationHost: TerminalView {
    let root: _TabContentRelay
    let topScreen: (any TerminalView)?
    let title: String?
    let pop: () -> Void

    /// The screen shown as the modal's presented content, wrapped with its
    /// title row. Only built while a screen is pushed.
    private func presentedScreen(_ screen: any TerminalView) -> some TerminalView {
        VStack {
            if let title, !title.isEmpty {
                Text(title).bold()
                Divider()
            }
            _TabContentRelay(view: screen)
        }
    }

    var body: some TerminalView {
        // The pushed screen is a *presented modal* over the root, which is what
        // reuses `containmentDepth` stamping — so the covered root is
        // unreachable by Tab, `isContainingFocus` is true (protecting Esc from
        // the app's quit default), and the modal machinery restores focus to
        // the link that pushed on pop.
        //
        // The modal *replaces* rather than floats: its base is a full-screen
        // blank while a screen is up, so the root does not bleed through the
        // presented content. Only the title row of the root shows at the base,
        // and the presented screen occludes it.
        let popBox = NavigationPopBox(pop)
        return baseLayer
            .modal(isPresented: topScreen != nil) {
                if let topScreen {
                    presentedScreen(topScreen)
                        .onKeyPress { event in
                            if event.key == .escape { popBox.run(); return .handled }
                            return .ignored
                        }
                }
            }
    }

    /// What sits under a presented screen: the root when nothing is pushed, an
    /// empty full-screen fill when something is — so the root never shows
    /// through the modal.
    @TerminalViewBuilder private var baseLayer: some TerminalView {
        if topScreen == nil {
            VStack {
                if let title, !title.isEmpty {
                    Text(title).bold()
                    Divider()
                }
                root
            }
        } else {
            // A blank base the presented screen fully covers.
            Text("")
        }
    }
}

/// Bridges the non-Sendable pop closure across an `Action`'s `@Sendable`
/// perform boundary, running it back on the main actor where it is safe.
final class NavigationPopBox: @unchecked Sendable {
    private let pop: () -> Void
    init(_ pop: @escaping () -> Void) { self.pop = pop }
    func run() { MainActor.assumeIsolated { pop() } }
}

/// Recovers the `navigationTitle` a screen declares, so the host can show it.
enum NavigationTitle {
    static func firstTitle(in value: Any) -> String? {
        if let titled = value as? any _NavigationTitleSource { return titled.navigationTitle }
        for child in ViewTree.children(of: value) {
            if let title = firstTitle(in: child) { return title }
        }
        return nil
    }
}

protocol _NavigationTitleSource {
    var navigationTitle: String { get }
}

extension NavigationTitleView: _NavigationTitleSource {
    var navigationTitle: String { title }
}

/// Modifier that registers one navigation destination into the environment.
///
/// It **merges** rather than replaces: `apply(to:)` reads the registry an
/// ancestor already published and adds this type's builder, so several
/// `.navigationDestination` calls on the same stack accumulate. A plain
/// `.environment(_:_:)` set would let the outermost win and drop the rest.
public struct NavigationDestinationModifier<Data: Hashable, Destination: TerminalView>: ViewModifier, _AnyEnvironmentModifier {
    public typealias ModifierType = Void
    let build: (Data) -> Destination

    /// Merges this modifier's builder into the inherited destination
    /// registry — accumulating with, not replacing, ancestors' entries.
    public func apply(to env: inout EnvironmentValues) {
        env.navigationDestinations = env.navigationDestinations.adding(Data.self) { value in
            (value as? Data).map(build)
        }
    }
}

extension TerminalView {
    /// Register a screen for values of type `data` pushed onto a
    /// `NavigationStack`. Mirrors SwiftUI: the stack looks the builder up by
    /// the pushed value's type.
    ///
    /// The registration is published into the environment, so it reaches the
    /// stack whether written inside the stack's content or, as is idiom, on the
    /// stack itself. Registrations accumulate, and an inner one shadows an
    /// outer one for the same type.
    public func navigationDestination<D: Hashable, V: TerminalView>(
        for data: D.Type,
        @TerminalViewBuilder destination: @escaping (D) -> V
    ) -> ModifiedView<Self, NavigationDestinationModifier<D, V>> {
        ModifiedView(content: self, modifier: NavigationDestinationModifier(build: destination))
    }

    /// Set the title shown for the current screen. Rendered by
    /// `NavigationStack` in a title row above the content.
    public func navigationTitle(_ title: String) -> some TerminalView {
        NavigationTitleView(content: self, title: title)
    }
}

/// Carries a screen title up to the enclosing `NavigationStack`.
struct NavigationTitleView<Content: TerminalView>: TerminalView {
    let content: Content
    let title: String

    var body: some TerminalView { content }
}

/// The screens a `NavigationStack` can push, keyed by value type.
///
/// A value rather than a class: it rides in `EnvironmentValues`, so each
/// `.navigationDestination` produces a new registry with one more entry and
/// leaves ancestors' copies untouched.
public struct NavigationDestinations: @unchecked Sendable {
    // `@unchecked` for the same reason `EnvironmentValues`'s other closure
    // values are: the builders are only ever read on the main thread during
    // body evaluation, matching the framework's main-thread-by-convention rule.
    private var builders: [ObjectIdentifier: (any Hashable) -> (any TerminalView)?]

    /// Creates an empty registry — no types are pushable until
    /// `.navigationDestination(for:)` adds builders.
    public init() { builders = [:] }

    /// A copy with `type`'s builder added. A later add for a type already
    /// present shadows it — matching SwiftUI's innermost-wins.
    func adding<D: Hashable>(
        _ type: D.Type,
        _ build: @escaping (any Hashable) -> (any TerminalView)?
    ) -> NavigationDestinations {
        var copy = self
        copy.builders[ObjectIdentifier(type)] = build
        return copy
    }

    /// Whether a screen is registered for `type`.
    public func hasDestination<D: Hashable>(for type: D.Type) -> Bool {
        builders[ObjectIdentifier(type)] != nil
    }

    /// The screen for `value`, or nil when its type has no registration.
    public func screen(for value: any Hashable) -> (any TerminalView)? {
        builders[ObjectIdentifier(type(of: value))]?(value)
    }
}

/// The push handler a `NavigationStack` installs for the links beneath it.
///
/// A reference type so it can ride in `EnvironmentValues` (which must be
/// `Sendable`) without making the raw closure sendable, and so a link captured
/// in a handler closure calls back into the live stack rather than a copy.
public final class NavigationPushAction: @unchecked Sendable {
    private let push: (any Hashable) -> Void
    init(_ push: @escaping (any Hashable) -> Void) { self.push = push }
    func callAsFunction(_ value: any Hashable) { push(value) }
}

/// A control that pushes a value onto the enclosing `NavigationStack` when
/// activated.
///
/// ```swift
/// NavigationLink(value: item) { Text(item.name) }
/// ```
///
/// The link renders its label and joins the Tab order via the framework's
/// `.focusable` machinery; Enter, Space, or a click pushes, and the stack
/// resolves the value to a screen through a matching
/// `.navigationDestination(for:)`. When the pushed screen pops (Esc), focus
/// returns to this link. Used with no stack in scope it renders its label
/// and does nothing on activation — a link is a valid leaf view, not an
/// error. Reach for ``Button`` when activation should run an action on the
/// *current* screen rather than navigate.
public struct NavigationLink<Label: TerminalView>: TerminalView {
    let value: any Hashable
    let label: Label

    @TerminalEnvironment(\.navigationPush) private var push
    @TerminalEnvironment(\.isEnabled) private var isEnabled

    /// Creates a link that pushes `value` when activated.
    ///
    /// - Parameters:
    ///   - value: Pushed onto the stack's path on activation; its type
    ///     selects the `.navigationDestination(for:)` that builds the screen.
    ///   - label: The link's visible content.
    public init(value: some Hashable, @TerminalViewBuilder label: () -> Label) {
        self.value = value
        self.label = label()
    }

    public var body: some TerminalView {
        let value = self.value
        let push = self.push
        return label
            .focusable()
            .onKeyPress { event in
                guard isEnabled else { return .ignored }
                if event.key == .enter || event.key == .character(" ") || event.key == .activate {
                    push?(value)
                    return .handled
                }
                return .ignored
            }
    }
}

/// Mutable navigation path for the unbound `NavigationStack` initialiser.
///
/// The bound initialiser drives display from a caller's `Binding<[…]>`
/// instead; this backs the form where the stack owns its own path.
@Observable
public final class NavigationPathStore {
    /// The pushed values, root-first; the last element's screen is shown.
    /// Empty means the stack is at its root content.
    public private(set) var elements: [any Hashable] = []

    /// Creates an empty path — the stack starts at its root content.
    public init() {}

    /// `true` when the stack is at its root (nothing pushed).
    public var isEmpty: Bool { elements.isEmpty }
    /// Number of pushed screens (0 at the root).
    public var count: Int { elements.count }
    /// The element whose screen is currently shown, or nil at the root.
    public var top: (any Hashable)? { elements.last }

    /// Pushes a value; the stack resolves its screen via the matching
    /// `.navigationDestination(for:)` registration.
    public func append(_ value: any Hashable) { elements.append(value) }

    /// Pop one level. A no-op on an empty path — popping past the root is a
    /// normal thing to attempt (Esc at the root), not an error.
    public func removeLast() {
        guard !elements.isEmpty else { return }
        elements.removeLast()
    }

}
