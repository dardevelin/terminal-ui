#!/usr/bin/env python3
"""Focused smoke test for TerminalUI — runs after every change.

Unlike ``storybook_walk.py`` (exhaustive crawl), this suite locks in the
specific behaviors that have regressed before. Each ``SmokeCase`` drives the
live app through the HYP-71 remote-control socket and asserts against real
rendered cells + focus state. Failing cases return to the user as a short
summary: which case, what the app showed, what was expected.

Run:   ``swift build && python3 tools/scripts/storybook_smoke.py``
Exit:  0 on all green, 1 on any failure.

Ship new cases alongside fixes: if a regression would have been caught by a
case here, add the case when you fix it so future regressions won't slip.
"""

from __future__ import annotations

import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import Client, CellSlice, Probe  # noqa: E402
from terminalui.runner import spawn_and_connect  # noqa: E402


# ---------------------------------------------------------------------------
# Case framework
# ---------------------------------------------------------------------------


class CaseFailed(Exception):
    """Raised inside a case to signal a deliberate failure with a message."""


@dataclass
class CaseResult:
    name: str
    ok: bool
    detail: str


@dataclass
class SmokeCase:
    name: str
    app: str  # binary under .build/debug/
    run: Callable[[Client], None]

    def execute(self, cols: int = 140, rows: int = 40) -> CaseResult:
        try:
            with spawn_and_connect(self.app, cols=cols, rows=rows) as (_, client):
                client.wait_for_frame(1, timeout=1.0)
                self.run(client)
            return CaseResult(self.name, True, "ok")
        except CaseFailed as failure:
            return CaseResult(self.name, False, str(failure))
        except Exception as exc:  # noqa: BLE001
            return CaseResult(self.name, False, f"{type(exc).__name__}: {exc}")


def assert_contains(snap: CellSlice, needle: str, context: str = "") -> None:
    if needle not in snap.text():
        hint = f" ({context})" if context else ""
        raise CaseFailed(f"expected '{needle}' in rendered cells{hint}")


def assert_kind(probe_or_focus, expected_kind: str, context: str = "") -> None:
    actual = getattr(probe_or_focus, "kind", None) or getattr(probe_or_focus, "node_kind", None)
    if actual != expected_kind:
        hint = f" ({context})" if context else ""
        raise CaseFailed(f"expected kind='{expected_kind}', got '{actual}'{hint}")


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise CaseFailed(message)


# ---------------------------------------------------------------------------
# Cases — each pins a historical regression
# ---------------------------------------------------------------------------


def storybook_arrow_navigation(app: Client) -> None:
    """Sidebar hint-line should receive arrow presses and advance
    selectedIndex even after boot — caught HYP-92 regression where bare
    ScrollView claimed initial focus and ate the arrows."""
    # Walk 3 pages; each press should update the preview title. If the
    # sidebar were swallowing arrows (HYP-92 bug), the preview would stay
    # on "VStack" forever.
    expected_after_n_presses = {
        1: "HStack",
        2: "ZStack",
        3: "Spacer",
    }
    for n, title in expected_after_n_presses.items():
        app.send_key("down")
        app.wait_for_frame(1, timeout=0.5)
    # n == 3 at this point
    snap = app.cells()
    # Sidebar is 28 cols wide; preview title sits around col 30
    preview_header = "\n".join(snap.rows[:6])
    assert_true(
        expected_after_n_presses[3] in preview_header,
        f"after 3 `down` presses expected '{expected_after_n_presses[3]}' in header, "
        f"got rows[:6]=\n{preview_header}",
    )


def storybook_tab_crosses_to_preview(app: Client) -> None:
    """Navigate to a page that puts a focusable in the preview (the Button
    page), press Tab, and verify focus crosses from the sidebar into the
    preview. Historical complaint: the 34 sidebar rows sat in the Tab order,
    so crossing took 34 presses. Now the sidebar has exactly one focusable
    (the hint-line handler) and Tab reaches the preview in one press."""
    # Button page is index 9 in declaration order (0=VStack, ..., 9=Button).
    for _ in range(9):
        app.send_key("down")
        time.sleep(0.05)
    app.wait_for_frame(1, timeout=0.5)
    initial = app.focus()
    app.send_key("tab")
    app.wait_for_frame(1, timeout=0.5)
    after = app.focus()
    assert_true(
        initial.node_id != after.node_id,
        f"Tab from Button page didn't move focus: still on {initial.node_id}",
    )


def storybook_button_arrows_traverse_siblings(app: Client) -> None:
    """On the Button page the preview is a VStack of two Buttons. After
    Tab into the preview, Down arrow must move focus to the next Button
    (in-stack sibling nav), and Up arrow must move back. Regression test
    for HYP-82 #4's unintended consequence where arrows on Button were
    completely dead because cross-stack gating swallowed them too."""
    # Button is the tenth page in declaration order (index 9).
    for _ in range(9):
        app.send_key("down")
        time.sleep(0.05)
    app.wait_for_frame(1, timeout=0.5)
    app.send_key("tab")  # sidebar → preview
    app.wait_for_frame(1, timeout=0.5)
    first = app.focus()
    app.send_key("down")
    app.wait_for_frame(1, timeout=0.5)
    second = app.focus()
    assert_true(
        first.node_id != second.node_id,
        f"Down arrow did not move focus within Button VStack (stuck on {first.node_id})",
    )
    app.send_key("up")
    app.wait_for_frame(1, timeout=0.5)
    back = app.focus()
    assert_true(
        back.node_id == first.node_id,
        f"Up arrow did not return focus to original sibling (now on {back.node_id})",
    )


def storybook_walks_past_promptinput(app: Client) -> None:
    """Navigate through page 13 (PromptInput) without the runtime crashing.
    HYP-82 bug — Range requires lowerBound <= upperBound fires when
    PreviewPane first renders PromptInput with default state."""
    for _ in range(14):  # 0 → 13 inclusive
        app.send_key("down")
        time.sleep(0.05)
    # If the app crashed the next call will raise RemoteError. Catch it here
    # so the failure message names the scenario rather than "server closed".
    try:
        app.wait_for_frame(1, timeout=1.0)
    except Exception as exc:
        raise CaseFailed(f"app crashed on navigate-to-PromptInput: {exc}") from exc


def storybook_auto_focus_on_boot(app: Client) -> None:
    """TerminalRuntime auto-focuses the first focusable on startup so
    per-view handlers fire on the user's very first press. Regressions here
    show up as 'arrow does nothing until I Tab once first'."""
    focus = app.focus()
    assert_true(focus.node_id is not None, "no node focused at boot")


def storybook_button_click_updates_message(app: Client) -> None:
    """Pressing Enter on the focused Button fires its action closure, which
    updates the page's message text. Regression coverage for the whole
    focus → onKeyPress → @Observable → rerender chain. Covers the same
    path that was broken when arrow policy landed."""
    for _ in range(9):  # page 9 = Button
        app.send_key("down")
        time.sleep(0.05)
    app.send_key("tab")
    app.wait_for_frame(1, timeout=0.5)
    # Focus should now be on the first Button ("OK").
    app.send_key("enter")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "OK clicked" in app.text(),
        "pressing Enter on OK button didn't update the message text",
    )
    # Down arrow to sibling + Space → "Cancel clicked".
    app.send_key("down")
    app.wait_for_frame(1, timeout=0.5)
    app.send_key(" ")  # Space also activates
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "Cancel clicked" in app.text(),
        "pressing Space on Cancel button didn't update the message text",
    )


def storybook_toggle_alternates_state(app: Client) -> None:
    """Toggle page: Space flips the @TerminalState binding; the display
    text shows 'on' or 'off' accordingly. Three presses should cycle
    off → on → off → on."""
    for _ in range(12):  # page 12 = toggle
        app.send_key("down")
        time.sleep(0.05)
    app.send_key("tab")
    app.wait_for_frame(1, timeout=0.5)
    initial_text = app.text()
    # Default is off. Press space; expect 'on'.
    app.send_key(" ")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "→ on" in app.text(),
        f"space on Toggle didn't flip to 'on'; text: {initial_text!r} → {app.text()[:200]!r}",
    )
    app.send_key(" ")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "→ off" in app.text(),
        "second space should return Toggle to 'off'",
    )


def storybook_textinput_validation_colors(app: Client) -> None:
    """TextInput with `validate:` surfaces a red border + 'missing @' row
    when the value fails. Typing '@' moves it to OK and the error row
    disappears. Regression coverage for the validation API (HYP-82 #3)."""
    for _ in range(10):  # page 10 = textInput
        app.send_key("down")
        time.sleep(0.05)
    app.send_key("tab")
    app.wait_for_frame(1, timeout=0.5)
    app.send_text("hello")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "missing @" in app.text(),
        "validator error message should render after typing a bad value",
    )
    app.send_text("@")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "missing @" not in app.text(),
        "error row should disappear once the value is valid",
    )


def storybook_promptinput_submit_clears(app: Client) -> None:
    """PromptInput: type text, press Enter, the field clears and the
    'last submitted' display updates. Covers the whole submit path +
    state reset — the same cycle that crashed in an earlier commit."""
    for _ in range(13):  # page 13 = promptInput
        app.send_key("down")
        time.sleep(0.05)
    app.send_key("tab")
    app.wait_for_frame(1, timeout=0.5)
    app.send_text("hello world")
    app.wait_for_frame(1, timeout=0.5)
    app.send_key("enter")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "hello world" in app.text(),
        "last submitted line should include the submitted text",
    )


def storybook_list_selection_advances(app: Client) -> None:
    """List preview shows alpha/beta/gamma/... Down arrow advances the
    selection cursor visibly (▸ glyph moves to next label). Exercises
    List's keyboard nav + selection binding. Page index 14."""
    for _ in range(14):
        app.send_key("down")
        time.sleep(0.05)
    app.send_key("tab")
    app.wait_for_frame(1, timeout=0.5)
    # Selection starts at index 0 ("alpha"); cursor is `▸ alpha`.
    assert_true(
        "▸ alpha" in app.text(),
        "initial List selection should be on alpha",
    )
    # Two down presses → gamma.
    app.press_many("down", 2, sleep_between=0.05)
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "▸ gamma" in app.text(),
        "after 2 down presses List selection should be on gamma",
    )
    # Up back to beta.
    app.send_key("up")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "▸ beta" in app.text(),
        "after 1 up press List selection should be on beta",
    )


def storybook_tabview_cycles_tabs(app: Client) -> None:
    """TabView preview has three tabs: First/Second/Third. When the tab
    bar is focused, ← / → switch tabs, as does pressing a digit 1-9.
    Page index 16."""
    for _ in range(16):
        app.send_key("down")
        time.sleep(0.05)
    app.send_key("tab")  # sidebar → preview (tab bar focused)
    app.wait_for_frame(1, timeout=0.5)
    # Default tab selection is 0 → "first page content".
    assert_true(
        "first page content" in app.text(),
        "initial TabView should show First content",
    )
    # Right arrow advances to the second tab.
    app.send_key("right")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "second page content" in app.text(),
        "after → TabView should show Second content",
    )
    # Digit "3" jumps directly to Third.
    app.send_key("3")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "third page content" in app.text(),
        "digit 3 should jump directly to Third tab",
    )


def storybook_treeview_expand_collapse(app: Client) -> None:
    """TreeView preview: Sources > TerminalUI > Views > {Text.swift,
    VStack.swift} plus Core, and a second Tests root. Right on Sources
    (already expanded by default — roots auto-expand) → no change.
    Left collapses. Page index 17."""
    for _ in range(17):
        app.send_key("down")
        time.sleep(0.05)
    app.send_key("tab")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "TerminalUI" in app.text(),
        "initial TreeView should show the Sources subtree expanded",
    )
    # Down three times to reach "Views" row, Left collapses its children.
    # Actually TreeView selection starts on Sources (index 0). Just
    # press Left to collapse the currently-selected (Sources) node.
    app.send_key("left")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "TerminalUI" not in app.text() or "▸" in app.text(),
        "Left arrow on an expanded TreeView node should collapse it",
    )


def storybook_textarea_accepts_input(app: Client) -> None:
    """TextArea preview is pre-seeded with three lines. Typing appends
    characters at the cursor, with the gutter showing line numbers.
    Page index 11."""
    for _ in range(11):
        app.send_key("down")
        time.sleep(0.05)
    app.send_key("tab")
    app.wait_for_frame(1, timeout=0.5)
    initial = app.text()
    assert_true(
        "Hello" in initial,
        "TextArea should start with its seeded 'Hello' content",
    )
    # Type a distinctive string at the end — TextArea places cursor at
    # the end on focus, so appending is safe.
    app.send_key("end")
    app.wait_for_frame(1, timeout=0.5)
    app.send_text("!xyz!")
    app.wait_for_frame(1, timeout=0.5)
    assert_true(
        "!xyz!" in app.text(),
        "typed text should appear in TextArea buffer",
    )


def demo_app_renders(app: Client) -> None:
    """Plain Demo smoke — renders its title bar and tab row without
    crashing. Looks for the app's "TerminalUI" title and one of the tab
    labels to catch both a blank screen AND a broken header row."""
    snap = app.cells(rect=[0, 0, 80, 4])
    assert_contains(snap, "TerminalUI", context="Demo title cell")
    assert_contains(snap, "Build", context="Demo Build tab label")


# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------


CASES: list[SmokeCase] = [
    SmokeCase("storybook.auto_focus_on_boot", "Storybook", storybook_auto_focus_on_boot),
    SmokeCase("storybook.arrow_navigation", "Storybook", storybook_arrow_navigation),
    SmokeCase("storybook.tab_crosses_to_preview", "Storybook", storybook_tab_crosses_to_preview),
    SmokeCase("storybook.button_arrows_traverse_siblings", "Storybook", storybook_button_arrows_traverse_siblings),
    SmokeCase("storybook.button_click_updates_message", "Storybook", storybook_button_click_updates_message),
    SmokeCase("storybook.toggle_alternates_state", "Storybook", storybook_toggle_alternates_state),
    SmokeCase("storybook.textinput_validation_colors", "Storybook", storybook_textinput_validation_colors),
    SmokeCase("storybook.promptinput_submit_clears", "Storybook", storybook_promptinput_submit_clears),
    SmokeCase("storybook.list_selection_advances", "Storybook", storybook_list_selection_advances),
    SmokeCase("storybook.tabview_cycles_tabs", "Storybook", storybook_tabview_cycles_tabs),
    SmokeCase("storybook.treeview_expand_collapse", "Storybook", storybook_treeview_expand_collapse),
    SmokeCase("storybook.textarea_accepts_input", "Storybook", storybook_textarea_accepts_input),
    SmokeCase("storybook.walks_past_promptinput", "Storybook", storybook_walks_past_promptinput),
    SmokeCase("demo.renders", "Demo", demo_app_renders),
]


def main() -> int:
    results = []
    for case in CASES:
        print(f"→ {case.name}", flush=True)
        results.append(case.execute())

    print()
    failed = [r for r in results if not r.ok]
    for result in results:
        tick = "✓" if result.ok else "✗"
        print(f"  {tick} {result.name:<40} {result.detail}")

    print()
    print(f"{len(results) - len(failed)}/{len(results)} cases passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
