#!/usr/bin/env python3
"""The README's demo walk must land on the Storybook pages it names.

``assets/demo.tape`` walks the Storybook sidebar by counted arrow presses,
and a page added before a landmark shifts every pause after it: the GIF
then dwells on whatever page the count reaches, and nothing fails. Each
pause in the tape names its page with a ``# page: <PageID case>`` line;
this replays the presses over ``PageID``'s declaration order, which is the
order the arrows move through, and checks every landing.

Run::

    python3 tools/tests/test_demo_tape.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Callable

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools"))

from terminalui.cases import run_cases  # noqa: E402

DEMO_TAPE = REPO_ROOT / "assets" / "demo.tape"
STORYBOOK_PAGES = REPO_ROOT / "Examples" / "Storybook" / "StorybookPage.swift"

# vhs: `Down`, `Down 8`, `Down@250ms 8` — the count defaults to one.
MOVE = re.compile(r"^(Up|Down)(?:@\S+)?(?:\s+(\d+))?\s*$")
LANDING = re.compile(r"^#\s*page:\s*(\w+)\s*$")


def page_order(swift: str) -> list[str]:
    """The cases of ``PageID``, in declaration order."""
    body = swift.split("enum PageID", 1)[1]
    cases: list[str] = []
    for line in body.splitlines()[1:]:
        stripped = line.strip()
        if stripped.startswith("var ") or stripped.startswith("static "):
            break
        if stripped.startswith("case "):
            cases += [name.strip() for name in stripped.removeprefix("case ").split(",")]
    return cases


def walk_problems(tape: str, pages: list[str]) -> list[str]:
    """Every landing the presses miss, and every run of presses that names
    no landing at all."""
    problems: list[str] = []
    index = 0
    unnamed_move: int | None = None
    for number, line in enumerate(tape.splitlines(), start=1):
        stripped = line.strip()
        if move := MOVE.match(stripped):
            if unnamed_move is not None:
                problems.append(f"line {unnamed_move}: presses with no `# page:` after them")
            step = int(move.group(2) or 1)
            index += step if move.group(1) == "Down" else -step
            unnamed_move = number
        elif landing := LANDING.match(stripped):
            named = landing.group(1)
            if named not in pages:
                problems.append(f"line {number}: no page `{named}`")
            elif not 0 <= index < len(pages):
                problems.append(f"line {number}: the presses run off the sidebar")
            elif pages[index] != named:
                problems.append(f"line {number}: lands on `{pages[index]}`, not `{named}`")
            unnamed_move = None
    if unnamed_move is not None:
        problems.append(f"line {unnamed_move}: presses with no `# page:` after them")
    return problems


def the_demo_lands_on_the_pages_it_names() -> None:
    pages = page_order(STORYBOOK_PAGES.read_text())
    problems = walk_problems(DEMO_TAPE.read_text(), pages)
    assert not problems, "\n".join(problems)


def the_page_order_is_read_from_the_enum() -> None:
    swift = """
    enum PageID: CaseIterable {
        // Layout
        case vstack, hstack
        // Input
        case button
        var info: PageInfo {
            switch self {
            case .vstack: return x
    """
    assert page_order(swift) == ["vstack", "hstack", "button"], page_order(swift)


def a_wrong_count_is_caught() -> None:
    pages = ["a", "b", "c", "d"]
    assert walk_problems("Down 2\n# page: c\nUp\n# page: b\n", pages) == []
    assert walk_problems("Down@250ms 2\n# page: d\n", pages) == ["line 2: lands on `c`, not `d`"]
    assert walk_problems("Down 9\n# page: d\n", pages) == ["line 2: the presses run off the sidebar"]
    assert walk_problems("Down\n# page: z\n", pages) == ["line 2: no page `z`"]


def presses_must_name_where_they_land() -> None:
    pages = ["a", "b", "c"]
    assert walk_problems("Down\nSleep 1s\nDown\n# page: c\n", pages) == \
        ["line 1: presses with no `# page:` after them"]
    assert walk_problems("Down\n", pages) == ["line 1: presses with no `# page:` after them"]


CASES: list[tuple[str, Callable[[], None]]] = [
    ("the demo lands on the pages it names", the_demo_lands_on_the_pages_it_names),
    ("the page order is read from the enum", the_page_order_is_read_from_the_enum),
    ("a wrong count is caught", a_wrong_count_is_caught),
    ("presses must name where they land", presses_must_name_where_they_land),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
