#!/usr/bin/env python3
"""Walk every Storybook page and assert the preview renders something.

Complements ``storybook_smoke.py``: smoke pins specific behaviours that have
regressed before, the walk asserts the *breadth* invariant — every page in the
catalog still renders. It catches the "new page added, never rendered in CI"
class that per-widget cases miss by construction.

Pages are discovered at runtime, never hardcoded. A hardcoded list silently
stops covering the catalog the moment a page is added: the list carried 34
entries against 48 real pages, and everything past the drift point went
unwalked. Discovery lives on ``Client.storybook_pages`` so this script and the
smoke suite share one definition of what the catalog contains.

Usage::

    swift build                                 # build Storybook + swtui
    python3 tools/scripts/storybook_walk.py     # run the walk

Runs against Linux binaries too — see ``tools/scripts/linux_harness.sh``.

Exits 0 on success, non-zero on any failure. Prints one line per page; full
snapshots land under ``/tmp/terminalui_walk/`` for post-mortem inspection.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Make the package importable regardless of cwd.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import Client  # noqa: E402
from terminalui.runner import spawn_and_connect  # noqa: E402


# Runaway guard only — enumeration stops when the title stops advancing.
MAX_PAGES = 200

# A page whose preview holds fewer than this many non-blank characters has
# almost certainly failed to render. Deliberately low: the walk's job is to
# catch blank/crashed pages, and per-page content assertions belong in
# storybook_smoke.py where they can be specific. False positives here would
# train readers to ignore the walk.
MIN_PREVIEW_CHARS = 3


def walk(app: Client, out_dir: Path) -> list[tuple[str, str]]:
    """Evaluate every page, returning ``(page, detail)`` pairs where an empty
    ``detail`` means the page rendered fine.

    Single pass: each page is snapshotted and checked at the moment navigation
    lands on it. Enumerating first and re-navigating afterwards would re-walk
    the whole catalog — and leave the cursor on the last page, so returning to
    the first would sweep the full list twice over.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    app.wait_for_frame(1, timeout=2.0)

    results: list[tuple[str, str]] = []
    seen: set[str] = set()

    for index in range(MAX_PAGES):
        page = app.storybook_page_title()
        if page in seen:
            break
        seen.add(page)

        (out_dir / f"{index:02d}_{_slug(page)}.txt").write_text(
            app.cells(grid=True).grid()
        )

        detail = _evaluate_page(app)
        results.append((page, detail))
        print(f"  {'✗' if detail else '✓'} {index:02d} {page:<22} {detail or 'ok'}")

        app.send_key("down")
        app.wait_for_frame(1, timeout=0.5)

    _assert_catalog_exhausted(app, [page for page, _ in results])
    return results


def _evaluate_page(app: Client) -> str:
    """Return "" when the page looks fine, else a short explanation.

    Conservative by design — the walk asserts that a page rendered at all, not
    what it rendered. Specific content assertions live in the smoke suite.
    """
    preview = app.preview_text()
    visible = sum(1 for ch in preview if not ch.isspace())
    if visible < MIN_PREVIEW_CHARS:
        return f"preview is blank ({visible} visible chars)"
    return ""


def _assert_catalog_exhausted(app: Client, walked: list[str]) -> None:
    """Fail when the walk stopped with pages still listed in the sidebar.

    "Title stopped changing" conflates *end of catalog* with *this page
    swallowed the Down key* — and a page eating arrow keys is exactly the
    focus regression this walk exists to catch. Without the cross-check it
    would report a short walk, pass every page it did reach, and exit 0.
    """
    missed = [row for row in app.storybook_sidebar_rows() if row not in walked]
    if missed:
        raise RuntimeError(
            f"walk ended after {len(walked)} pages but the sidebar still lists "
            f"unvisited pages {missed!r} — a page is likely swallowing Down"
        )


def _slug(page: str) -> str:
    """Filesystem-safe snapshot name. Modifier pages start with '.', which
    would otherwise produce hidden files that `ls` omits during post-mortem."""
    return page.lstrip(".") or "page"


def main(argv: list[str]) -> int:
    # Optional build dir so the same walk can drive a Linux build from a
    # separate scratch path (tools/scripts/linux_harness.sh). Passed straight
    # through to spawn_and_connect's existing `build_dir` parameter.
    build_dir = argv[0] if argv else None

    out_dir = Path("/tmp/terminalui_walk")
    print(f"spawning Storybook → snapshots at {out_dir}")
    with spawn_and_connect("Storybook", build_dir=build_dir, cols=140, rows=40) as (_, app):
        results = walk(app, out_dir)

    failed = [(page, detail) for page, detail in results if detail]
    print(f"\nwalked {len(results)} pages, {len(failed)} failed")
    for page, detail in failed:
        print(f"  FAIL {page}: {detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
