import Foundation
import Observation
import TerminalUI

// MARK: - State

/// Option type for the Picker page. `Identifiable` so `ForEach` can drive the
/// option list the way a real app would.
enum StorybookTheme: String, CaseIterable, Hashable, Identifiable {
    case light, dark, auto
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A node in the NavigationStack demo's drill-down: a section, then one of its
/// items, then that item's detail — three levels the page can descend.
struct NavItem: Hashable, Identifiable {
    let id: Int
    let name: String
    let kind: Kind
    enum Kind: Hashable { case section, item, detail }
}

@Observable
final class StorybookState {
    private(set) var selectedIndex: Int = 0
    /// Where the sidebar is scrolled to, by the id of the row at its top.
    /// Kept apart from the selection because the wheel writes to it: a
    /// reader scrolling the list is not choosing a page.
    var sidebarPosition: Int? = 0

    /// Choose a page, and bring its row into sight.
    func select(_ index: Int) {
        selectedIndex = index
        sidebarPosition = index
    }

    // Per-page interactive state — kept on the state so switching pages
    // doesn't reset progress.
    var buttonMessage: String = "(nothing yet)"
    var textInputValue: String = ""
    var toggleValue: Bool = false
    var loudTheme: Bool = false
    var anchoredLines: Int = 12
    var positionedRow: Int? = 0
    var visibleRows: [Int] = []
    var pickerTheme: StorybookTheme = .dark
    var sliderVolume: Double = 40
    var stepperTabWidth: Int = 4
    var formDark: Bool = true
    var formFontScale: Double = 1.0
    // Rows below the fold of the Form page's preview window — the ones that
    // only a scrolling Form can reach.
    var formTelemetry: Bool = false
    var formCrashReports: Bool = true
    var formAutosave: Bool = true
    var formHistoryDepth: Int = 20
    var navPath: [NavItem] = []
    var listSelection: Int? = 0
    var listScroll: Int = 0
    var tabSelection: Int = 0
    var morseScroll: Int = 0
    // Extra state for previously-stub pages
    var textAreaContent: String = "Hello\nThis is a TextArea.\nTry typing, arrows, and Enter."
    var textAreaState: TextAreaState = TextAreaState()
    var promptValue: String = ""
    var promptState: PromptInputState = PromptInputState()
    var promptSubmitted: String = "(nothing yet)"
    var prefixDraft: String = ""
    var prefixPromptState: PromptInputState = PromptInputState()
    var treeSelection: Int? = 0
    var hunkFileName: String = "example.swift"
    // Hover/policy demo state
    var hoverIndicator: String = "(not hovering)"
    var hoveredScrollRow: String = "none"
    /// Which of a card and the badge drawn over it the pointer is on.
    var hoveredLayer: String = "none"
    /// The `.onTapGesture` page's counts.
    var taps = 0
    var opens = 0
    var marked = false
    /// The `.gesture(DragGesture)` page's bar, and its width when the drag
    /// began.
    var dragWidth = 10
    var dragStartWidth = 10
    // Action graph demo state
    var actionFired: Int = 0
    // Boundary-feedback demo: a small TextInput with .modal + onBoundaryHit
    // captures the most recent boundary reason for visual confirmation.
    var boundaryHitValue: String = ""
    var boundaryHitMessage: String = "(no boundary hit yet)"
    var boundaryBellValue: String = ""
    var keymapLineValue: String = "kill the rest of this line"
    var keymapNotesContent: String = "Undo with Ctrl+Z,\nthen redo with Ctrl+Y."
    var keymapNotesState: TextAreaState = TextAreaState()
    // Modal demo: toggled by the page's own focusable trigger. Presenting
    // confines Tab to the dialog, so the page doubles as the live check
    // that focus containment holds.
    var modalPresented: Bool = false
    var inspectorPresented: Bool = false
    var disclosureExpanded: Bool = true
    // Alert demos. Separate flags so each page's dialog is independent, and
    // a result line per page so the fired action is visible after dismissal
    // — the dialog is gone by then, so the page itself has to report it.
    var alertPresented: Bool = false
    var alertResult: String = "(no choice yet)"
    var confirmPresented: Bool = false
    var confirmResult: String = "(no choice yet)"
    // Timeline-page demo: app advances `timelineFrame` via TerminalTimer
    // so the rendered braille-spinner cycles. The page reads
    // `timelineFrame % 8` to pick the displayed glyph; if no timer is
    // running, it shows frame 0 statically.
    var timelineFrame: Int = 0
    /// Ticked by the `.task` page's own async work, with no timer and no
    /// input — the render loop has to notice the mutation on its own.
    var asyncTicks: Int = 0
    // SplitView demo: nested two-level tree. Left pane is one leaf; right
    // pane is itself a vertical split. Holding the SplitState here means
    // a reassigned `root` survives page switches.
    /// Active mode stack for the .actionContext storybook page. Pushed
    /// by .alt+r (enter resize), popped by Esc (exit). The page reads
    /// `currentMode.current` to render the visible mode indicator and
    /// pushes the value into the env so scoped bindings dispatch.
    var currentMode: ActionContext = ActionContext()
    /// Left-pane fraction (0.0 .. 1.0) for the .actionContext two-pane
    /// resize demo. L grows the left pane, H shrinks it. Maps to
    /// `actionContextSplit.root` ratios so SplitView drives the visible
    /// boundary — the framework's purpose-built resizable container, and the
    /// right one to demonstrate even now that a stack honours an explicit
    /// `.frame` on both axes.
    var actionContextLeftFraction: Double = 0.5

    /// SplitState driving the .actionContext page's resizable two-pane
    /// view. Each leaf is a bordered Text so the visible boundary
    /// move is unambiguous (border edges shift, not just the text
    /// reflow). Updated via `syncActionContextSplit()` whenever the
    /// fraction mutates so SplitView re-renders with new ratios.
    var actionContextSplit: SplitState = SplitState(root: .split(
        axis: .horizontal,
        children: [
            .leaf(Text("left").foreground(.green).border()),
            .leaf(Text("right").foreground(.cyan).border()),
        ],
        ratios: [0.5, 0.5]))

    var splitState: SplitState = SplitState(root: .split(
        axis: .horizontal,
        children: [
            .leaf(Text("left pane").foreground(.cyan)),
            .split(
                axis: .vertical,
                children: [
                    .leaf(Text("top right").foreground(.green)),
                    .leaf(Text("bottom right").foreground(.yellow)),
                ],
                ratios: [0.5, 0.5]),
        ],
        ratios: [0.4, 0.6]))
}

nonisolated(unsafe) let state = StorybookState()

// MARK: - Sidebar

/// Left pane: grouped category list. Up/Down arrows navigate. Enter selects.
struct Sidebar: TerminalView {
    let state: StorybookState

    var body: some TerminalView {
        let st = state
        return VStack {
            Text("TerminalUI Storybook").bold().foreground(.cyan)
            Text("\(Storybook.allPages.count) pages").foreground(.gray)
            Divider()
            // The position is bound both ways: choosing a page sets it, so
            // the selected row comes into sight (HIG: *"Persistently
            // highlight selected row to clarify navigation path."*), and the
            // wheel writes it back, so the reader can scroll the list away
            // from the selection to look at the rest.
            ScrollView(.vertical) {
                VStack {
                    ForEachWithID(Array(PageInfo.Category.allCases), id: \.self) { category in
                        Text(category.rawValue).foreground(.yellow).bold()
                        ForEach(pagesIn(category)) { entry in
                            SidebarRow(
                                label: entry.page.name,
                                index: entry.index,
                                isSelected: entry.index == st.selectedIndex,
                                state: st
                            )
                        }
                        Text(" ")
                    }
                }
            }
            .scrollPosition(id: Binding(get: { st.sidebarPosition },
                                        set: { st.sidebarPosition = $0 }))
            Divider()
            Text(" ↑↓ navigate").foreground(.gray)
            Text(" Tab → preview").foreground(.gray)
            Text(" Esc: quit").foreground(.gray)
        }
        // The sidebar is one of the app's two areas, so the area is what takes
        // focus and the engine cycles between them. This lived on the quit
        // hint above — a stand-in focusable, chosen because a single stable
        // node avoids the reconciliation problem a per-row focusable has, but
        // it put the focus stop on a line that is not the thing being
        // navigated. Same stability, right node.
        .focusable()
        // The ▸ against the selected row is this pane's focus visual, and the
        // pane starts at column 0 — the framework's bar would have to overwrite
        // the first character of every row to appear at all.
        .focusIndicator(.prefix)
        .onKeyPress { event in
            switch event.key {
            case .up:
                if st.selectedIndex > 0 { st.select(st.selectedIndex - 1) }
                return .handled
            case .down:
                if st.selectedIndex < Storybook.allPages.count - 1 {
                    st.select(st.selectedIndex + 1)
                }
                return .handled
            default:
                return .ignored
            }
        }
    }

    private func pagesIn(_ category: PageInfo.Category) -> [IndexedPage] {
        Storybook.allPages.enumerated()
            .compactMap { (index, id) in
                let info = id.info
                return info.category == category
                    ? IndexedPage(id: id.rawValue, index: index, page: info)
                    : nil
            }
    }
}

struct IndexedPage: Identifiable {
    let id: String
    let index: Int
    let page: PageInfo
}

/// Sidebar row — focus + selection are unified. The currently-selected
/// row is the focusable; arrow keys on it commit-immediately: ↓ sets
/// selectedIndex to next, ↑ to previous. Since selection flows through
/// state → re-render, the focusable "moves" to the new row on next frame.
///
/// This makes focus VISIBLE (via the ▸ cursor) without requiring the
/// framework to show a focus indicator inside ScrollView-clipped content.
/// Only ONE focusable exists in the sidebar at a time, so Tab crosses
/// into the preview in one press instead of walking 34 rows.
struct SidebarRow: TerminalView {
    let label: String
    let index: Int
    let isSelected: Bool
    let state: StorybookState

    var body: some TerminalView {
        let prefix = isSelected ? "▸ " : "  "
        // Every row is `.id(index)`-tagged: the sidebar's scroll position
        // names a row, both when a page is chosen and when the wheel
        // reports where the list now starts.
        //
        // Rows accept clicks so a mouse-driven user can jump straight
        // to a page. The single-focusable architecture (one focusable
        // on the bottom hint row) handles keyboard navigation; the
        // click handler is per-row and sets selectedIndex directly.
        // Arrow handling stays on the sidebar's outer container so
        // each row needs no key handler — no reconciliation confusion.
        // A name too long for the sidebar ends in an ellipsis rather than
        // wrapping onto a row of its own.
        return Text("\(prefix)\(label)")
            .foreground(isSelected ? .white : .default)
            .wrap(.truncate(.tail))
            .onClick { [state, index] _, _ in
                state.select(index)
            }
            .id(index)
    }
}

// MARK: - App

struct StorybookApp: TerminalView {
    let state: StorybookState

    var body: some TerminalView {
        let currentID = Storybook.allPages[state.selectedIndex]
        return HStack {
            Sidebar(state: state)
                .frame(width: 28)
            Divider()
            PageDetail(pageID: currentID, state: state)
                .padding()
        }
    }
}

// MARK: - Entry point

@main
struct StorybookMain: TerminalAppProtocol {
    /// 100ms ticker advances `state.timelineFrame` so the Timeline page's
    /// braille spinner cycles. The timer fires whether or not the
    /// Timeline page is visible — the cost is one Int increment per
    /// 100ms which is negligible.
    static var timers: [TerminalTimer] {[
        TerminalTimer("timeline-tick", every: .milliseconds(100))
    ]}

    static func onEvent(_ event: TerminalEvent) -> Bool {
        // Global-only binding: Esc quits — UNLESS a context mode is
        // active, in which case Esc clears the mode and STAYS in the
        // app. We can't safely dispatch the page's scoped Esc binding
        // here (a focusable node takes the key first), so we
        // unconditionally clear all active modes when the user presses
        // Esc and a mode is on the stack. Acts like a master "exit
        // any sticky mode" affordance until the action graph sees Esc
        // ahead of focusable nodes.
        //
        // Arrow keys are handled by the sidebar's hint-line
        // `.onKeyPress` when focused (see Sidebar). Arrow focus
        // navigation is opted in at the root via
        // `.allowArrowFocusNavigation` below so unhandled arrows in
        // the preview still fall through to focus navigation rather
        // than being silently dropped.
        if case .key(let k) = event, k.key == .escape {
            if state.currentMode.current != nil {
                state.currentMode.clear()
                return true
            }
            return false
        }
        if case .timer(let name) = event, name == "timeline-tick" {
            state.timelineFrame &+= 1
        }
        return true
    }

    static func content() -> some TerminalView {
        StorybookApp(state: state)
    }
}
