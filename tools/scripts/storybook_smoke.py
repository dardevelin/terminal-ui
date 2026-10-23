#!/usr/bin/env python3
"""Focused smoke test for TerminalUI — runs after every change.

Unlike ``storybook_walk.py`` (exhaustive crawl), this suite locks in the
specific behaviors that have regressed before. Each ``SmokeCase`` drives the
live app through the remote-control socket and asserts against real
rendered cells + focus state. Failing cases return to the user as a short
summary: which case, what the app showed, what was expected.

Run:   ``swift build && python3 tools/scripts/storybook_smoke.py``
Exit:  0 on all green, 1 on any failure.

Ship new cases alongside fixes: if a regression would have been caught by a
case here, add the case when you fix it so future regressions won't slip.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import Client, CellSlice, Probe  # noqa: E402
from terminalui.runner import BOOT_TIMEOUT, AppExitedBadly, spawn_and_connect  # noqa: E402


# ---------------------------------------------------------------------------
# Case framework
# ---------------------------------------------------------------------------


class CaseFailed(Exception):
    """Raised inside a case to signal a deliberate failure with a message."""


class CaseSkipped(Exception):
    """Raised inside a case that cannot observe what it checks in the build
    under test, with the reason."""


@dataclass
class CaseResult:
    name: str
    ok: bool
    detail: str
    skipped: bool = False


@dataclass
class SmokeCase:
    name: str
    app: str  # binary under .build/debug/
    run: Callable[[Client], None]
    # The runner's exit check, run in reverse: when set, the case passes
    # only if the runner objects to how the app ended, in words containing
    # every one of these phrases.
    expected_objections: tuple[str, ...] = ()
    # Files the app finds in its user's config directory, as (path under it,
    # contents): the case runs with XDG_CONFIG_HOME at a fresh directory
    # holding only these, never the developer's own.
    config_files: tuple[tuple[str, str], ...] = ()
    # Files in the project the app runs from, as (path under it, contents):
    # with any, the case runs from a fresh directory holding only these,
    # such as a `.terminalui/terminalui.toml`; with none, from the checkout.
    project_files: tuple[tuple[str, str], ...] = ()
    # Variables added to the app's environment.
    env: tuple[tuple[str, str], ...] = ()
    # False for an app that should open no socket: the case gets its client
    # unconnected, with the app's terminal, process and data dir.
    connects: bool = True

    def execute(self, build_dir: Optional[str] = None) -> CaseResult:
        with tempfile.TemporaryDirectory(prefix="terminalui-config-") as config_home, \
                tempfile.TemporaryDirectory(prefix="terminalui-project-") as project:
            _write_files(config_home, self.config_files)
            _write_files(project, self.project_files)
            return self._run(config_home, project if self.project_files else None, build_dir)

    def _run(self, config_home: str, cwd: Optional[str], build_dir: Optional[str]) -> CaseResult:
        try:
            with spawn_and_connect(self.app, build_dir=build_dir, cwd=cwd,
                                   env={**dict(self.env), "XDG_CONFIG_HOME": config_home},
                                   connect=self.connects) as (_, client):
                self.run(client)
            if self.expected_objections:
                return CaseResult(self.name, False, "the runner accepted how the app ended")
            return CaseResult(self.name, True, "ok")
        except AppExitedBadly as objection:
            if self.expected_objections and all(
                    phrase in str(objection) for phrase in self.expected_objections):
                return CaseResult(self.name, True, "ok")
            return CaseResult(self.name, False, f"AppExitedBadly: {objection}")
        except CaseFailed as failure:
            return CaseResult(self.name, False, str(failure))
        except CaseSkipped as reason:
            return CaseResult(self.name, True, f"skipped: {reason}", skipped=True)
        except Exception as exc:  # noqa: BLE001
            return CaseResult(self.name, False, f"{type(exc).__name__}: {exc}")


def _write_files(root: str, files: tuple[tuple[str, str], ...]) -> None:
    for relative, contents in files:
        path = Path(root) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)


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
    selectedIndex even after boot — caught a regression where bare
    ScrollView claimed initial focus and ate the arrows."""
    # Walk 3 pages; each press should update the preview title. If the
    # sidebar were swallowing arrows, the preview would stay
    # on "VStack" forever.
    expected_after_n_presses = {
        1: "HStack",
        2: "ZStack",
        3: "Spacer",
    }
    for n, title in expected_after_n_presses.items():
        app.send_key("down")
    # n == 3 at this point
    snap = app.cells()
    # Sidebar is 28 cols wide; preview title sits around col 30
    preview_header = "\n".join(snap.rows[:6])
    assert_true(
        expected_after_n_presses[3] in preview_header,
        f"after 3 `down` presses expected '{expected_after_n_presses[3]}' in header, "
        f"got rows[:6]=\n{preview_header}",
    )


def storybook_a_client_that_hangs_up_leaves_the_app_running(app: Client) -> None:
    """A control client that sends a request and disconnects before the reply
    leaves the app running, and its terminal intact. Regression: the reply
    went to the closed socket, SIGPIPE ended the app inside the write, and
    nothing restored the terminal — `swtui ctl kill` hangs up this way, so
    every kill left the shell in raw mode with mouse tracking on."""
    import socket as socketlib

    for _ in range(3):
        hang_up = socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM)
        hang_up.connect(app.socket_path)
        hang_up.sendall(b'{"id": 1, "cmd": "query_tree"}\n')
        hang_up.close()
        # The server answers both connections in one pump, the closed one
        # first; this ping is answered only if that reply did not end it.
        app.ping()
    assert_contains(app.cells(), "Storybook", "the app should still be drawing")


def storybook_sidebar_order_matches_navigation(app: Client) -> None:
    """Walking Down through every page must visit each visible
    sidebar row in the same order the sidebar displays them.
    Regression test for the Primitives cursor-jump bug
    (2026-05-05): the enum declaration order silently diverged from
    sidebar visual order, causing arrow nav to skip three pages.
    Index-based smoke tests didn't catch it by construction (they
    encoded the broken navigation).

    Strategy: walk Down through the full page list, collecting the
    title at each step. Assert:
      1. No title repeats (sequence has unique entries).
      2. The first N titles (where N = number of rows visible in the
         initial sidebar snapshot) match the rendered sidebar exactly.

    The visible-prefix check (#2) is the load-bearing assertion: it
    catches "cursor jumped past visible rows" — which is exactly the
    bug class. Pages scrolled below the fold aren't checked here
    (the visible window scrolls with cursor) but the unique-order
    assertion catches duplicates from any section."""
    initial_sidebar = app.storybook_sidebar_rows()
    assert_true(
        len(initial_sidebar) >= 5,
        f"sidebar should expose at least 5 visible pages; got {initial_sidebar!r}",
    )

    # Enumeration lives on the client so this case and storybook_walk.py
    # share one definition of the catalog. It already rejects a repeated
    # title, which is the "cursor revisits a page mid-walk" check this case
    # used to perform inline.
    titles = app.storybook_pages()

    # Visible-prefix matches rendered sidebar. The walk's
    # first len(initial_sidebar) titles must equal the sidebar rows
    # exactly. Mismatch = cursor skipped a visible row (the regression
    # class).
    visible_prefix = titles[: len(initial_sidebar)]
    assert_true(
        visible_prefix == initial_sidebar,
        f"navigation order doesn't match sidebar display order:\n"
        f"  sidebar  : {initial_sidebar!r}\n"
        f"  navigated: {visible_prefix!r}",
    )


def storybook_tab_crosses_to_preview(app: Client) -> None:
    """Navigate to a page that puts a focusable in the preview (the Button
    page), press Tab, and verify focus crosses from the sidebar into the
    preview. Historical complaint: the 34 sidebar rows sat in the Tab order,
    so crossing took 34 presses. Now the sidebar has exactly one focusable
    (the hint-line handler) and Tab reaches the preview in one press."""
    # Button page is index 9 in declaration order (0=VStack, ..., 9=Button).
    app.goto_page("Button")
    initial = app.focus()
    app.send_key("tab")
    after = app.focus()
    assert_true(
        initial.node_id != after.node_id,
        f"Tab from Button page didn't move focus: still on {initial.node_id}",
    )


def storybook_focusable_rows_read_their_focus(app: Client) -> None:
    """The `.focusable` page's rows read `isFocused`: the focused row draws a
    `▸`, and Tab moves it. Regression: `isFocused` was never set, so no view
    could tell it held focus."""
    app.goto_page(".focusable")
    app.send_key("tab")
    preview = app.preview_text()
    assert_true("▸ press Tab to focus me" in preview,
                f"the first row should show it holds focus: {preview!r}")
    assert_true("▸ then me" not in preview, "only the focused row is marked")
    app.send_key("tab")
    preview = app.preview_text()
    assert_true("▸ then me" in preview and "▸ press Tab" not in preview,
                f"Tab should move the mark to the second row: {preview!r}")


def storybook_theme_switch_reaches_unchanged_views(app: Client) -> None:
    """The `.environment(\\.theme)` page's swatch takes no inputs and draws
    with the theme, so only the theme can change it. Regression: the update
    walk skipped a view whose inputs compared equal and everything under it,
    so a theme switched above it never reached it."""
    app.goto_page(".environment(\\.theme)")
    preview = app.preview_text()
    assert_true("accent is cyan" in preview, f"the default theme's accent: {preview!r}")
    app.send_key("tab")
    app.send_key(" ")
    assert_true("accent is magenta" in app.preview_text(),
                f"switching to the loud theme should reach the swatch: {app.preview_text()!r}")
    app.send_key(" ")
    assert_true("accent is cyan" in app.preview_text(),
                f"switching back should too: {app.preview_text()!r}")


def storybook_anchored_scroll_follows_its_tail(app: Client) -> None:
    """The `.defaultScrollAnchor` page's log opens on its last line and keeps
    the newest in view as lines are appended."""
    app.goto_page(".defaultScrollAnchor")
    preview = app.preview_text()
    assert_true("line 12" in preview and "line 1 " not in preview,
                f"the log should open on its tail: {preview!r}")
    app.send_key("tab")
    app.send_key("enter")
    assert_true("line 13" in app.preview_text(),
                f"an appended line should come into view: {app.preview_text()!r}")


def storybook_sidebar_scrolls_away_from_the_selection(app: Client) -> None:
    """The wheel scrolls the sidebar past the selected row, and the list
    stays where the reader put it. Regression: the sidebar's scroll position
    was re-applied every frame, so the selected row was pinned in sight and
    the list snapped back to it."""
    first = app.storybook_sidebar_rows()
    assert_true(len(first) > 0, "the sidebar should list pages")
    for _ in range(12):
        app.mouse_wheel("down", 4, 10)
    scrolled = app.storybook_sidebar_rows()
    assert_true(first[0] not in scrolled,
                f"the wheel should scroll the selected page out of sight: {scrolled!r}")
    assert_true(app.storybook_sidebar_rows() == scrolled,
                "the list should stay where the reader scrolled it")
    app.send_key("down")
    assert_true(app.storybook_sidebar_rows()[:1] != scrolled[:1]
                and "▸" in app.cells(rect=app._STORYBOOK_SIDEBAR_RECT).text(),
                "choosing a page brings its row back into sight")


def storybook_scroll_position_binds_both_ways(app: Client) -> None:
    """The `.scrollPosition` page: a button sets the position and the row
    scrolls to the top; the wheel scrolls and the readout follows it."""
    app.goto_page(".scrollPosition")
    app.send_key("tab")
    app.send_key("enter")
    preview = app.preview_text()
    assert_true("row 25" in preview and "position: 25" in preview,
                f"the button should bring row 25 into sight: {app.preview_text()!r}")
    # The code listing above names row 25 too; the row itself sits right
    # after the preview's frame.
    cells = app.preview_cells()
    y = next(i for i, row in enumerate(cells.rows) if row.lstrip().startswith("│ row 25"))
    x = cells.rows[y].index("row 25")
    app.mouse_wheel("up", cells.x + x, cells.y + y)

    top = next((row.split("│ row ")[1].split()[0] for row in app.preview_cells().rows
                if row.lstrip().startswith("│ row ")), None)
    assert_true(top is not None and top != "25" and f"position: {top}" in app.preview_text(),
                f"scrolling should report the row now at the top: {app.preview_text()!r}")


def storybook_scroll_target_visibility_follows_the_scroll(app: Client) -> None:
    """The `.onScrollTargetVisibilityChange` page: the rows the reader can
    see are reported at rest, and again as the view scrolls. Reported once
    a frame is drawn, so the new set lands a frame after the keys."""
    app.goto_page(".onScrollTargetVisibilityChange")
    assert_true("seen: 0, 1, 2, 3, 4" in app.preview_text(),
                f"the rows in sight should be reported at rest: {app.preview_text()!r}")
    app.tab()
    app.press_many("down", 4)
    assert_true(app.wait_until(lambda c: "seen: 4, 5, 6, 7, 8" in c.preview_text()),
                f"scrolling should report the rows now in sight: {app.preview_text()!r}")


def storybook_button_arrows_traverse_siblings(app: Client) -> None:
    """On the Button page the preview is a VStack of two Buttons. After
    Tab into the preview, Down arrow must move focus to the next Button
    (in-stack sibling nav), and Up arrow must move back. Regression test
    for the cross-stack gating bug where arrows on Button were completely
    dead because the gate swallowed in-stack arrows too."""
    # Button is the tenth page in declaration order (index 9).
    app.goto_page("Button")
    app.send_key("tab")  # sidebar → preview
    first = app.focus()
    app.send_key("down")
    second = app.focus()
    assert_true(
        first.node_id != second.node_id,
        f"Down arrow did not move focus within Button VStack (stuck on {first.node_id})",
    )
    app.send_key("up")
    back = app.focus()
    assert_true(
        back.node_id == first.node_id,
        f"Up arrow did not return focus to original sibling (now on {back.node_id})",
    )


def storybook_walks_past_promptinput(app: Client) -> None:
    """Navigate through page 13 (PromptInput) without the runtime crashing.
    Regression: Range requires lowerBound <= upperBound used to fire when
    PreviewPane first rendered PromptInput with default state."""
    app.goto_page("PromptInput")
    # If the app crashed the next call will raise RemoteError. Catch it here
    # so the failure message names the scenario rather than "server closed".
    try:
        app.ping()
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
    app.goto_page("Button")
    app.send_key("tab")
    # Focus should now be on the first Button ("OK").
    app.send_key("enter")
    assert_true(
        "OK clicked" in app.text(),
        "pressing Enter on OK button didn't update the message text",
    )
    # Down arrow to sibling + Space → "Cancel clicked".
    app.send_key("down")
    app.send_key(" ")  # Space also activates
    assert_true(
        "Cancel clicked" in app.text(),
        "pressing Space on Cancel button didn't update the message text",
    )


def storybook_toggle_alternates_state(app: Client) -> None:
    """Toggle page: Space flips the @TerminalState binding; the display
    text shows 'on' or 'off' accordingly. Three presses should cycle
    off → on → off → on."""
    app.goto_page("Toggle")
    app.send_key("tab")
    initial_text = app.text()
    # Default is off. Press space; expect 'on'.
    app.send_key(" ")
    assert_true(
        "→ on" in app.text(),
        f"space on Toggle didn't flip to 'on'; text: {initial_text!r} → {app.text()[:200]!r}",
    )
    app.send_key(" ")
    assert_true(
        "→ off" in app.text(),
        "second space should return Toggle to 'off'",
    )


def storybook_textinput_validation_colors(app: Client) -> None:
    """TextInput with `validate:` surfaces a red border + 'missing @' row
    when the value fails. Typing '@' moves it to OK and the error row
    disappears. Regression coverage for the validation API.

    Scoped to the Preview pane via ``preview_text()`` because the Code
    pane shows the validator source containing the literal "missing @"
    — using ``app.text()`` would always match the snippet."""
    app.goto_page("TextInput")
    app.send_key("tab")
    app.send_text("hello")
    assert_true(
        "missing @" in app.preview_text(),
        "validator error message should render after typing a bad value",
    )
    app.send_text("@")
    assert_true(
        "missing @" not in app.preview_text(),
        "error row should disappear once the value is valid",
    )


def storybook_promptinput_long_input_soft_wraps(app: Client) -> None:
    """Typing past the container width must soft-wrap downward — Claude
    Code / Codex style. Supersedes the 2026-04-18 horizontal-scroll test
    after the soft-wrap rewrite: the long input produces at least
    two visible content rows in the preview (the Storybook preview pane
    is too short to fit all four wrapped rows, so the exact tail may be
    scrolled out; wrapping is the invariant we actually care about)."""
    app.goto_page("PromptInput")
    app.send_key("tab")
    app.send_text("abcdefghijklmnopqrstuvwxyz0123456789" * 3)
    preview = app.preview_text()
    content_rows = [
        row for row in preview.splitlines()
        if "abcdef" in row or "vwxyz" in row or "6789" in row or "mnopqr" in row
    ]
    assert_true(
        len(content_rows) >= 2,
        f"PromptInput didn't soft-wrap — expected ≥2 content rows, got {len(content_rows)}:\n{preview}",
    )


def storybook_promptinput_submit_clears(app: Client) -> None:
    """PromptInput: type text, press Enter, the field clears and the
    'last submitted' display updates. Covers the whole submit path +
    state reset — the same cycle that crashed in an earlier commit."""
    app.goto_page("PromptInput")
    app.send_key("tab")
    app.send_text("hello world")
    app.send_key("enter")
    assert_true(
        "hello world" in app.text(),
        "last submitted line should include the submitted text",
    )


def storybook_prompt_prefix_follows_focus(app: Client) -> None:
    """The `.promptPrefix` page's composer is Crush's: three rows when empty,
    `:::` on each while focus is elsewhere, `>` on the first once Tab brings
    focus in, and typed text after it. Regression: the prompt could not tell
    it held focus, and drew a cursor regardless."""
    app.goto_page(".promptPrefix")
    preview = app.preview_text()
    cells = [row.split("│", 1)[1].strip() for row in preview.splitlines() if "│" in row]
    rows = [row for row in cells if row.startswith((":::", ">"))]
    assert_true(len(rows) == 3 and all(row.startswith(":::") for row in rows),
                f"an unfocused composer should be three ::: rows: {preview!r}")
    assert_true("Ask anything, or / for commands" in preview, "the placeholder shows while empty")
    app.send_key("tab")
    app.send_text("quit queue")
    preview = app.preview_text()
    assert_true("> quit queue" in preview, f"focused, the first row reads '> ' then the text: {preview!r}")


def storybook_list_selection_advances(app: Client) -> None:
    """List preview shows alpha/beta/gamma/... Down arrow advances the
    selection cursor visibly (▸ glyph moves to next label). Exercises
    List's keyboard nav + selection binding. Page index 14."""
    app.goto_page("List")
    app.send_key("tab")
    # Selection starts at index 0 ("alpha"); cursor is `▸ alpha`.
    assert_true(
        "▸ alpha" in app.text(),
        "initial List selection should be on alpha",
    )
    # Two down presses → gamma.
    app.press_many("down", 2)
    assert_true(
        "▸ gamma" in app.text(),
        "after 2 down presses List selection should be on gamma",
    )
    # Up back to beta.
    app.send_key("up")
    assert_true(
        "▸ beta" in app.text(),
        "after 1 up press List selection should be on beta",
    )


def storybook_tabview_cycles_tabs(app: Client) -> None:
    """TabView preview has three tabs: First/Second/Third. When the tab
    bar is focused, ← / → switch tabs, as does pressing a digit 1-9.
    Page index 16."""
    app.goto_page("TabView")
    app.send_key("tab")  # sidebar → preview (tab bar focused)
    # Default tab selection is 0 → "first page content".
    assert_true(
        "first page content" in app.text(),
        "initial TabView should show First content",
    )
    # Right arrow advances to the second tab.
    app.send_key("right")
    assert_true(
        "second page content" in app.text(),
        "after → TabView should show Second content",
    )
    # Digit "3" jumps directly to Third.
    app.send_key("3")
    assert_true(
        "third page content" in app.text(),
        "digit 3 should jump directly to Third tab",
    )


def storybook_treeview_expand_collapse(app: Client) -> None:
    """TreeView preview: Sources > TerminalUI > Views > {Text.swift,
    VStack.swift} plus Core, and a second Tests root. Right on Sources
    (already expanded by default — roots auto-expand) → no change.
    Left collapses. Page index 17."""
    app.goto_page("TreeView")
    app.send_key("tab")
    assert_true(
        "TerminalUI" in app.text(),
        "initial TreeView should show the Sources subtree expanded",
    )
    # Down three times to reach "Views" row, Left collapses its children.
    # Actually TreeView selection starts on Sources (index 0). Just
    # press Left to collapse the currently-selected (Sources) node.
    app.send_key("left")
    assert_true(
        "TerminalUI" not in app.text() or "▸" in app.text(),
        "Left arrow on an expanded TreeView node should collapse it",
    )


def storybook_sidebar_autoscrolls_with_selection(app: Client) -> None:
    """Pressing Down past the visible sidebar window must keep the ▸
    cursor visible — the ScrollView should auto-scroll to follow the
    selection. Prior to the fix, ▸ moved off-screen because
    only the bottom hint row was focusable, so adjustScrollForFocus
    never had a moving target."""
    # Press Down 35 times — past the ~33-row visible window.
    app.press_many("down", 35)
    # Scrape sidebar column (left ~30 cells) and confirm ▸ is visible.
    rendered = app.text()
    sidebar_cols = [line[:30] for line in rendered.splitlines()]
    has_cursor = any("▸" in row for row in sidebar_cols)
    assert_true(
        has_cursor,
        "After 35 down-arrows, ▸ cursor must still be visible in the sidebar viewport "
        f"(sidebar should auto-scroll to follow selection). Got:\n"
        + "\n".join(f"  {r!r}" for r in sidebar_cols if r.strip()),
    )


def storybook_textarea_accepts_input(app: Client) -> None:
    """TextArea preview is pre-seeded with three lines. Typing appends
    characters at the cursor, with the gutter showing line numbers.
    Page index 11."""
    app.goto_page("TextArea")
    app.send_key("tab")
    initial = app.text()
    assert_true(
        "Hello" in initial,
        "TextArea should start with its seeded 'Hello' content",
    )
    # Type a distinctive string at the end — TextArea places cursor at
    # the end on focus, so appending is safe.
    app.send_key("end")
    app.send_text("!xyz!")
    assert_true(
        "!xyz!" in app.text(),
        "typed text should appear in TextArea buffer",
    )


def storybook_textinput_cursor_follows_focus(app: Client) -> None:
    """The TextInput page's field draws its caret only once Tab gives it
    focus. Regression: the caret was drawn whether or not keys reached the
    field."""
    app.goto_page("TextInput")
    preview = app.preview_text()
    assert_true("type an email" in preview and "│type an email" not in preview,
                f"no caret before the field holds focus: {preview!r}")
    app.send_key("tab")
    assert_true("│type an email" in app.preview_text(),
                f"the caret should appear with focus: {app.preview_text()!r}")


def storybook_textinput_paste_inserts(app: Client) -> None:
    """Bracketed-paste payload reaches a focused TextInput and inserts
    at the cursor. Single-line component → embedded \\n must NOT
    produce visible new rows in the preview pane."""
    app.goto_page("TextInput")
    app.send_key("tab")
    app.paste("PASTED-TEXT")
    assert_true(
        "PASTED-TEXT" in app.preview_text(),
        f"TextInput should show pasted payload; got:\n{app.preview_text()}",
    )


def storybook_textarea_paste_splits_lines(app: Client) -> None:
    """Pasting `alpha\\nbeta\\ngamma` into TextArea must produce three
    distinct logical rows. Visible in the preview pane after gutter."""
    app.goto_page("TextArea")
    app.send_key("tab")
    app.send_key("end")
    # Newline before the multi-line paste so pasted rows don't merge
    # with the seeded "Hello" line.
    app.send_key("enter")
    app.paste("alphaPaste\nbetaPaste\ngammaPaste")
    rendered = app.text()
    for token in ("alphaPaste", "betaPaste", "gammaPaste"):
        assert_true(
            token in rendered,
            f"TextArea preview should show '{token}' after paste; got:\n{rendered}",
        )


def storybook_large_paste_does_not_corrupt_ui(app: Client) -> None:
    """A large multi-line paste must arrive intact AND collapse to a
    marker. Verifies that:
      1. App chrome still renders post-paste (the parser tolerates read
         timeouts mid-paste).
      2. PromptInput's default `.pasteMode(.claudeCode)` collapses
         the paste into a `[Pasted text #N +M lines]` marker so the
         viewport doesn't flood with raw paste content."""
    app.goto_page("PromptInput")
    app.send_key("tab")
    # 100-line blob ≈ 3KB. Realistic for clipboard contents.
    blob = "\n".join(f"line{i:03d} alpha beta gamma delta epsilon" for i in range(100))
    app.paste(blob)
    rendered = app.text()
    assert_true(
        "TerminalUI Storybook" in rendered,
        f"app chrome should still render after large paste; got:\n{rendered[:600]}",
    )
    # Marker should be visible — Claude Code parity. Match either
    # `+100 lines` literal OR the `[Pasted text #` prefix in case the
    # exact line count rendering shifts (we still want the marker).
    assert_true(
        "[Pasted text #" in rendered,
        f"PromptInput should collapse the multi-line paste into a marker; got:\n{rendered[:800]}",
    )
    # And: raw payload should NOT be visible — markers replace it.
    assert_true(
        "line050" not in rendered,
        "raw payload content should be hidden under marker; marker default is .placeholder",
    )


def storybook_promptinput_paste_creates_logical_rows(app: Client) -> None:
    """PromptInput collapses a multi-line paste to a marker by default
    (Claude Code parity). The underlying expanded text remains in the
    binding and gets sent on submit; only the rendered presentation
    is collapsed."""
    app.goto_page("PromptInput")
    app.send_key("tab")
    app.paste("zenAlpha\nzenBeta\nzenGamma")
    rendered = app.text()
    assert_true(
        "[Pasted text #" in rendered,
        f"multi-line paste should collapse to a marker; got:\n{rendered}",
    )


# ---------------------------------------------------------------------------
# Static-render coverage (Tier 1 sweep)
#
# These cases don't interact with focus — they just navigate to a page and
# assert that its preview pane shows the expected glyphs. They're cheap and
# catch regressions in the layout / rendering pipeline that don't show up
# in per-widget interaction tests: compositor cell drift, VStack spacing,
# HStack sibling alignment, border glyph selection, etc.
#
# Use ``app.preview_text()`` / ``app.contains()`` / ``app.count_glyph()``
# so the case body stays under 10 lines.
# ---------------------------------------------------------------------------


def storybook_vstack_renders_three_rows(app: Client) -> None:
    """VStack preview stacks row 1/2/3 vertically in the preview pane."""
    app.goto_page("VStack")
    preview = app.preview_text()
    for label in ("row 1", "row 2", "row 3"):
        assert_true(label in preview, f"VStack preview missing '{label}'")


def storybook_hstack_renders_horizontal(app: Client) -> None:
    """HStack preview puts A | B | C on a single row, separators between."""
    app.goto_page("HStack")
    preview = app.preview_text()
    assert_true("A" in preview and "B" in preview, "HStack missing A/B labels")
    # A, |, B appear on the same row (no newlines between them).
    for row in preview.split("\n"):
        if "A" in row and "B" in row:
            return
    raise CaseFailed("HStack A/B not on same row — vertical regression?")


def storybook_divider_renders_rule(app: Client) -> None:
    """Divider preview draws a horizontal rule via `─` glyphs between the
    'above' and 'below' text. Catches primitive divider render bugs."""
    app.goto_page("Divider")
    assert_true(app.contains("above"), "Divider preview missing 'above'")
    assert_true(app.contains("below"), "Divider preview missing 'below'")
    assert_true(
        app.count_glyph("─") >= 4,
        "Divider rule not rendered (no '─' chars)",
    )


def storybook_table_renders_header_and_rows(app: Client) -> None:
    """Table preview shows Name/Color header columns + data rows for the
    demo items. No interaction — Table has no keyboard selection yet."""
    app.goto_page("Table")
    preview = app.preview_text()
    assert_true("Name" in preview, "Table header 'Name' missing")
    assert_true("alpha" in preview, "Table row 'alpha' missing")
    assert_true("beta" in preview, "Table row 'beta' missing")


def storybook_diffview_marks_changes(app: Client) -> None:
    """DiffView preview shows hello + swift world, with diff markers on
    the changed line. Regression net for stale-cell bugs in scrolling diffs."""
    app.goto_page("DiffView")
    preview = app.preview_text()
    assert_true("hello" in preview, "DiffView context 'hello' missing")
    assert_true("swift world" in preview, "DiffView modified line missing")


def storybook_hunkdiffview_navigates_lines(app: Client) -> None:
    """HunkDiffView preview: Tab into the hunk, Down moves selection; file
    header + hunk content remain visible. Keyboard-interactive path that's
    otherwise untested in smoke."""
    app.goto_page("HunkDiffView")
    app.send_key("tab")
    preview = app.preview_text()
    assert_true("example.swift" in preview, "HunkDiffView header missing")
    # Down shouldn't crash and should keep the hunk content visible.
    app.send_key("down")
    assert_true(
        "let x" in app.preview_text(),
        "HunkDiffView content disappeared after down",
    )


def storybook_progressbar_renders_all_values(app: Client) -> None:
    """ProgressBar page shows four bars at different fill levels. Count of
    filled glyphs on successive rows should grow monotonically."""
    app.goto_page("ProgressBar")
    preview = app.preview_text()
    for marker in ("25%", "50%", "75%"):
        assert_true(marker in preview, f"ProgressBar preview missing '{marker}'")


def storybook_statusbar_sections_render(app: Client) -> None:
    """StatusBar lays out left/center/right sections. READY + tab:1/3 + a
    timing indicator should all appear on a single row."""
    app.goto_page("StatusBar")
    preview = app.preview_text()
    # Don't assume the exact text — just that the three conceptual sections
    # landed something visible in the preview.
    assert_true(len(preview.strip()) > 0, "StatusBar preview was empty")


def storybook_barchart_renders_bars(app: Client) -> None:
    """BarChart preview renders `█` glyphs proportional to value — verify
    at least one filled bar appears and the label characters are present."""
    app.goto_page("BarChart")
    full_block_count = app.count_glyph("█")
    assert_true(full_block_count >= 5, f"BarChart filled-cells too sparse: {full_block_count}")


def storybook_zstack_overlays_label(app: Client) -> None:
    """ZStack preview: `OVER` label rendered on top of a ◼ block background.
    Both should be present in the same snapshot — the label overwrites the
    fill cells underneath, not the whole frame."""
    app.goto_page("ZStack")
    preview = app.preview_text()
    assert_true("OVER" in preview, "ZStack top-layer label missing")
    assert_true("◼" in preview, "ZStack background fill glyphs missing")


def storybook_spacer_pushes_edges(app: Client) -> None:
    """HStack{Text, Spacer, Text} — [left] + [right] appear on the same
    row, separated by ≥5 blank cells. Catches Spacer flex regressions."""
    app.goto_page("Spacer")
    for row in app.preview_text().split("\n"):
        l = row.find("[left]")
        r = row.find("[right]")
        if l >= 0 and r >= 0:
            assert_true(
                r - (l + len("[left]")) >= 5,
                f"Spacer didn't push edges apart (gap={r - l - len('[left]')})",
            )
            return
    raise CaseFailed("Spacer preview: [left] and [right] not on same row")


def storybook_scrollview_initial_viewport(app: Client) -> None:
    """ScrollView preview shows early rows; later rows are clipped off the
    initial viewport. Regression net for scroll-offset + frame(height:6)."""
    app.goto_page("ScrollView")
    preview = app.preview_text()
    assert_true("row 0" in preview, "ScrollView viewport missing 'row 0'")
    assert_true("row 19" not in preview, "ScrollView viewport shouldn't show 'row 19' initially")


def storybook_textinput_boundary_emits_under_modal(app: Client) -> None:
    """`.boundaryFeedback` page: TextInput with `.modal` mode +
    `.onBoundaryHit { ... }`. Pressing Right with cursor at end of
    an empty value must dispatch `.rightEdge` to the callback,
    visible as 'boundary: rightEdge' in the preview pane."""
    app.goto_page(".boundaryFeedback")
    app.send_key("tab")
    # Empty value: cursor at 0, both Left and Right are walls. Press
    # Right — under .modal the onBoundaryHit callback fires and
    # writes "boundary: rightEdge" into state.boundaryHitMessage.
    app.send_key("right")
    preview = app.preview_text()
    assert_true(
        "boundary: rightEdge" in preview,
        f"Right at empty TextInput should fire .rightEdge via .modal callback; preview: {preview[:300]!r}",
    )
    # Now Left at cursor=0 fires .leftEdge.
    app.send_key("left")
    preview = app.preview_text()
    assert_true(
        "boundary: leftEdge" in preview,
        f"Left at cursor=0 should fire .leftEdge via .modal callback; preview: {preview[:300]!r}",
    )


# BEL, the C0 control a terminal answers with a beep or a flash (ECMA-48).
BEL = b"\x07"


def storybook_textinput_boundary_rings_the_bell(app: Client) -> None:
    """`.boundaryFeedback` page, second TextInput under `.bell`: a wall
    hit must write BEL (0x07) to the terminal. Nothing supplied the bell,
    so `.bell` was silent; a hit changes no cell, so the byte cannot ride
    on a frame's diff alone. The `.modal` input above must stay silent."""
    app.goto_page(".boundaryFeedback")
    app.send_key("tab")
    start = len(app.pty_output())
    app.send_key("right")
    assert_true(BEL not in app.pty_output()[start:],
                "a wall hit under .modal must not ring the bell")
    app.send_key("tab")
    start = len(app.pty_output())
    app.send_key("left")
    app.wait_until(lambda client: BEL in client.pty_output()[start:], timeout=2.0)
    rang = app.pty_output()[start:].count(BEL)
    assert_true(rang == 1, f"Left at an empty .bell TextInput must write one BEL; wrote {rang}")


# SGR background colours (ECMA-48 8.3.117): the default theme's warning is
# yellow, its accent cyan.
WARNING_BACKGROUND = b"\x1b[43m"
ACCENT_BACKGROUND = b"\x1b[46m"


def storybook_textarea_wall_flashes_the_cursor(app: Client) -> None:
    """`.bounce`, the default boundary feedback, lights the cursor in the
    theme's warning colour for a moment at a wall, then the accent comes
    back — the timed redraw an idle app makes on its own. Regression:
    `.bounce` drew nothing at all."""
    app.goto_page("TextArea")
    app.send_key("tab")
    start = len(app.pty_output())
    app.send_key("left")
    assert_true(app.wait_until(lambda c: WARNING_BACKGROUND in c.pty_output()[start:], timeout=2.0),
                "Left at the first character should light the cursor in the warning colour")
    lit = start + app.pty_output()[start:].index(WARNING_BACKGROUND)
    assert_true(app.wait_until(lambda c: ACCENT_BACKGROUND in c.pty_output()[lit:], timeout=2.0),
                "the cursor should go back to the accent once the flash is over")


def storybook_textinput_cursor_mid_buffer_edit(app: Client) -> None:
    """TextInput cursor model: typing 'AC', then Left, then 'B' must
    produce 'ABC' (mid-buffer insert), not 'ACB' (legacy append-only).
    Pins the cursor contract end-to-end through the live
    Storybook TextInput page."""
    app.goto_page("TextInput")
    app.send_key("tab")
    # Type "AC", then Left, then 'B'. With a real cursor model, 'B'
    # inserts between A and C, so the value is "ABC".
    app.send_key("A")
    app.send_key("C")
    app.send_key("left")
    app.send_key("B")
    preview = app.preview_text()
    assert_true(
        "→ ABC" in preview,
        f"mid-buffer insert produced wrong value (expected 'ABC'); preview: {preview[:300]!r}",
    )


def storybook_disabled_skips_focus(app: Client) -> None:
    """`.disabled()` page has two Buttons: 'Live' and 'Dead' (disabled).
    Tab from the sidebar must land on Live; pressing Tab again must wrap
    back to a sidebar focusable rather than landing on Dead. Pressing
    Enter on Live increments the counter; the counter must NEVER be
    incremented by Tab/Enter cycles that would have hit Dead."""
    app.goto_page(".disabled")
    app.send_key("tab")
    # Counter starts at 0 — read the preview pane.
    pre = app.preview_text()
    assert_true(
        "[ Live ]" in pre,
        f"Disabled page preview missing 'Live' button text — got {pre[:200]!r}",
    )
    assert_true(
        "[ Dead ]" in pre,
        f"Disabled page preview missing 'Dead' button text — got {pre[:200]!r}",
    )
    # The Dead button should NOT be in tab order. Press Enter on the
    # current focus (which should be Live) — counter goes from 0 to 1.
    app.send_key("enter")
    after = app.preview_text()
    assert_true(
        "counter: 1" in after,
        f"Enter on Live didn't increment counter to 1 — got {after[:300]!r}",
    )


def storybook_actioncontext_ctrl_r_enters_resize_mode(app: Client) -> None:
    """`.actionContext` page: pressing Ctrl+R must push the "resize"
    context, visible in the preview as `mode: resize`. Default mode
    label is `mode: default`. Coverage that the demo's mode-toggle
    binding fires through the universal Ctrl path — Option/Alt is
    eaten by Apple Terminal as a compose key, so the demo deliberately
    uses Ctrl. Pressing Ctrl+R again pops the context (toggle), and the
    label returns to `mode: default`."""
    app.goto_page(".actionContext")
    app.send_key("tab")
    pre = app.preview_text()
    assert_true(
        "mode: default" in pre,
        f".actionContext preview should show 'mode: default' before any chord — got {pre[:300]!r}",
    )
    app.chord("ctrl+r")
    after_enter = app.preview_text()
    assert_true(
        "mode: resize" in after_enter,
        f"Ctrl+R should push 'resize' context — preview: {after_enter[:300]!r}",
    )
    # Toggle: second Ctrl+R returns to default.
    app.chord("ctrl+r")
    after_exit = app.preview_text()
    assert_true(
        "mode: default" in after_exit,
        f"Second Ctrl+R should pop back to default — preview: {after_exit[:300]!r}",
    )


def storybook_scrollview_shows_thumb_scrollbar(app: Client) -> None:
    """ScrollView with overflowing content paints the thumb-track
    scrollbar — │ track on the right column with the default (thin) ┃
    thumb segment."""
    app.goto_page("ScrollView")
    preview = app.preview_text()
    # Track glyphs: at least one │ on the right edge (anywhere in
    # preview is fine — the smoke harness already pins viewport to
    # the preview pane). Thumb glyph: at least one ┃ visible.
    assert_true("│" in preview, "ScrollView preview missing │ scrollbar track")
    assert_true("┃" in preview, "ScrollView preview missing ┃ scrollbar thumb")


def storybook_scrollview_tab_focuses_and_scrolls(app: Client) -> None:
    """ScrollView page has no focusable descendants — the ScrollView itself
    should accept Tab focus and respond to arrow/PageDown keys to scroll.
    Reported 2026-04-18: 'pressing tab when cursor is in ScrollView to see
    the preview doesn't work' — Tab cycled back to the sidebar because
    no focusable existed in the preview."""
    app.goto_page("ScrollView")
    before = app.focus()
    app.send_key("tab")
    after = app.focus()
    assert_true(
        after.node_id != before.node_id,
        "Tab from ScrollView page should land inside the preview",
    )
    # Down arrow should scroll the viewport so later rows become visible.
    app.send_key("down")
    app.send_key("down")
    app.send_key("down")
    assert_true(
        "row 3" in app.preview_text() or "row 4" in app.preview_text(),
        "Down arrow on focused ScrollView should advance the viewport",
    )


def storybook_geometryreader_reports_size(app: Client) -> None:
    """GeometryReader renders 'proposed: WxH' with the current rect size
    — confirms the lazy rebuild ships the real allocated rect,
    not the terminal default 80×24 stale value."""
    app.goto_page("GeometryReader")
    preview = app.preview_text()
    assert_true("proposed:" in preview, "GeometryReader preview missing 'proposed:' label")
    assert_true("×" in preview, "GeometryReader preview missing size separator")


def storybook_text_styles_render(app: Client) -> None:
    """Text primitive preview: plain / bold / colored / both — all four
    strings present in the rendered preview."""
    app.goto_page("Text")
    preview = app.preview_text()
    for label in ("plain", "bold", "colored", "both"):
        assert_true(label in preview, f"Text preview missing '{label}'")


def storybook_forEach_renders_all_items(app: Client) -> None:
    """ForEach preview iterates 5 colour names; each `[name]` should
    render somewhere in the preview pane."""
    app.goto_page("ForEach")
    preview = app.preview_text()
    for name in ("red", "yellow", "green", "cyan", "magenta"):
        assert_true(f"[{name}]" in preview, f"ForEach preview missing '[{name}]'")


def storybook_sparkline_renders_line(app: Client) -> None:
    """Sparkline draws a sine wave using braille dots — expect >20 braille
    cells somewhere in the preview."""
    app.goto_page("Sparkline")
    preview = app.preview_text()
    non_space = sum(1 for ch in preview if ch not in (" ", "\n"))
    assert_true(non_space > 10, f"Sparkline preview looked empty (non_space={non_space})")


def storybook_heatmap_renders_grid(app: Client) -> None:
    """HeatMap renders a colored 5×20 matrix; expect many shade characters
    (█ / ▒ / ▓ etc.) spanning the preview."""
    app.goto_page("HeatMap")
    preview = app.preview_text()
    non_space = sum(1 for ch in preview if ch not in (" ", "\n"))
    assert_true(non_space > 50, f"HeatMap looked empty (non_space={non_space})")


def storybook_braillecanvas_renders_curve(app: Client) -> None:
    """BrailleCanvas helper writes braille dots into the preview text."""
    app.goto_page("BrailleCanvas")
    preview = app.preview_text()
    has_braille = any(0x2800 <= ord(ch) <= 0x28FF for ch in preview)
    assert_true(has_braille, "BrailleCanvas didn't render any braille glyphs (U+2800–U+28FF)")


def storybook_dotmatrixtext_renders_HELLO(app: Client) -> None:
    """DotMatrixText renders the word HELLO via its internal dot-font.
    Each glyph column is rendered as block characters; the preview should
    have many `█`/`▓`/`▒` cells."""
    app.goto_page("DotMatrixText")
    preview = app.preview_text()
    filled = sum(1 for ch in preview if ch in "█▓▒░●")
    assert_true(filled > 20, f"DotMatrixText preview too sparse (filled={filled})")


def storybook_morseticker_renders_sos(app: Client) -> None:
    """MorseTicker draws the SOS pattern. Preview should contain braille
    cells (the ticker uses braille for sub-cell resolution)."""
    app.goto_page("MorseTicker")
    preview = app.preview_text()
    has_braille = any(0x2800 <= ord(ch) <= 0x28FF for ch in preview)
    assert_true(has_braille, "MorseTicker didn't render any braille ticker glyphs")


def storybook_foreground_renders_colored_words(app: Client) -> None:
    """`.foreground` modifier page: red/green/blue side by side. Glyph
    text is what we assert; colour-byte verification is out of scope
    until the client exposes per-cell style (future work)."""
    app.goto_page(".foreground")
    preview = app.preview_text()
    for word in ("red", "green", "blue"):
        assert_true(word in preview, f".foreground preview missing '{word}'")


def storybook_bold_distinguishes_styles(app: Client) -> None:
    """`.bold` modifier page: both the plain and bolded label render.
    Style bit verification (bold true on 'is bold' cells) belongs in a
    richer probe API; for now assert both lines land."""
    app.goto_page(".bold")
    preview = app.preview_text()
    for label in ("not bold", "is bold"):
        assert_true(label in preview, f".bold preview missing '{label}'")


def storybook_border_wraps_text(app: Client) -> None:
    """`.border` page: ' bordered ' text wrapped by a box-drawing frame.
    Verify the border-corner or horizontal glyphs land alongside the text."""
    app.goto_page(".border")
    preview = app.preview_text()
    assert_true("bordered" in preview, ".border preview missing label")
    # Rounded border uses ╭ ╮ ╰ ╯ — at least one corner should appear.
    has_corner = any(ch in preview for ch in "╭╮╰╯")
    assert_true(has_corner, ".border preview missing corner glyphs")


def storybook_padding_wraps_text(app: Client) -> None:
    """`.padding` page: uniform padding still frames its label, leading-only
    padding opens exactly two columns inside its box, and a rail keeps one
    column of room before its text."""
    app.goto_page(".padding")
    preview = app.preview_text()
    assert_true("all sides" in preview, ".padding preview missing the uniform example")
    assert_true("│  leading only" in preview, "leading-only padding is not two columns inside its box")
    assert_true("┃ rail, then room" in preview, "the rail has no column of room before its text")


def storybook_frame_sizes_bordered_box(app: Client) -> None:
    """`.frame(width:10, height:3).border()` page: 'x' centered in a
    bordered 10-wide, 3-tall box. Corners + 'x' must both show."""
    app.goto_page(".frame")
    preview = app.preview_text()
    assert_true("x" in preview, ".frame preview missing 'x' label")
    assert_true(any(ch in preview for ch in "╭╮╰╯"), ".frame preview missing border corners")


def storybook_flexible_distributes_remainder(app: Client) -> None:
    """`.flexible` page (35): renders the four canonical shapes (HStack
    fixed+flex+weighted, sidebar+content). Smoke pins the rendering
    contract: both demos visible, key labels present, no crash. The
    weighted-distribution math is unit-tested in FlexibleSizingTests."""
    app.goto_page(".flexible")
    preview = app.preview_text()
    assert_true("fixed" in preview, ".flexible preview missing 'fixed' label")
    assert_true("flex 1" in preview, ".flexible preview missing 'flex 1' label")
    assert_true("flex 2" in preview, ".flexible preview missing 'flex 2' label")
    assert_true("sidebar" in preview, ".flexible preview missing sidebar example")


def storybook_focusable_joins_tab_order(app: Client) -> None:
    """`.focusable` modifier page has exactly one focusable Text. Tab into
    it — focus should land on it, not bounce back to the sidebar."""
    app.goto_page(".focusable")
    before = app.focus()
    app.send_key("tab")
    after = app.focus()
    assert_true(
        after.node_id != before.node_id,
        ".focusable page should accept Tab into preview",
    )


def storybook_onhover_callback_fires_on_enter_leave(app: Client) -> None:
    """`.onHover` page (34): hover the indicator-bound row in the preview
    and watch the indicator text flip from '(not hovering)' → 'hovering'
    → 'left'. The page lays out the row + indicator inside a bordered
    Preview pane; we move the cursor far inside the preview to ensure
    we're hovering the row and not the indicator below it."""
    app.goto_page(".onHover")
    initial = app.preview_text()
    assert_true("hover this row" in initial, ".onHover preview missing target row")
    # Find the row's location in the rendered preview to pick a cursor
    # coordinate. Probe-by-grep: look up "hover this row" in the page
    # text and use its y for the mouse_move.
    full = app.text()
    target_y = None
    for y, row in enumerate(full.split("\n")):
        if "hover this row" in row:
            target_y = y
            break
    assert_true(target_y is not None, "could not locate 'hover this row' in screen")

    # Mouse into the row — picking column 60 places the cursor inside
    # the bordered Preview pane on a wide-enough terminal.
    app.mouse_move(60, target_y)
    after_enter = app.preview_text()
    assert_true(
        "hover indicator: hovering" in after_enter,
        f".onHover did not fire 'hovering' on enter — preview was: {after_enter[:200]}",
    )

    # Mouse out — far corner.
    app.mouse_move(0, 0)
    after_leave = app.preview_text()
    assert_true(
        "hover indicator: left" in after_leave,
        f".onHover did not fire 'left' on exit — preview was: {after_leave[:200]}",
    )


def storybook_mousefocuspolicy_renders_subtrees(app: Client) -> None:
    """`.mouseFocusPolicy` page (35): the preview shows two labels — outer
    (default policy) + inner (subtree override to .disabled). Smoke proof
    that the page renders + the per-subtree env modifier doesn't crash
    the runtime. Behavioural assertions live in unit tests."""
    app.goto_page(".mouseFocusPolicy")
    preview = app.preview_text()
    assert_true("default .clickToLock" in preview,
                ".mouseFocusPolicy preview missing outer subtree label")
    assert_true(".disabled" in preview,
                ".mouseFocusPolicy preview missing inner subtree label")


def storybook_bufferview_blits_demo_cells(app: Client) -> None:
    """`BufferView` page (Display group, index 22): a 24x4 demo CellBuffer
    is built in code and blitted into the view's rect. Smoke proof that
    all four rows of the source buffer appear verbatim in the rendered
    preview — the basic BufferView contract."""
    app.goto_page("BufferView")
    preview = app.preview_text()
    for needle in ("BufferView demo", "CellBuffer -> blit", "12345 67890"):
        assert_true(needle in preview,
                    f"BufferView preview missing source row: '{needle}' — preview was: {preview[:300]}")


def storybook_layout_stable_under_mouse_hover(app: Client) -> None:
    """Bug #3: moving the mouse over the screen must NOT change layout.
    The Code box width must stay constant whether or not the cursor is
    hovering somewhere. Captures the user-reported regression where
    moving the mouse on the HStack page shrank the Code panel and
    forced wrapping in the snippet."""
    app.goto_page("HStack")
    text_before = app.text()
    width_before = _code_box_width(text_before)
    app.mouse_move(80, 10)
    text_after = app.text()
    width_after = _code_box_width(text_after)
    assert_true(
        width_before == width_after,
        f"Code box width changed under mouse-move: {width_before} -> {width_after}",
    )


def storybook_layout_stable_under_arrow_repeat(app: Client) -> None:
    """Bug #3 (sister): repeatedly pressing arrow keys on a focused
    sidebar must not re-flow the Preview/Code geometry. Width stays
    constant across N keystrokes."""
    app.goto_page("VStack")
    width0 = _code_box_width(app.text())
    for _ in range(5):
        app.send_key("up")
    widthN = _code_box_width(app.text())
    assert_true(
        width0 == widthN,
        f"Code box width drifted across arrow-up presses: {width0} -> {widthN}",
    )


def _code_box_width(text: str) -> int:
    """Return the rendered width (column count) of the first bordered
    box found in `text`. Identifies the box by the top-left corner
    glyph `╭` and counts columns to the matching `╮`."""
    for line in text.splitlines():
        if "╭" in line and "╮" in line:
            start = line.index("╭")
            end = line.index("╮", start + 1)
            return end - start + 1
    return 0


def storybook_treeview_click_expand(app: Client) -> None:
    """Bug #2: clicking on a TreeView folder row must toggle its
    expanded state. The TreeView preview shows two roots ("Sources"
    and "Tests"); both auto-expand. Clicking on the "Sources" row
    should collapse it (children disappear), clicking again expands."""
    app.goto_page("TreeView")
    app.send_key("tab")
    preview_before = app.preview_text()
    assert_true(
        "└── ▸ TerminalUI" in preview_before,
        "TreeView should show 'TerminalUI' under expanded 'Sources' root by default",
    )
    f = app.focus()
    if f.rect:
        # Click row 0 (Sources) — first row of the focused TreeView rect
        x = f.rect[0] + 2
        y = f.rect[1]
        app.mouse_click(x, y)
    preview_after = app.preview_text()
    assert_true(
        "└── ▸ TerminalUI" not in preview_after,
        "Click on expanded 'Sources' row should collapse it (TerminalUI child gone)",
    )


def storybook_treeview_keyboard_expand_collapse(app: Client) -> None:
    """Bug #2 (sister): keyboard expand/collapse must work in TreeView.
    Auto-expand on first render shows Sources > TerminalUI. Left on
    Sources collapses. Right re-expands. Asserts the visible-child
    name "TerminalUI" goes away when only Tests is showing
    (Tests has TerminalUITests, so we look for the specific child)."""
    app.goto_page("TreeView")
    app.send_key("tab")
    preview = app.preview_text()
    assert_true(
        "└── ▸ TerminalUI" in preview,
        "TreeView should boot with Sources expanded showing 'TerminalUI' child",
    )
    app.send_key("left")
    collapsed = app.preview_text()
    assert_true(
        "└── ▸ TerminalUI" not in collapsed,
        "Left arrow on expanded Sources root should hide its TerminalUI child",
    )
    assert_true(
        "▸ Sources" in collapsed,
        "Sources row should now show the collapsed glyph (▸)",
    )
    app.send_key("right")
    expanded = app.preview_text()
    assert_true(
        "└── ▸ TerminalUI" in expanded,
        "Right arrow on collapsed Sources root should reveal its TerminalUI child",
    )


def storybook_mouse_click_on_sidebar_navigates(app: Client) -> None:
    """Bug #1: clicking on a sidebar page row must navigate to that
    page. The page title (row 1, right of sidebar) is the canonical
    indicator — it must change from "VStack" to "ZStack" after the
    click. Sidebar list always contains the row label so we cannot
    use full-screen substring matches."""
    app.goto_page("VStack")
    title_before = app.text().splitlines()[1]
    assert_true(
        "VStack" in title_before,
        f"should boot on VStack page; title was: {title_before!r}",
    )
    # Sidebar layout: row 4=VStack, 5=HStack, 6=ZStack, 7=Spacer, ...
    app.mouse_click(2, 6)
    title_after = app.text().splitlines()[1]
    assert_true(
        "ZStack" in title_after and "VStack" not in title_after,
        f"Click on ZStack sidebar row should navigate to ZStack page; title was: {title_after!r}",
    )


def storybook_mouse_wheel_scrolls_hovered_scrollview(app: Client) -> None:
    """Regression guard: wheel-down at a hovered scrollable ScrollView
    must advance its scrollOffset, even when keyboard focus is on the
    sidebar. Pre-fix: handleScrollKey read engine.keyboardFocusID and
    walked the SIDEBAR's subtree for a scroll-layout (none found),
    returning .ignored — wheel did nothing visible. Post-fix: routing
    target is read from GraphContext.currentRoutingNodeID, so the
    handler resolves the ScrollView's own scroll-layout."""
    app.goto_page("ScrollView")
    # Capture preview's first content row before wheel.
    text_before = app.preview_text()
    # Find "row 0" position to hover precisely.
    full = app.text()
    rows = full.split("\n")
    target_x, target_y = None, None
    for y, row in enumerate(rows):
        if "row 0" in row:
            target_x = row.find("row 0") + 2
            target_y = y
            break
    assert_true(
        target_x is not None,
        "ScrollView page should display 'row 0' before wheel-down",
    )
    # Mouse-move + wheel-down WITHOUT a Tab. Pre-fix path would return
    # .ignored because keyboard focus is still on the sidebar; post-fix
    # routes through currentRoutingNodeID and scrolls the hovered view.
    app.mouse_move(target_x, target_y)
    app.mouse_wheel("down", target_x, target_y)
    text_after = app.preview_text()
    # Post-fix: viewport advances by 3 rows per wheel-down (the runtime
    # synthesises 3 arrow events). Earliest visible row should now be
    # "row 3" or later, not "row 0".
    assert_true(
        text_before != text_after,
        f"wheel-down at hovered ScrollView must advance the viewport; "
        f"before == after content unchanged",
    )


def storybook_mouse_wheel_routes_to_hover_target(app: Client) -> None:
    """Bug #1 (sister): wheel-scroll must route to the hover target,
    not the keyboard-focused element. With keyboard focus on the
    sidebar, scrolling over the Preview pane should affect Preview
    (or do nothing visible if Preview content is short), NOT advance
    the sidebar selection. Currently scrollUp/scrollDown route to
    keyboard focus → sidebar advances when you wheel anywhere."""
    app.goto_page("VStack")
    selected_before = "VStack"
    # Sidebar focus, wheel-down over preview area (right half of screen)
    app.mouse_move(100, 20)
    app.mouse_wheel("down", 100, 20)
    after = app.text()[:200]
    # If wheel routed to focus (current bad behaviour), sidebar selection
    # advanced from VStack to HStack and the preview now reads "HStack".
    # Correct behaviour: wheel didn't change page; preview still shows VStack.
    assert_true(
        "VStack" in after,
        f"Wheel-scroll over preview should not advance sidebar selection; got: {after!r}",
    )


def storybook_mouse_wheel_scrolls_hovered_sidebar(app: Client) -> None:
    """User-reported: wheel-scroll over the Storybook sidebar must
    advance the sidebar's viewport even when keyboard focus is on
    the preview pane. The sidebar is a bare `ScrollView` (no
    `.scrollable()`) — the framework's `wheelTargetID` finds no
    focusable under the cursor and previously dropped the wheel.
    The hovered-ScrollView fallback in the runtime now mutates the
    deepest scroll-layout's offset directly so visual sliding
    matches user intent. Verbatim user report (2026-05-06):
    *\"scroll doesn't work with mouse when storybook sidebar is in
    mouse focus.\"*"""
    # Drive sidebar to the top so we have downward room.
    app.goto_page("Text")  # First page in the alphabet — sidebar at top.
    rows_before = app.storybook_sidebar_rows()
    assert_true(
        len(rows_before) > 0,
        "sidebar must show at least one row before scroll",
    )
    # Hover over a sidebar row well below any divider line.
    app.mouse_move(10, 10)
    # Send wheel-down at the same coordinate. The runtime's
    # findScrollNodeAt fallback should locate the sidebar's scroll
    # layout and advance its offset by 3 rows.
    app.mouse_wheel("down", 10, 10)
    rows_after = app.storybook_sidebar_rows()
    assert_true(
        rows_before != rows_after,
        f"wheel-down on hovered sidebar must change visible rows; "
        f"before={rows_before[:3]} after={rows_after[:3]}",
    )


def storybook_mouse_click_locks_until_next_click(app: Client) -> None:
    """Bug #1 (sister): once the user clicks somewhere, hover-only
    motion should not steal focus or routing — until the next click
    targets a different region. This protects against the user moving
    the cursor out of the way after committing focus to a region.

    Setup: click into the preview, then mouse_move to sidebar area,
    assert the focus didn't drift away from the preview's vicinity."""
    app.goto_page("Table")
    # Tab into preview to give us a stable preview-focus baseline first
    app.send_key("tab")
    f_after_tab = app.focus()
    # Now move the mouse over the sidebar — focus must NOT migrate.
    app.mouse_move(5, 10)
    f_after_move = app.focus()
    assert_true(
        f_after_tab.node_id == f_after_move.node_id,
        "Mouse-move alone (no click) should not change keyboard focus",
    )


def storybook_list_actions_returns_quit_default(app: Client) -> None:
    """RemoteControl `list_actions` exposes the framework's default
    Ctrl+C → app.quit binding. Validates the LLM-side action graph
    surface — agents can ask "what can I do here?" and find the
    framework defaults without scraping cells or guessing chords."""
    actions = app.list_actions()
    quit_action = next((a for a in actions if a.id == "app.quit"), None)
    assert_true(quit_action is not None,
                f"app.quit must appear in list_actions; got: {[a.id for a in actions]}")
    assert_true(quit_action.title == "Quit",
                f"app.quit title should be 'Quit'; got '{quit_action.title}'")
    assert_true(quit_action.enabled,
                "app.quit must be enabled by default")
    keyboard_bindings = [b for b in quit_action.bindings if b.kind == "keyboard"]
    assert_true(any(b.key == "c" and b.modifiers == ["ctrl"] for b in keyboard_bindings),
                f"app.quit must be bound to Ctrl+C; got: {[(b.key, b.modifiers) for b in keyboard_bindings]}")


def storybook_invoke_action_quits_app(app: Client) -> None:
    """RemoteControl `invoke_action` fires an action by stable ID
    without simulating a chord. Invoking app.quit must exit the
    process cleanly via the same framework-default path Ctrl+C uses.
    Critical contract for LLM-driven test harnesses."""
    fired = app.invoke_action("app.quit")
    assert_true(fired,
                "invoke_action('app.quit') must return fired=True (action graph dispatched)")
    # Note: process exits asynchronously via the QuitSignal poll in
    # the event loop; the runner's __exit__ tears down anyway.


def storybook_actions_modifier_fires_via_chord(app: Client) -> None:
    """`.actions` page (Modifiers group, last index 38): a focusable
    VStack carries an action bound to Ctrl+P. Tab into the preview,
    fire Ctrl+P, observe the counter increment from 0. Exercises the
    full action graph dispatch path: focus walker → ActionScope lookup
    → bound action perform closure → state mutation → re-render."""
    app.goto_page(".actions")
    app.send_key("tab")
    # Initial counter shows 0 in the page (search full text — preview
    # pane on this page is small enough that preview_text() crops it).
    initial = app.text()
    assert_true("counter: 0" in initial,
                f"actions page should start with 'counter: 0'; full text first 400: {initial[:400]}")
    # Fire the bound chord via the framework dispatch.
    app.send_key("p", "ctrl")
    # The action mutates state from a `Task { @MainActor }`, after the key.
    advanced = app.wait_until(lambda c: any(f"counter: {n}" in c.text() for n in range(1, 10)))
    after = app.text()
    assert_true(
        advanced,
        f"actions counter should be >0 after Ctrl+P; first 400: {after[:400]}"
    )


def demo_app_renders(app: Client) -> None:
    """Plain Demo smoke — renders its title bar and TabView strip
    without crashing. Looks for the "TerminalUI" banner (row 2-3) and
    one of the tab labels (row 4) to catch both a blank screen AND a
    broken tab strip."""
    snap_title = app.cells(rect=[0, 0, 80, 4])
    assert_contains(snap_title, "TerminalUI", context="Demo title cell")
    snap_tabs = app.cells(rect=[0, 4, 80, 1])
    assert_contains(snap_tabs, "Build", context="Demo Build tab label")


# ---- GitClient demo ----------------------------------------------------
# A flagship dogfood demo: file tree + diff view + commit prompt, with
# keyboard-driven hunk staging. Pinned by these smoke cases so future
# regressions in TreeView focus, HunkDiffView range selection, or
# PromptInput submit can't slip past us.


def gitclient_renders(app: Client) -> None:
    """Boots and shows the three-pane layout: file tree on the left,
    diff view on the right, commit prompt at the bottom. We assert
    against the demo's fixture data so a broken layout (panes
    overlapping, diff swallowed, prompt dropped) lights up."""
    snap = app.cells()
    full = snap.text()
    assert_true("file_a.swift" in full or "src/" in full,
                "expected file tree to list fixture file")
    assert_true("@@" in full,
                "expected hunk header from default-selected file's diff")
    assert_true("Commit" in full or "commit" in full,
                "expected commit prompt label")


def gitclient_tab_focuses_diff(app: Client) -> None:
    """Tab cycles focus tree → diff → commit. After one Tab, the
    diff pane should own keyboard focus. We assert by rect rather
    than kind: the DiffPane sits in the right half of the screen,
    so focus's x-coordinate must land beyond the file-tree pane's
    right edge (col 32 in our layout)."""
    app.send_key("tab")
    focus = app.focus()
    rect = getattr(focus, "rect", None)
    assert_true(rect is not None, "Tab should land on a focusable node")
    assert_true(
        rect[0] >= 32,
        f"after Tab, focus rect x={rect[0]} should be in the right pane (>=32)",
    )


def gitclient_s_stages_hunk(app: Client) -> None:
    """`s` on the focused hunk moves it from "unstaged" to "staged".
    The status bar / footer renders the count, so we assert the
    "1 staged" hint appears after pressing `s` once."""
    # Tab to diff pane, then press `s` to stage the hunk under cursor.
    app.send_key("tab")
    app.send_text("s")
    snap = app.cells()
    full = snap.text()
    assert_true(
        "1 staged" in full or "staged: 1" in full or "[1]" in full,
        "expected staged-count indicator after pressing `s`",
    )


def gitclient_commit_clears_staged(app: Client) -> None:
    """Enter inside the focused PromptInput commits the staged
    set and appends the message to the fake log. Sequence:
    Tab → s → Tab → type message → Enter. SwiftUI parity:
    PromptInput.onSubmit is the canonical commit channel — no
    global `c` chord that would swallow the letter while typing."""
    app.send_key("tab")              # focus diff
    app.send_text("s")               # stage hunk
    app.send_key("tab")              # focus commit prompt
    app.send_text("test commit")
    app.send_key("enter")            # PromptInput.onSubmit fires
    snap = app.cells()
    full = snap.text()
    assert_true(
        "0 staged" in full or "staged: 0" in full or "[0]" in full,
        "after commit, staged count should be zero",
    )


def gitclient_q_quits(app: Client) -> None:
    """`q` exits the app, and the runner checks it went cleanly. The case
    waits for the exit itself: the runner stops whatever is still running
    with SIGTERM, so an app `q` left running would pass, and one that
    finished quitting just as the SIGTERM went out reads as having
    ignored it."""
    app.send_text("q")
    assert_true(app.wait_for_exit(5.0) is not None, "q should quit")


# ---- Chat demo ---------------------------------------------------------
# Second flagship demo. Different surface from GitClient — exercises a
# scroll-list of dynamic content + PromptInput + delayed bot reply (via
# TerminalTimer). Pinned by these smoke cases so future regressions in
# scroll-pinning, message-list rendering, or PromptInput.onSubmit don't
# slip past.


def chat_renders(app: Client) -> None:
    """Boots and shows fixture messages + the prompt. The 12 canned
    messages all live in the message list above the prompt — we
    assert at least three of them appear so a partial render
    (e.g., prompt visible but list cleared) lights up."""
    snap = app.cells()
    full = snap.text()
    assert_true("alice" in full, "expected 'alice' in fixture messages")
    assert_true("bob" in full, "expected 'bob' in fixture messages")
    assert_true("#general" in full, "expected channel name in status bar")


def chat_send_message_appends(app: Client) -> None:
    """Type a message → Enter submits → 'you' line appended at the
    bottom. Tab into the prompt first (the message list owns
    initial focus when scrollable)."""
    # Boot focus may sit on the scroll list; tab/click into prompt.
    app.send_key("tab")
    app.send_text("hello there")
    app.send_key("enter")
    snap = app.cells()
    full = snap.text()
    assert_true("hello there" in full,
                "submitted message body should appear in the message list")
    assert_true("you" in full,
                "user's message should be tagged with the 'you' name")
    # The row is `name HH:MM body` — the gap after the timestamp comes from
    # the row's HStack spacing, which once defaulted to 0 and fused them
    # ("10:42Hi everyone").
    assert_true(re.search(r"\d\d:\d\d hello there", full) is not None,
                "timestamp and body should be separated by a space")


def chat_bot_reply_appears(app: Client) -> None:
    """Bot replies after a short delay, driven by a TerminalTimer tick:
    submit a message, and the bot's reply appears tagged 'bot'."""
    app.send_key("tab")
    app.send_text("ping")
    app.send_key("enter")
    # The bot replies on a timer tick ~200ms after the submit.
    assert_true(app.wait_until(lambda c: "bot" in c.cells().text()),
                "bot reply (tagged 'bot') should appear after user message")


def chat_scroll_pins_to_bottom(app: Client) -> None:
    """When a new message arrives, the ScrollView pins to the
    latest. The fixture has more messages than fit in the
    viewport; submitting a unique message should make IT visible
    even if the older messages are scrolled past."""
    app.send_key("tab")
    app.send_text("anchor message zzz")
    app.send_key("enter")
    snap = app.cells()
    full = snap.text()
    assert_true("anchor message zzz" in full,
                "newly-submitted message must be auto-scrolled into view")


def chat_q_in_empty_prompt_quits(app: Client) -> None:
    """`q` quits ONLY when the prompt is empty. (`q` while typing
    must be a literal letter; otherwise words like 'queue' become
    unwriteable.) Boot focus is on the prompt-empty state, so a
    bare `q` press should exit cleanly."""
    app.send_key("tab")
    app.send_text("q")
    assert_true(app.wait_for_exit(5.0) is not None, "q in an empty prompt should quit")


# ---- Coder demo --------------------------------------------------------
# The Crush-parity forcing function (design/crush-parity.md §5). Its
# transcript embeds framework components inside cards, which is where a
# component that behaves like a control instead of content shows up.

# Inside the transcript, clear of the sidebar and its scrollbar.
CODER_TRANSCRIPT_POINT = (40, 15)
CODER_DIFF_REMOVED = "-        previousBuffer = nil"
CODER_DIFF_ADDED = "+        skippedFrame = true"
CODER_DIFF_FIRST = "private var previousBuffer: CellBuffer?"


def _coder_scroll_until(app: Client, needle: str, what: str, *also: str) -> str:
    """Wheel the transcript back from its tail, where it opens, until
    `needle` — and every string in `also` — is on screen, and return the
    frame text. Waiting for everything a case asserts on, rather than for one
    line and assuming its neighbours came with it, keeps a one-row shift in
    wrapping from turning into a false failure. Stops when the frame stops
    changing — the transcript's start."""
    text = app.cells().text()
    while not all(part in text for part in (needle, *also)):
        app.mouse_wheel("up", *CODER_TRANSCRIPT_POINT)
        after = app.cells().text()
        if after == text:
            raise CaseFailed(f"{what} never scrolled into view")
        text = after
    return text


def _coder_scroll_to_edit_card(app: Client) -> str:
    """The Edit card sits below the fold at 40 rows; scroll until its whole
    change — first line, removal and addition — is on screen."""
    return _coder_scroll_until(app, CODER_DIFF_FIRST, "Edit card's diff",
                               CODER_DIFF_REMOVED, CODER_DIFF_ADDED)


def coder_renders(app: Client) -> None:
    """Boots into the shell: wordmark, a user message, a tool card."""
    assert_true("CODER" in app.cells().text(), "expected the wordmark in the header")
    _coder_scroll_until(app, "You", "the user's message", "Read")


def coder_opens_on_the_latest_entry(app: Client) -> None:
    """The transcript opens on its tail — the pending Bash card — as Crush's
    does, with nothing scrolled."""
    assert_true(CODER_LATEST_ENTRY in app.cells().text(),
                "the latest entry should be on screen at boot")


def coder_typing_reaches_the_prompt(app: Client) -> None:
    """What the user types lands in the composer, behind its focused `>`, and
    neither a `q` nor Escape ends the session. Regression: the composer was
    a drawing, `q` and Escape were quit chords, and the first word with a
    `q` in it closed the app and ran the rest of the line in the shell."""
    app.send_text("quit queue")
    app.send_key("escape")
    app.ping()
    assert_true("> quit queue" in app.cells().text(),
                "the typed text should sit in the composer after its `>`")


def coder_readline_keys_edit_the_draft(app: Client) -> None:
    """The composer edits with readline's keys, from the bytes a terminal
    sends: Ctrl+A — which Ghostty, iTerm2 and Terminal.app also send for
    Cmd+Left — Option+Right as `ESC f`, Ctrl+K, Ctrl+E, Ctrl+Y. Regression:
    no input knew Ctrl+K, and each kept its own handful of editing keys."""
    app.send_text("keep this gone")
    app.write_raw(b"\x01\x1bf\x0b")
    draft = app.cells().text()
    assert_true("> keep" in draft and "this gone" not in draft,
                "Ctrl+A, a word forward, then Ctrl+K should leave `keep`")
    app.write_raw(b"\x05\x19")
    assert_true("> keep this gone" in app.cells().text(),
                "Ctrl+E then Ctrl+Y should yank the kill back onto the end")


def coder_reads_the_users_keymap(app: Client) -> None:
    """Coder opts into a user keymap, `keys.toml` in its config directory:
    the case's runner points XDG_CONFIG_HOME at one that binds Ctrl+O to
    kill to the end of the line and unbinds Ctrl+K. The user's bindings lie
    over the app's, so Ctrl+O kills and Ctrl+K no longer does."""
    app.send_text("keep this gone")
    app.write_raw(b"\x01\x1bf\x0b")
    assert_true("> keep this gone" in app.cells().text(), "Ctrl+K is unbound by the user's file")
    app.write_raw(b"\x0f")
    draft = app.cells().text()
    assert_true("> keep" in draft and "this gone" not in draft,
                "Ctrl+O, bound by the user's file, should kill to the end of the line")


def coder_enter_sends_the_draft(app: Client) -> None:
    """Enter sends the draft into the transcript and empties the composer,
    which shows its placeholder again."""
    app.send_text("lands at the end")
    app.send_key("enter")
    assert_true("lands at the end" in app.cells().text(),
                "the sent message should come into view with nothing scrolled")
    assert_true("Ask anything" in app.cells().text(), "the composer empties after sending")


def coder_edit_card_shows_diff(app: Client) -> None:
    """The Edit card renders its change as a diff with no focus bar beside
    it — a `▎` there means the diff took focus it has no use for (DiffView
    was once unconditionally focusable and took boot focus)."""
    text = _coder_scroll_to_edit_card(app)
    rows = text.splitlines()
    removed = next(row for row in rows if CODER_DIFF_REMOVED in row)
    assert_true(CODER_DIFF_ADDED in text, "expected the added line")
    diff_rows = [row for row in rows
                 if CODER_DIFF_FIRST in row or CODER_DIFF_REMOVED in row or CODER_DIFF_ADDED in row]
    assert_true(all("▎" not in row for row in diff_rows),
                f"a focus bar is drawn beside the diff: {removed.strip()!r}")


def coder_transcript_diff_takes_no_keys(app: Client) -> None:
    """A diff that fits its card has nothing to scroll, so arrow keys must
    not reach it. Regression: DiffView was unconditionally focusable, took
    boot focus, and Down scrolled the edit's first line out of the card."""
    before = _coder_scroll_to_edit_card(app)
    app.press_many("down", 3)
    after = app.cells().text()
    assert_true(CODER_DIFF_FIRST in after, "Down scrolled the diff inside its card")
    assert_true(after == before, "arrow keys changed the transcript")


def coder_reply_keeps_heading_markers_and_chips_code(app: Client) -> None:
    """The transcript draws replies in the demo's markdown style: headings
    keep their `##` marker, and inline code is padded into a chip."""
    text = _coder_scroll_until(app, "## The fix", "the reply's heading", " previousBuffer  to signal")
    assert_true("## The fix" in text, "expected the heading drawn with its marker")
    assert_true(" previousBuffer  to signal" in text, "expected inline code padded as a chip")


def coder_read_card_shows_numbered_excerpt(app: Client) -> None:
    """A Read result shows the file text itself, numbered from where the
    read started rather than from one, and capped like any tool result."""
    text = _coder_scroll_until(app, "/// Compute the bytes", "the Read excerpt", "… (5 lines hidden)")
    rows = text.splitlines()
    first = next((row for row in rows if "/// Compute the bytes" in row), None)
    assert_true(first is not None, "expected the excerpt's first line")
    assert_true("298" in first, f"excerpt not numbered from its file line: {first.strip()!r}")
    assert_true("… (5 lines hidden)" in text, "expected the excerpt's hidden-line count")


# The rail Crush thickens on the transcript entry the reader selected.
CODER_FOCUSED_RAIL = "▌"
# The latest entry, a Bash call still waiting, and the one above it, a
# finished test run whose output is capped.
CODER_LATEST_ENTRY = "Waiting for tool response"
CODER_CAPPED_ENTRY = "swift test --filter Compositor"
# A line of that output the cap holds back.
CODER_HIDDEN_LINE = "Test run with 5 tests"
CODER_CAPPED_NOTE = "… (4 lines hidden) [click or space to expand]"
# Rows the transcript fills, beside the sidebar; the top one tells whether it
# scrolled.
CODER_TRANSCRIPT_TOP = (0, 1, 84, 1)


def _coder_rail_rows(text: str) -> list[str]:
    """The transcript rows the focused rail runs down."""
    return [row for row in text.splitlines() if row.lstrip().startswith(CODER_FOCUSED_RAIL)]


def _coder_hidden_note(text: str) -> Optional[tuple[int, int]]:
    """Where the capped result's `lines hidden` note is on screen, if it is."""
    for y, row in enumerate(text.splitlines()):
        if "lines hidden" in row:
            return row.index("lines hidden"), y
    return None


def coder_tab_reaches_the_transcript(app: Client) -> None:
    """The composer holds focus when Coder opens, though the transcript comes
    first in Tab order; Tab reaches the transcript, and the latest entry —
    the selection until the reader moves it — wears the focused rail."""
    app.send_text("x")
    assert_true("> x" in app.text(), f"typing at launch should reach the composer: {app.text()!r}")
    app.send_key("backspace")
    assert_true(not _coder_rail_rows(app.text()),
                "no entry should wear the focused rail while the composer has focus")
    app.tab()
    rails = _coder_rail_rows(app.text())
    assert_true(any(CODER_LATEST_ENTRY in row for row in rails),
                f"the latest entry should wear the focused rail: {rails!r}")


def coder_shift_arrows_step_the_selection(app: Client) -> None:
    """Shift+↑ and Shift+↓ step the selection an entry at a time, and an
    entry already in sight is selected without the transcript moving."""
    app.tab()
    top = app.cells(CODER_TRANSCRIPT_TOP).text()
    app.send_key("up", "shift")
    rails = _coder_rail_rows(app.text())
    assert_true(any(CODER_CAPPED_ENTRY in row for row in rails),
                f"Shift+↑ should select the entry above: {rails!r}")
    assert_true(app.cells(CODER_TRANSCRIPT_TOP).text() == top,
                "selecting an entry in sight should not scroll the transcript")
    app.send_key("down", "shift")
    assert_true(any(CODER_LATEST_ENTRY in row for row in _coder_rail_rows(app.text())),
                "Shift+↓ should select the entry below again")


def coder_space_expands_a_capped_result(app: Client) -> None:
    """Space opens the selected capped result, as the note under it says,
    and closes it again."""
    app.tab()
    app.send_key("up", "shift")
    assert_true(CODER_CAPPED_NOTE in app.text(), "expected the capped note")
    app.send_text(" ")
    text = app.text()
    assert_true(_coder_hidden_note(text) is None and CODER_HIDDEN_LINE in text,
                f"Space should open the result: {text!r}")
    app.send_text(" ")
    assert_true(_coder_hidden_note(app.text()) is not None, "Space again should close it")


def coder_click_expands_a_capped_result(app: Client) -> None:
    """A click on a capped result selects it and opens it."""
    note = _coder_hidden_note(app.text())
    assert_true(note is not None, "expected the capped note in sight")
    app.mouse_click(*note)
    text = app.text()
    assert_true(_coder_hidden_note(text) is None and CODER_HIDDEN_LINE in text,
                f"a click should open the result: {text!r}")
    assert_true(any(CODER_HIDDEN_LINE in row for row in _coder_rail_rows(text)),
                "the clicked entry should be selected")


def coder_scrolling_keeps_the_selection_in_sight(app: Client) -> None:
    """Scrolled with the arrows until the selected entry leaves the view, the
    selection passes to the nearest entry still in it, so Space acts on
    something the reader can see. Reported once a frame is drawn, so the
    rail moves a frame after the scroll."""
    app.tab()
    app.press_many("up", 20)
    assert_true(app.wait_until(lambda c: bool(_coder_rail_rows(c.text()))),
                "the selection should follow into the view")
    assert_true(CODER_LATEST_ENTRY not in app.text(), "the latest entry should have scrolled out of sight")


def coder_wheel_burst_keeps_running(app: Client) -> None:
    """A burst of real wheel reports — raw SGR 1006 bytes through the PTY,
    as a trackpad sends them — leaves the app running. Regression: debug
    builds trace their first frames, and the input task recorded each
    event's bytes into the same unguarded array the render loop was
    recycling; scrolling Coder crashed it with SIGSEGV."""
    # Spread over a couple of seconds, as a real scroll is, so parsing and
    # drawing overlap; one instant burst is parsed before a frame starts.
    x, y = CODER_TRANSCRIPT_POINT
    for step in range(80):
        direction = 64 if (step // 10) % 2 == 0 else 65
        app.write_raw(f"\x1b[<{direction};{x + 1};{y + 1}M".encode() * 20)
        time.sleep(0.02)
    app.ping()
    assert_true("CODER" in app.cells().text(), "the app should still be drawing")


def coder_crash_restores_the_terminal(app: Client) -> None:
    """A crash leaves the terminal as the app found it: mouse reporting off,
    the alternate screen left, the cursor shown. Regression: only SIGINT,
    SIGTERM and SIGHUP restored it, so a crash while scrolling printed its
    backtrace as a staircase over the last frame and the shell went on
    receiving mouse coordinates as typed text."""
    import signal
    before = len(app.pty_output())
    app.expected_exit_signal = signal.SIGSEGV
    app.crash()
    restored = (b"\x1b[?1006l", b"\x1b[?1000l", b"\x1b[?1049l", b"\x1b[?25h")
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        after = app.pty_output()[before:]
        if all(sequence in after for sequence in restored):
            return
        time.sleep(0.05)
    raise CaseFailed(f"the terminal was not restored after SIGSEGV: {app.pty_output()[before:][:200]!r}")


def idle_costs_nothing(app: Client) -> None:
    """An app with nothing to do sleeps until something happens. Regression:
    an `.onDemand` app — documented as zero CPU when idle — polled every
    millisecond for work, and every app polled for a resize every 16ms."""
    time.sleep(1.0)
    before = app.cpu_seconds()
    time.sleep(4.0)
    used = app.cpu_seconds() - before
    assert_true(used < 0.03, f"idle for 4s, the app used {used:.3f}s of CPU")


# Long enough for an app to finish its startup frames and park in its idle
# wait, which a remote command then has to wake.
IDLE_SETTLE_SECONDS = 0.3


def _settled_frame(app: Client) -> int:
    """The frame an app shows once it has gone idle."""
    time.sleep(IDLE_SETTLE_SECONDS)
    return app.frame_number()


def navigation_an_idle_app_acts_on_remote_commands(app: Client) -> None:
    """An idle `.onDemand` app answers its socket, and draws what a command
    changes. Regressions: its wait loop stopped reading the socket, the only
    source of events an idle app has, so nothing could drive it; and a
    command that changed what is drawn without an event or observed state —
    `inspector-toggle`, a focus set, a screenshot — showed only at the next
    keypress."""
    before = _settled_frame(app)
    app.send_key("down")
    assert_true(app.frame_number() > before, "a key sent to the idle app drew no frame")
    before = _settled_frame(app)
    app.inspector_toggle()
    assert_true(app.frame_number() > before, "toggling the inspector drew no frame")


def navigation_invoke_action_quits_an_idle_app(app: Client) -> None:
    """`invoke_action app.quit` ends an idle app. Regression: the quit
    signal was read only while handling a key, so an idle app went on."""
    time.sleep(IDLE_SETTLE_SECONDS)
    assert_true(app.invoke_action("app.quit"), "app.quit did not fire")
    assert_true(app.wait_for_exit(3.0) is not None, "the app was still running 3s after app.quit")


# ---------------------------------------------------------------------------
# The harness contract: input is drawn before the next reply
#
# A case asserts straight after it types, with no wait between. Over the
# socket the runtime serves requests before it drains events, so a reply
# comes after the keys sent before it are drawn. Through the terminal,
# `paste` and `write_raw` return once the app has turned every byte into
# events, and `resize_terminal` once it has drawn the new size. Coder is the
# target because it draws nothing while idle: a frame that came along anyway
# cannot hide input that was not drawn yet.
# ---------------------------------------------------------------------------


def coder_the_first_reply_sees_the_first_frame(app: Client) -> None:
    """The first request is answered after the first frame, focus and all.
    Regression: the frame drawn before the loop skipped auto-focus, so a
    request in the loop's first pass found nothing focused, and keys sent
    then went nowhere."""
    assert_true(app.focus().node_id is not None, "nothing was focused when the first request was answered")
    assert_true("> " in app.text(), "the first frame should show the prompt")


def _type_and_check_each_key(app: Client, type_key: Callable[[str], None]) -> None:
    typed = ""
    for key in "harness contract":
        type_key(key)
        typed += key
        assert_true(f"> {typed}" in app.text(),
                    f"the reply after typing {key!r} did not show it: {app.text()!r}")


def coder_socket_input_is_drawn_before_the_next_reply(app: Client) -> None:
    _type_and_check_each_key(app, app.send_text)


def coder_terminal_input_is_drawn_before_the_next_reply(app: Client) -> None:
    _type_and_check_each_key(app, lambda key: app.write_raw(key.encode()))
    app.paste(" pasted")
    assert_true("> harness contract pasted" in app.text(),
                f"the reply after a paste did not show it: {app.text()!r}")


def coder_a_resize_redraws_at_the_new_size(app: Client) -> None:
    """A terminal resize reaches an idle app and it redraws at the new
    size."""
    app.resize_terminal(100, 30)
    frame = app.cells()
    assert_true((frame.width, frame.height) == (100, 30),
                f"after a resize to 100x30 the frame is {frame.width}x{frame.height}")


def coder_sigterm_during_an_unfinished_paste_quits_at_once(app: Client) -> None:
    """A terminating signal quits the app while a bracketed paste waits for
    its end. Regression: the parser gives a paste's end 3s to arrive, and
    the signal's wake was not among what its reads watched, so the quit
    waited them out."""
    import signal

    if app.sanitizer == "thread":
        raise CaseSkipped("Thread Sanitizer runs a signal's handler only once the thread it reached "
                          "calls into its runtime, and an idle app's threads sleep in the kernel")
    app.write_raw(b"\x1b[200~half a paste", unfinished=True)
    # Not a settle: the parser has to be inside the paste when the signal
    # comes, and nothing it does there can be observed.
    time.sleep(0.3)
    app.expected_exit_signal = signal.SIGTERM
    os.kill(app.pid, signal.SIGTERM)
    assert_true(app.wait_for_exit(1.0) is not None, "the app was still running 1s after SIGTERM")


def storybook_a_hung_up_terminal_quits_the_app(app: Client) -> None:
    """Closing the terminal — its window, its SSH connection — quits the app
    through its teardown, which the runner checks, and ends it by SIGHUP.
    Regression: the input thread spun a core on the hung-up terminal, and the
    app ran on for as long as nobody killed it."""
    import signal
    app.expected_exit_signal = signal.SIGHUP
    app.hang_up()
    if app.wait_for_exit(5.0) is None:
        raise CaseFailed("the app outlived its terminal")


def harness_objects_to_an_unannounced_crash(app: Client) -> None:
    """The runner fails a case whose app crashed, even when every assertion
    passed. Regression: a crash under a passing case went unreported, so a
    race that killed the app one run in three looked green the other two."""
    app.crash()
    if app.wait_for_exit(20.0) is None:
        raise CaseFailed("the app outlived its crash")


def harness_objects_to_a_terminal_left_dirty(app: Client) -> None:
    """The runner fails a case whose app left the terminal in a mode it
    turned on. SIGKILL cannot be caught, so nothing restores it."""
    import os
    import signal

    os.kill(app.pid, signal.SIGKILL)
    if app.wait_for_exit(20.0) is None:
        raise CaseFailed("the app outlived SIGKILL")


def coder_bash_card_caps_and_cuts_output(app: Client) -> None:
    """A Bash result shows at most ten lines and says how many it held back;
    a line wider than the card ends in `…`. Regression: the transcript's
    scrollbar was painted over the content's last column, so the ellipsis a
    correctly truncated line ends on was erased and the line read as cut off
    mid-word."""
    text = _coder_scroll_until(app, CODER_LATEST_ENTRY, "pending Bash card")
    rows = text.splitlines()
    assert_true("… (4 lines hidden)" in text, "expected the hidden-line count")
    long_row = next((row for row in rows if "note: previousBuffer" in row), None)
    assert_true(long_row is not None, "expected the long diagnostic line")
    assert_true("…" in long_row, f"long line lost its ellipsis: {long_row.rstrip()!r}")


# ---------------------------------------------------------------------------
# The single-purpose examples
#
# Navigation, Settings and AsyncState each exist to put one framework
# behaviour in front of a real terminal: the whole stack under test, input
# parser to renderer, where a graph test sees only part of it.
# ---------------------------------------------------------------------------


def navigation_pop_restores_focus_to_the_pushing_link(app: Client) -> None:
    """Enter on a NavigationLink pushes its screen, the pushed screen keeps
    Tab to itself, and Esc pops back with focus on the link that pushed, not
    the top of the list."""
    screen = app.text()
    assert_true("Account" in screen and "Home" in screen,
                "the root screen did not render (no Account row or Home title)")
    # Focus starts on the first link; from the second, a pop that lands on
    # the top of the list is told apart from one that restores.
    app.tab()
    pushing = app.focus().node_id

    app.send_key("enter")
    assert_true(app.contains("Inside Network"), "Enter on a link did not push its destination")
    for _ in range(4):
        app.tab()
        assert_true(not app.contains("Choose a destination"), "Tab escaped the pushed screen to the root")

    app.send_key("escape")
    assert_true(not app.contains("Inside Network"), "Esc did not pop the pushed screen")
    restored = app.focus().node_id
    assert_true(restored == pushing,
                f"the pop did not restore focus to the pushing link (wanted {pushing!r}, got {restored!r})")

    # Settings, one Tab on, is reached through navigation and still lays out
    # its Form there.
    app.tab()
    app.send_key("enter")
    assert_true(app.contains("APPEARANCE"), "Settings is not reachable through navigation")


def _settings_model(app: Client) -> str:
    """The `theme=… density=…` line Settings echoes from its model, which
    proves a binding committed rather than that a control repainted."""
    return next((line.strip() for line in app.text().splitlines() if "theme=" in line), "")


def settings_pickers_commit_and_abandon(app: Client) -> None:
    """A segmented picker commits as the arrows move; a dropdown opens on
    Enter, commits the highlighted option on Enter and abandons it on Esc.
    The dropdown matters most: opening it adds nodes to the tree, so a stale
    focus index or a missed render sends the next key to the wrong
    handler, which a graph test cannot see."""
    screen = app.text()
    for expected in ("Settings", "Theme", "Density", "Telemetry", "Editor"):
        assert_true(expected in screen, f"the settings screen did not render (missing {expected!r})")

    # The segmented picker is the first focusable, focused at boot.
    model = _settings_model(app)
    assert_true("theme=dark" in model, f"unexpected initial model: {model!r}")
    app.send_key("right")
    model = _settings_model(app)
    assert_true("theme=auto" in model, f"segmented Right did not commit the next option: {model!r}")
    app.send_key("left")
    model = _settings_model(app)
    assert_true("theme=dark" in model, f"segmented Left did not commit the previous option: {model!r}")

    app.tab()
    assert_true(not app.contains("Comfortable"), "the dropdown was expanded before it was opened")
    app.send_key("enter")
    assert_true(app.contains("Comfortable"), "Enter did not open the dropdown")
    # The second key must reach the open list, which exists only in a tree
    # built after the first.
    app.send_key("down")
    app.send_key("enter")
    model = _settings_model(app)
    assert_true("density=comfortable" in model, f"dropdown Enter did not commit the highlighted option: {model!r}")

    app.send_key("enter")
    assert_true(app.contains("Compact"), "Enter did not reopen the dropdown")
    app.send_key("up")
    app.send_key("escape")
    model = _settings_model(app)
    assert_true("density=comfortable" in model, f"Esc committed the highlighted option: {model!r}")


def demo_a_modal_keeps_focus_until_dismissed(app: Client) -> None:
    """Presenting the help modal moves focus into it, Tab never leaves it,
    and dismissing it hands the background focus back. Demo, not
    Storybook: `.modal` centres on the screen, and inside a Storybook page,
    a ScrollView's buffer, it would centre on that clipped buffer."""
    outside = app.focus().node_id
    app.send_text("h")
    assert_true(app.contains("Keyboard Shortcuts"), "h did not present the help modal")
    inside = app.focus().node_id
    assert_true(inside != outside, f"presenting did not move focus into the dialog (still {outside!r})")

    # The modal holds one focusable, [ Close ], so every Tab re-selects it.
    for press in range(1, 9):
        app.tab()
        landed = app.focus().node_id
        assert_true(landed == inside, f"Tab #{press} left [ Close ] for {landed!r}")

    app.send_key("enter")
    assert_true(not app.contains("Keyboard Shortcuts"), "Enter on [ Close ] did not dismiss the dialog")
    app.tab()
    assert_true(app.focus().node_id is not None, "focus did not return to the background")


# The form's first and last labelled rows, and the section header above the
# first. Scrolling to the focused row brings back the row, not the header,
# so the header is checked only at rest.
FORM_FIRST_SECTION = "APPEARANCE"
FORM_FIRST_ROW = "Theme"
FORM_LAST_ROW = "History depth"
# Tab visits eight controls before it leaves the preview; bounded so a form
# that never scrolls fails rather than spins.
FORM_MAX_TABS = 12


def _form_window(app: Client) -> tuple[int, list[str], str]:
    """The preview window's first screen row, its rows, and their text."""
    first_row, rows = app.boxed_rows("Preview")
    return first_row, rows, "\n".join(rows)


def _form_label_columns(rows: list[str]) -> set[int]:
    """The column of each Toggle's checkbox: the form's label column."""
    return {row.index("[") for row in rows if "[" in row}


def storybook_form_scrolls_to_the_focused_control(app: Client) -> None:
    """Tab through a Form taller than its window scrolls each control into
    view, keeps one label column, and Shift-Tab scrolls back. Rows below
    the fold used to stay focusable while out of sight."""
    app.goto_page("Form")
    _, rows, text = _form_window(app)
    assert_true(FORM_FIRST_SECTION in text and FORM_FIRST_ROW in text,
                "the Form page did not render its first section")
    assert_true(FORM_LAST_ROW not in text, "the form fits its window, so it cannot prove it scrolls")
    columns = _form_label_columns(rows)

    for _ in range(FORM_MAX_TABS):
        app.tab()
        first_row, rows, text = _form_window(app)
        if FORM_LAST_ROW in text:
            break
    else:
        raise CaseFailed(f"tabbing through the form never brought {FORM_LAST_ROW!r} into view")
    assert_true(FORM_FIRST_ROW not in text, "the viewport never moved")

    focus_y = app.focus().rect[1]
    assert_true(first_row <= focus_y < first_row + len(rows),
                f"the focused control sits outside the preview window "
                f"(y={focus_y}, window rows {first_row}..{first_row + len(rows) - 1})")
    # Before and after together: rows that disagree, or a column that moved
    # as the rows scrolled past.
    columns |= _form_label_columns(rows)
    assert_true(len(columns) == 1, f"the controls do not share one label column: {sorted(columns)}")

    for _ in range(FORM_MAX_TABS):
        app.tab(reverse=True)
        if FORM_FIRST_ROW in _form_window(app)[2]:
            return
    raise CaseFailed("Shift-Tab back through the form never returned to the first section")


# Several of AsyncState's 60ms ticks.
ASYNC_OBSERVE_SECONDS = 1.0


def _async_count(app: Client) -> Optional[int]:
    match = re.search(r"count=(\d+)", app.text())
    return int(match[1]) if match else None


def async_state_is_drawn_with_no_input(app: Client) -> None:
    """A `Task` that changes observed state gets its frame with nothing else
    happening, in either render mode: `.onDemand`'s idle wait has to be
    woken by it. AsyncState declares no timer; Storybook's would set
    `needsRender` every tick and hide the defect. One look after a quiet
    interval, not `wait_until`: each query wakes the app, and an app that
    slept through the change would draw it for the poll."""
    first = _async_count(app)
    assert_true(first is not None, "the app did not render its counter")
    time.sleep(ASYNC_OBSERVE_SECONDS)
    second = _async_count(app)
    assert_true(second is not None, f"the counter vanished after {ASYNC_OBSERVE_SECONDS}s")
    assert_true(second != first,
                f"the count stayed at {first} for {ASYNC_OBSERVE_SECONDS}s with no input: "
                f"the task marks the graph dirty and the loop drops the frame")


def storybook_a_disabled_socket_is_never_opened(app: Client) -> None:
    """`enabled = false` under `[socket]` in the project's config keeps the
    app from opening its control socket, and the app runs as usual. The
    runtime decides on the socket before its first frame, so once a frame
    is on the terminal there is nothing left to wait for."""
    assert_true(app.wait_until(lambda client: b"VStack" in client.pty_output(), timeout=BOOT_TIMEOUT),
                "the app drew no frame")
    remote = Path(app.diag_dir) / "remote"
    sockets = sorted(str(path) for path in remote.glob("*.sock")) if remote.exists() else []
    assert_true(not sockets, f"a socket was opened despite enabled = false: {sockets}")


# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------


CASES: list[SmokeCase] = [
    SmokeCase("storybook.auto_focus_on_boot", "Storybook", storybook_auto_focus_on_boot),
    SmokeCase("navigation.idle_costs_nothing", "Navigation", idle_costs_nothing),
    SmokeCase("coder.idle_costs_nothing", "Coder", idle_costs_nothing),
    SmokeCase("navigation.an_idle_app_acts_on_remote_commands", "Navigation",
              navigation_an_idle_app_acts_on_remote_commands),
    SmokeCase("navigation.invoke_action_quits_an_idle_app", "Navigation",
              navigation_invoke_action_quits_an_idle_app),
    SmokeCase("coder.a_resize_redraws_at_the_new_size", "Coder", coder_a_resize_redraws_at_the_new_size),
    SmokeCase("coder.sigterm_during_an_unfinished_paste_quits_at_once", "Coder",
              coder_sigterm_during_an_unfinished_paste_quits_at_once),
    SmokeCase("coder.the_first_reply_sees_the_first_frame", "Coder",
              coder_the_first_reply_sees_the_first_frame),
    SmokeCase("coder.socket_input_is_drawn_before_the_next_reply", "Coder",
              coder_socket_input_is_drawn_before_the_next_reply),
    SmokeCase("coder.terminal_input_is_drawn_before_the_next_reply", "Coder",
              coder_terminal_input_is_drawn_before_the_next_reply),
    SmokeCase("storybook.arrow_navigation", "Storybook", storybook_arrow_navigation),
    SmokeCase("storybook.sidebar_order_matches_navigation", "Storybook", storybook_sidebar_order_matches_navigation),
    SmokeCase("storybook.a_client_that_hangs_up_leaves_the_app_running", "Storybook",
              storybook_a_client_that_hangs_up_leaves_the_app_running),
    SmokeCase("storybook.tab_crosses_to_preview", "Storybook", storybook_tab_crosses_to_preview),
    SmokeCase("storybook.focusable_rows_read_their_focus", "Storybook", storybook_focusable_rows_read_their_focus),
    SmokeCase("storybook.theme_switch_reaches_unchanged_views", "Storybook", storybook_theme_switch_reaches_unchanged_views),
    SmokeCase("storybook.scroll_position_binds_both_ways", "Storybook", storybook_scroll_position_binds_both_ways),
    SmokeCase("storybook.scroll_target_visibility_follows_the_scroll", "Storybook",
              storybook_scroll_target_visibility_follows_the_scroll),
    SmokeCase("storybook.sidebar_scrolls_away_from_the_selection", "Storybook", storybook_sidebar_scrolls_away_from_the_selection),
    SmokeCase("storybook.textinput_cursor_follows_focus", "Storybook", storybook_textinput_cursor_follows_focus),
    SmokeCase("storybook.anchored_scroll_follows_its_tail", "Storybook", storybook_anchored_scroll_follows_its_tail),
    SmokeCase("storybook.button_arrows_traverse_siblings", "Storybook", storybook_button_arrows_traverse_siblings),
    SmokeCase("storybook.button_click_updates_message", "Storybook", storybook_button_click_updates_message),
    SmokeCase("storybook.toggle_alternates_state", "Storybook", storybook_toggle_alternates_state),
    SmokeCase("storybook.textinput_validation_colors", "Storybook", storybook_textinput_validation_colors),
    SmokeCase("storybook.promptinput_long_input_soft_wraps", "Storybook", storybook_promptinput_long_input_soft_wraps),
    SmokeCase("storybook.promptinput_submit_clears", "Storybook", storybook_promptinput_submit_clears),
    SmokeCase("storybook.prompt_prefix_follows_focus", "Storybook", storybook_prompt_prefix_follows_focus),
    SmokeCase("storybook.list_selection_advances", "Storybook", storybook_list_selection_advances),
    SmokeCase("storybook.tabview_cycles_tabs", "Storybook", storybook_tabview_cycles_tabs),
    SmokeCase("storybook.treeview_expand_collapse", "Storybook", storybook_treeview_expand_collapse),
    SmokeCase("storybook.sidebar_autoscrolls_with_selection", "Storybook", storybook_sidebar_autoscrolls_with_selection),
    SmokeCase("storybook.textarea_accepts_input", "Storybook", storybook_textarea_accepts_input),
    SmokeCase("storybook.textinput_paste_inserts", "Storybook", storybook_textinput_paste_inserts),
    SmokeCase("storybook.textarea_paste_splits_lines", "Storybook", storybook_textarea_paste_splits_lines),
    SmokeCase("storybook.promptinput_paste_creates_logical_rows", "Storybook", storybook_promptinput_paste_creates_logical_rows),
    SmokeCase("storybook.large_paste_does_not_corrupt_ui", "Storybook", storybook_large_paste_does_not_corrupt_ui),
    SmokeCase("storybook.vstack_renders_three_rows", "Storybook", storybook_vstack_renders_three_rows),
    SmokeCase("storybook.hstack_renders_horizontal", "Storybook", storybook_hstack_renders_horizontal),
    SmokeCase("storybook.divider_renders_rule", "Storybook", storybook_divider_renders_rule),
    SmokeCase("storybook.table_renders_header_and_rows", "Storybook", storybook_table_renders_header_and_rows),
    SmokeCase("storybook.diffview_marks_changes", "Storybook", storybook_diffview_marks_changes),
    SmokeCase("storybook.hunkdiffview_navigates_lines", "Storybook", storybook_hunkdiffview_navigates_lines),
    SmokeCase("storybook.progressbar_renders_all_values", "Storybook", storybook_progressbar_renders_all_values),
    SmokeCase("storybook.statusbar_sections_render", "Storybook", storybook_statusbar_sections_render),
    SmokeCase("storybook.barchart_renders_bars", "Storybook", storybook_barchart_renders_bars),
    SmokeCase("storybook.zstack_overlays_label", "Storybook", storybook_zstack_overlays_label),
    SmokeCase("storybook.spacer_pushes_edges", "Storybook", storybook_spacer_pushes_edges),
    SmokeCase("storybook.scrollview_initial_viewport", "Storybook", storybook_scrollview_initial_viewport),
    SmokeCase("storybook.scrollview_shows_thumb_scrollbar", "Storybook", storybook_scrollview_shows_thumb_scrollbar),
    SmokeCase("storybook.disabled_skips_focus", "Storybook", storybook_disabled_skips_focus),
    SmokeCase("storybook.actioncontext_ctrl_r_enters_resize_mode", "Storybook", storybook_actioncontext_ctrl_r_enters_resize_mode),
    SmokeCase("storybook.textinput_cursor_mid_buffer_edit", "Storybook", storybook_textinput_cursor_mid_buffer_edit),
    SmokeCase("storybook.textinput_boundary_emits_under_modal", "Storybook", storybook_textinput_boundary_emits_under_modal),
    SmokeCase("storybook.textinput_boundary_rings_the_bell", "Storybook", storybook_textinput_boundary_rings_the_bell),
    SmokeCase("storybook.textarea_wall_flashes_the_cursor", "Storybook", storybook_textarea_wall_flashes_the_cursor),
    SmokeCase("storybook.a_hung_up_terminal_quits_the_app", "Storybook", storybook_a_hung_up_terminal_quits_the_app),
    SmokeCase("storybook.scrollview_tab_focuses_and_scrolls", "Storybook", storybook_scrollview_tab_focuses_and_scrolls),
    SmokeCase("storybook.geometryreader_reports_size", "Storybook", storybook_geometryreader_reports_size),
    SmokeCase("storybook.text_styles_render", "Storybook", storybook_text_styles_render),
    SmokeCase("storybook.forEach_renders_all_items", "Storybook", storybook_forEach_renders_all_items),
    SmokeCase("storybook.sparkline_renders_line", "Storybook", storybook_sparkline_renders_line),
    SmokeCase("storybook.heatmap_renders_grid", "Storybook", storybook_heatmap_renders_grid),
    SmokeCase("storybook.braillecanvas_renders_curve", "Storybook", storybook_braillecanvas_renders_curve),
    SmokeCase("storybook.dotmatrixtext_renders_HELLO", "Storybook", storybook_dotmatrixtext_renders_HELLO),
    SmokeCase("storybook.morseticker_renders_sos", "Storybook", storybook_morseticker_renders_sos),
    SmokeCase("storybook.foreground_renders_colored_words", "Storybook", storybook_foreground_renders_colored_words),
    SmokeCase("storybook.bold_distinguishes_styles", "Storybook", storybook_bold_distinguishes_styles),
    SmokeCase("storybook.border_wraps_text", "Storybook", storybook_border_wraps_text),
    SmokeCase("storybook.padding_wraps_text", "Storybook", storybook_padding_wraps_text),
    SmokeCase("storybook.frame_sizes_bordered_box", "Storybook", storybook_frame_sizes_bordered_box),
    SmokeCase("storybook.flexible_distributes_remainder", "Storybook", storybook_flexible_distributes_remainder),
    SmokeCase("storybook.focusable_joins_tab_order", "Storybook", storybook_focusable_joins_tab_order),
    SmokeCase("storybook.onhover_callback_fires_on_enter_leave", "Storybook", storybook_onhover_callback_fires_on_enter_leave),
    SmokeCase("storybook.mousefocuspolicy_renders_subtrees", "Storybook", storybook_mousefocuspolicy_renders_subtrees),
    SmokeCase("storybook.bufferview_blits_demo_cells", "Storybook", storybook_bufferview_blits_demo_cells),
    SmokeCase("storybook.walks_past_promptinput", "Storybook", storybook_walks_past_promptinput),
    # Mouse + layout-stability regressions reported 2026-04-25
    SmokeCase("storybook.layout_stable_under_mouse_hover", "Storybook", storybook_layout_stable_under_mouse_hover),
    SmokeCase("storybook.layout_stable_under_arrow_repeat", "Storybook", storybook_layout_stable_under_arrow_repeat),
    SmokeCase("storybook.treeview_click_expand", "Storybook", storybook_treeview_click_expand),
    SmokeCase("storybook.treeview_keyboard_expand_collapse", "Storybook", storybook_treeview_keyboard_expand_collapse),
    SmokeCase("storybook.mouse_click_on_sidebar_navigates", "Storybook", storybook_mouse_click_on_sidebar_navigates),
    SmokeCase("storybook.mouse_wheel_routes_to_hover_target", "Storybook", storybook_mouse_wheel_routes_to_hover_target),
    SmokeCase("storybook.mouse_wheel_scrolls_hovered_scrollview", "Storybook", storybook_mouse_wheel_scrolls_hovered_scrollview),
    SmokeCase("storybook.mouse_wheel_scrolls_hovered_sidebar", "Storybook", storybook_mouse_wheel_scrolls_hovered_sidebar),
    SmokeCase("storybook.mouse_click_locks_until_next_click", "Storybook", storybook_mouse_click_locks_until_next_click),
    SmokeCase("storybook.actions_modifier_fires_via_chord", "Storybook", storybook_actions_modifier_fires_via_chord),
    SmokeCase("storybook.list_actions_returns_quit_default", "Storybook", storybook_list_actions_returns_quit_default),
    SmokeCase("demo.invoke_action_quits", "Demo", storybook_invoke_action_quits_app),
    SmokeCase("demo.renders", "Demo", demo_app_renders),
    SmokeCase("gitclient.renders", "GitClient", gitclient_renders),
    SmokeCase("gitclient.tab_focuses_diff", "GitClient", gitclient_tab_focuses_diff),
    SmokeCase("gitclient.s_stages_hunk", "GitClient", gitclient_s_stages_hunk),
    SmokeCase("gitclient.commit_clears_staged", "GitClient", gitclient_commit_clears_staged),
    SmokeCase("gitclient.q_quits", "GitClient", gitclient_q_quits),
    SmokeCase("chat.renders", "Chat", chat_renders),
    SmokeCase("chat.send_message_appends", "Chat", chat_send_message_appends),
    SmokeCase("chat.bot_reply_appears", "Chat", chat_bot_reply_appears),
    SmokeCase("chat.scroll_pins_to_bottom", "Chat", chat_scroll_pins_to_bottom),
    SmokeCase("chat.q_in_empty_prompt_quits", "Chat", chat_q_in_empty_prompt_quits),
    SmokeCase("navigation.pop_restores_focus_to_the_pushing_link", "Navigation",
              navigation_pop_restores_focus_to_the_pushing_link),
    SmokeCase("settings.pickers_commit_and_abandon", "Settings", settings_pickers_commit_and_abandon),
    SmokeCase("demo.a_modal_keeps_focus_until_dismissed", "Demo", demo_a_modal_keeps_focus_until_dismissed),
    SmokeCase("storybook.form_scrolls_to_the_focused_control", "Storybook",
              storybook_form_scrolls_to_the_focused_control),
    SmokeCase("asyncstate.capped_is_drawn_with_no_input", "AsyncState",
              async_state_is_drawn_with_no_input),
    SmokeCase("asyncstate.ondemand_is_drawn_with_no_input", "AsyncState",
              async_state_is_drawn_with_no_input, env=(("TUI_RENDER_MODE", "ondemand"),)),
    SmokeCase("storybook.a_disabled_socket_is_never_opened", "Storybook",
              storybook_a_disabled_socket_is_never_opened, connects=False,
              project_files=((".terminalui/terminalui.toml", "[socket]\nenabled = false\n"),)),
    SmokeCase("coder.renders", "Coder", coder_renders),
    SmokeCase("coder.typing_reaches_the_prompt", "Coder", coder_typing_reaches_the_prompt),
    SmokeCase("coder.readline_keys_edit_the_draft", "Coder", coder_readline_keys_edit_the_draft),
    SmokeCase("coder.reads_the_users_keymap", "Coder", coder_reads_the_users_keymap,
              config_files=(("coder/keys.toml", '[text]\n"ctrl+o" = "deleteToLineEnd"\n"ctrl+k" = []\n'),)),
    SmokeCase("coder.opens_on_the_latest_entry", "Coder", coder_opens_on_the_latest_entry),
    SmokeCase("coder.enter_sends_the_draft", "Coder", coder_enter_sends_the_draft),
    SmokeCase("coder.edit_card_shows_diff", "Coder", coder_edit_card_shows_diff),
    SmokeCase("coder.transcript_diff_takes_no_keys", "Coder", coder_transcript_diff_takes_no_keys),
    SmokeCase("coder.reply_keeps_heading_markers_and_chips_code", "Coder", coder_reply_keeps_heading_markers_and_chips_code),
    SmokeCase("coder.read_card_shows_numbered_excerpt", "Coder", coder_read_card_shows_numbered_excerpt),
    SmokeCase("coder.bash_card_caps_and_cuts_output", "Coder", coder_bash_card_caps_and_cuts_output),
    SmokeCase("coder.tab_reaches_the_transcript", "Coder", coder_tab_reaches_the_transcript),
    SmokeCase("coder.shift_arrows_step_the_selection", "Coder", coder_shift_arrows_step_the_selection),
    SmokeCase("coder.space_expands_a_capped_result", "Coder", coder_space_expands_a_capped_result),
    SmokeCase("coder.click_expands_a_capped_result", "Coder", coder_click_expands_a_capped_result),
    SmokeCase("coder.scrolling_keeps_the_selection_in_sight", "Coder",
              coder_scrolling_keeps_the_selection_in_sight),
    SmokeCase("coder.wheel_burst_keeps_running", "Coder", coder_wheel_burst_keeps_running),
    SmokeCase("coder.crash_restores_the_terminal", "Coder", coder_crash_restores_the_terminal),
    # A sanitized build reports the SEGV itself and then aborts, so the
    # phrases name the signal without naming how the parent saw the death.
    SmokeCase("harness.objects_to_an_unannounced_crash", "Coder",
              harness_objects_to_an_unannounced_crash,
              expected_objections=("crashed on", "SEGV")),
    SmokeCase("harness.objects_to_a_terminal_left_dirty", "Coder",
              harness_objects_to_a_terminal_left_dirty,
              expected_objections=("crashed on SIGKILL", "left DEC mode 1049 on")),
]


def _usable_cpus() -> int:
    """The CPUs this process may run on — a container's share, not the host's."""
    if hasattr(os, "process_cpu_count"):
        return os.process_cpu_count() or 1
    if hasattr(os, "sched_getaffinity"):
        return len(os.sched_getaffinity(0))
    return os.cpu_count() or 1


def _tick(result: CaseResult) -> str:
    if result.skipped:
        return "–"
    return "✓" if result.ok else "✗"


def _execute(case: SmokeCase, build_dir: Optional[str]) -> CaseResult:
    # Printed when a worker takes the case, so a run cut off by a timeout
    # shows which cases had started and not finished.
    print(f"→ {case.name}", flush=True)
    result = case.execute(build_dir=build_dir)
    print(f"{_tick(result)} {case.name}", flush=True)
    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # Optional build dir so the same suite can drive a Linux build from a
    # separate scratch path (tools/scripts/linux_harness.sh).
    parser.add_argument("build_dir", nargs="?", default=None)
    # Half the CPUs: every case is an app under a PTY plus its client, and a
    # timing-sensitive case — an idle app's CPU, a burst of input — must not
    # be starved by its neighbours. Each app owns its own data dir and socket.
    parser.add_argument("--jobs", type=int, default=_usable_cpus() // 2,
                        help="cases run at once (default: half the CPUs; 1 runs them in turn)")
    args = parser.parse_args(argv)

    pool = ThreadPoolExecutor(max_workers=max(1, args.jobs))
    try:
        futures = [pool.submit(_execute, case, args.build_dir) for case in CASES]
        results = [future.result() for future in futures]
    except KeyboardInterrupt:
        # Without this, every queued case still ran — and spawned its app —
        # before the interrupt took effect.
        pool.shutdown(wait=False, cancel_futures=True)
        raise
    pool.shutdown()

    failed = [r for r in results if not r.ok]
    skipped = [r for r in results if r.skipped]
    if failed or skipped:
        print()
    for result in skipped + failed:
        print(f"  {_tick(result)} {result.name:<40} {result.detail}")

    print()
    passed = len(results) - len(failed) - len(skipped)
    print(f"{passed}/{len(results)} cases passed" + (f", {len(skipped)} skipped" if skipped else ""))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
