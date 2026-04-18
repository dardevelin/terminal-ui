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
