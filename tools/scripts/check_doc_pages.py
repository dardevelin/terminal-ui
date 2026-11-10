#!/usr/bin/env python3
"""Every page the published documentation has says something.

DocC makes a page for every public symbol, documented or not. Before 1.0,
thousands of them were empty — a title, a declaration, nothing else — and
a doc pass filled them in. Nothing held the line after it: 2.0 added 92 more
of its own, and the site carried some 3,500 pages that only repeated others
(every view listed every modifier again; `!=` alone had 121).

This check builds the documentation exactly as ``.github/workflows/docs.yml``
publishes it — every module the site carries, ``TARGETS`` — and reads each
module's DocC coverage report: it fails on a symbol page
without an abstract, and on any DocC warning (a broken link, an article that
shadows a symbol). Plumbing no reader uses — a view's ``body``, a modifier's
``ModifierType`` — is kept off the site with
``@_documentation(visibility: internal)`` rather than given words for the
sake of the count. The pages left alone are the ones the compiler writes —
a ``Codable`` type's ``init(from:)``, a raw-value enum's ``init(rawValue:)``,
a property wrapper's or macro's ``$`` projection — for which no source line
exists to document.

Run::

    python3 tools/scripts/check_doc_pages.py [--scratch-path .build-docs]

Exit 0 when every page says something, 1 otherwise. Needs network access the
first time: building documentation fetches the DocC plugin.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# The modules the site publishes, in docs.yml's order. A module joins the
# site by joining this list and docs.yml's together.
TARGETS = ("TerminalUI", "TerminalUI3D")
# The options the published site is built with; kept equal to docs.yml's.
# docs.yml also combines the modules into one archive, which changes no
# page; the coverage report is written per module, so this builds them apart.
PUBLISHED_OPTIONS = ["--experimental-skip-synthesized-symbols"]
# Pages the compiler writes, with no declaration to carry a comment: a
# Codable type's decoder and a raw-value enum's initializer.
COMPILER_WRITTEN = {("Initializer", "init(from:)"), ("Initializer", "init(rawValue:)")}


def is_projection(entry: dict) -> bool:
    """A property wrapper's or macro's `$` projection — `@TaskLocal`'s
    `$currentNode`. The compiler writes it beside the property, so no line
    exists to document; newer DocC publishes it and older DocC does not, so
    a stub that documents it warns on one toolchain or the other."""
    return entry["title"].startswith("$") and entry["kind"]["name"].endswith("Property")


def naked_pages(coverage: list[dict], target: str = TARGETS[0]) -> list[str]:
    """Every symbol page in `target`'s DocC coverage report with nothing to
    say, as ``Type/member (Kind)``, prefixed by the module for any module but
    the first."""
    naked = []
    prefix = "" if target == TARGETS[0] else f"{target}/"
    for entry in coverage:
        kind = entry["kind"]
        if not kind.get("isSymbol") or entry["hasAbstract"]:
            continue
        if (kind["name"], entry["title"]) in COMPILER_WRITTEN or is_projection(entry):
            continue
        path = entry["referencePath"].split(f"/documentation/{target}/", 1)[-1]
        naked.append(f"{prefix}{path} ({kind['name']})")
    return sorted(naked)


def docc_warnings(log: str) -> list[str]:
    return [line.strip() for line in log.splitlines() if line.lstrip().startswith("warning:")]


def build(scratch_path: str) -> tuple[int, str, dict[str, Path]]:
    """Build every published module's documentation; the status, the log,
    and each module's archive."""
    targets = [argument for target in TARGETS for argument in ("--target", target)]
    result = subprocess.run(
        ["swift", "package", "--scratch-path", scratch_path, "generate-documentation",
         *targets, *PUBLISHED_OPTIONS,
         "--experimental-documentation-coverage", "--coverage-summary-level", "brief"],
        cwd=REPO_ROOT, capture_output=True, text=True,
        env={**os.environ, "TUI_BUILD_DOCS": "1"})
    outputs = REPO_ROOT / scratch_path / "plugins" / "Swift-DocC" / "outputs"
    archives = {target: outputs / f"{target}.doccarchive" for target in TARGETS}
    return result.returncode, result.stdout + result.stderr, archives


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--scratch-path", default=".build-docs")
    args = parser.parse_args()
    status, log, archives = build(args.scratch_path)
    if status != 0:
        print("\n".join(log.splitlines()[-20:]))
        print("the documentation did not build")
        return 1
    problems = docc_warnings(log)
    pages = 0
    for target, archive in archives.items():
        coverage = json.loads((archive / "documentation-coverage.json").read_text())
        problems += [f"says nothing: {page}" for page in naked_pages(coverage, target)]
        pages += sum(1 for entry in coverage if entry["kind"].get("isSymbol"))
    if problems:
        print("\n".join(problems))
        return 1
    print(f"every one of the {pages} symbol pages of {', '.join(TARGETS)} says something")
    return 0


if __name__ == "__main__":
    sys.exit(main())
