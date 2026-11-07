"""What the harness knows about the Storybook example's page order.

The sidebar's arrows move through ``PageID``'s cases in declaration order
(``Examples/Storybook/StorybookPage.swift`` says so where it declares
them), so a script that walks the pages by counted presses reads them from
there rather than keeping a list that drifts.
"""

from __future__ import annotations

from pathlib import Path

STORYBOOK_PAGES = Path(__file__).resolve().parents[2] / "Examples" / "Storybook" / "StorybookPage.swift"


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


def pages() -> list[str]:
    """The Storybook's pages, in the order its arrows reach them."""
    return page_order(STORYBOOK_PAGES.read_text())
