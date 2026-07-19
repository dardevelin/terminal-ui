import Foundation
import Observation
import TerminalUI

// MARK: - State

@Observable
final class StorybookState {
    var selectedIndex: Int = 0

    // Per-page interactive state — kept on the state so switching pages
    // doesn't reset progress.
    var buttonMessage: String = "(nothing yet)"
    var textInputValue: String = ""
    var toggleValue: Bool = false
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
    var treeSelection: Int? = 0
    var hunkFileName: String = "example.swift"
    // Hover/policy demo state
    var hoverIndicator: String = "(not hovering)"
    // Action graph demo state
    var actionFired: Int = 0
    // Boundary-feedback demo: a small TextInput with .modal + onBoundaryHit
    // captures the most recent boundary reason for visual confirmation.
    var boundaryHitValue: String = ""
    var boundaryHitMessage: String = "(no boundary hit yet)"
    // Modal demo: toggled by the page's own focusable trigger. Presenting
    // confines Tab to the dialog, so the page doubles as the live check
    // that focus containment holds.
    var modalPresented: Bool = false
    // Timeline-page demo: app advances `timelineFrame` via TerminalTimer
    // so the rendered braille-spinner cycles. The page reads
    // `timelineFrame % 8` to pick the displayed glyph; if no timer is
    // running, it shows frame 0 statically.
    var timelineFrame: Int = 0
    // SplitView demo: nested two-level tree. Left pane is one leaf; right
    // pane is itself a vertical split. Holding the SplitState here means
    // mutations (slice 2 mutation API) will survive page switches.
    /// Active mode stack for the .actionContext storybook page. Pushed
    /// by .alt+r (enter resize), popped by Esc (exit). The page reads
    /// `currentMode.current` to render the visible mode indicator and
    /// pushes the value into the env so scoped bindings dispatch.
    var currentMode: ActionContext = ActionContext()
    /// Left-pane fraction (0.0 .. 1.0) for the .actionContext two-pane
    /// resize demo. L grows the left pane, H shrinks it. Maps to
    /// `actionContextSplit.root` ratios so SplitView (which honors
    /// explicit ratios) drives the visible boundary. (HStack's flex
    /// doesn't honor `.frame(width:)` — HYP-340 — so this demo uses
    /// SplitView, the framework's purpose-built resizable container.)
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
            // .scrollPosition(id:) tells the framework to keep the row
            // tagged with `.id(selectedIndex)` visible. Mirrors SwiftUI's
            // `View.scrollPosition(id:)` (iOS 17+) and HIG's selection-row
            // visibility requirement: *"Persistently highlight selected
            // row to clarify navigation path."*
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
            .scrollPosition(id: st.selectedIndex)
            Divider()
            Text(" ↑↓ navigate").foreground(.gray)
            Text(" Tab → preview").foreground(.gray)
            Text(" Esc: quit").foreground(.gray)
                .focusable()
                .onKeyPress { event in
                    switch event.key {
                    case .up:
                        if st.selectedIndex > 0 { st.selectedIndex -= 1 }
                        return .handled
                    case .down:
                        if st.selectedIndex < Storybook.allPages.count - 1 {
                            st.selectedIndex += 1
                        }
                        return .handled
                    default:
                        return .ignored
                    }
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
        // The selected row is `.id(index)`-tagged so the sidebar's
        // `.scrollPosition(id: selectedIndex)` knows which descendant
        // to keep visible. Untagged rows are invisible to the
        // explicit-target scroll path; that's fine — only the moving
        // selection matters.
        //
        // Rows accept clicks so a mouse-driven user can jump straight
        // to a page. The single-focusable architecture (one focusable
        // on the bottom hint row) handles keyboard navigation; the
        // click handler is per-row and sets selectedIndex directly.
        // Arrow handling stays on the sidebar's outer container so
        // each row needs no key handler — no reconciliation confusion.
        return Text("\(prefix)\(label)")
            .foreground(isSelected ? .white : .default)
            .onClick { [state, index] _, _ in
                state.selectedIndex = index
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
        // here (HYP-341: focusable nodes swallow keys), so we
        // unconditionally clear all active modes when the user presses
        // Esc and a mode is on the stack. Acts like a master "exit
        // any sticky mode" affordance until HYP-341 lets the action
        // graph handle Esc properly.
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
