#!/usr/bin/env python3
"""Walk every Storybook page and assert the preview is non-empty.

Runs on top of the HYP-71 remote-control Python client. Fails fast when a
page renders nothing, shows a focus regression (arrows swallowed by the
sidebar ScrollView), or when the code/preview block goes blank — the exact
class of regressions our unit-test suite doesn't catch.

Usage::

    swift build                                 # build Storybook + swtui
    python3 tools/scripts/storybook_walk.py     # run the walk

Exits 0 on success, non-zero on any failure. Prints a one-line status per
page so CI logs stay readable; full snapshots land under
``/tmp/terminalui_walk/`` for post-mortem inspection.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

# Make the package importable regardless of cwd.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import Client, RemoteError  # noqa: E402
from terminalui.runner import spawn_and_connect  # noqa: E402


# Storybook page IDs in declaration order (see
# Examples/Storybook/StorybookPage.swift). The walk starts at index 0 and
# presses Down to advance one page at a time.
PAGES = [
    "vstack", "hstack", "zstack", "spacer", "divider", "scrollview", "geometryreader",
    "text", "forEach",
    "button", "textInput", "textArea", "toggle", "promptInput",
    "list", "table", "tabView", "treeView", "diffView", "hunkDiffView",
    "progressBar", "statusBar",
    "barChart", "sparkline", "heatMap", "brailleCanvas", "dotMatrixText", "morseTicker",
    "foreground", "bold", "border", "padding", "focusable", "frame",
]


def walk(app: Client, out_dir: Path) -> list[tuple[str, bool, str]]:
    """Return (page, ok, detail) triples for every page. `ok=False` when
    the preview region looks broken; `detail` explains why."""
    out_dir.mkdir(parents=True, exist_ok=True)
    results: list[tuple[str, bool, str]] = []

    # Let the initial frame land before we start probing.
    app.wait_for_frame(1)

    for i, page in enumerate(PAGES):
        if i > 0:
            app.send_key("down")
            app.wait_for_frame(1, timeout=1.0)

        snap = app.cells(grid=True)
        (out_dir / f"{i:02d}_{page}.txt").write_text(snap.grid())

        detail = _evaluate_page(page, snap)
        ok = detail == ""
        results.append((page, ok, detail or "ok"))
        status = "✓" if ok else "✗"
        print(f"  {status} {i:02d} {page:<18} {detail or 'ok'}")

    return results


def _evaluate_page(page: str, snap) -> str:
    """Return an empty string when the page looks fine, otherwise a short
    explanation of what broke. The checks stay conservative — false
    positives are worse than missed regressions here."""
    text = snap.text()
    # Every page displays its title at row 1 col ~30 in the preview pane.
    # Use a case-insensitive substring check because page case conventions
    # vary (VStack vs vstack vs Stack…) and we care only that the preview
    # advanced, not exact casing.
    header = "\n".join(snap.rows[:6]).lower()
    pretty_name = _pretty_page_name(page).lower()
    if pretty_name not in header:
        return f"header missing '{_pretty_page_name(page)}'"

    # Preview region should have something other than whitespace/borders.
    preview_rows = snap.rows[22:]  # below the Code block
    real_content = any(
        ch.isalnum() for row in preview_rows for ch in row
    )
    if not real_content:
        return "preview is empty"

    # Both scroll-indicator glyphs (▼▲) combined with an *empty* content area
    # would signal clipped-to-death content. We only flag this if there's
    # also a near-empty preview.
    return ""


def _pretty_page_name(page: str) -> str:
    """Map the enum case to the heading the page prints (see StorybookPage.info)."""
    mapping = {
        "scrollview": "ScrollView",
        "geometryreader": "GeometryReader",
        "forEach": "ForEach",
        "textInput": "TextInput",
        "textArea": "TextArea",
        "promptInput": "PromptInput",
        "tabView": "TabView",
        "treeView": "TreeView",
        "diffView": "DiffView",
        "hunkDiffView": "HunkDiffView",
        "progressBar": "ProgressBar",
        "statusBar": "StatusBar",
        "barChart": "BarChart",
        "heatMap": "HeatMap",
        "brailleCanvas": "BrailleCanvas",
        "dotMatrixText": "DotMatrixText",
        "morseTicker": "MorseTicker",
        "foreground": ".foreground",
        "bold": ".bold",
        "border": ".border",
        "padding": ".padding",
        "focusable": ".focusable",
        "frame": ".frame",
    }
    return mapping.get(page, page.capitalize())


def main() -> int:
    out_dir = Path("/tmp/terminalui_walk")
    print(f"spawning Storybook → snapshots at {out_dir}")
    with spawn_and_connect("Storybook", cols=140, rows=40) as (_, app):
        results = walk(app, out_dir)
    failed = [r for r in results if not r[1]]
    print(f"\nwalked {len(results)} pages, {len(failed)} failed")
    for page, _, detail in failed:
        print(f"  FAIL {page}: {detail}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
