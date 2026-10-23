#!/usr/bin/env python3
"""Every concurrency escape hatch in Sources/ is listed, with what guards it.

`@unchecked Sendable` and `nonisolated(unsafe)` tell the compiler to stop
checking: the type or variable is declared safe to share across threads, and
nothing verifies the claim. Every data race this framework has shipped sat
behind one — five `GraphContext` statics, then the trace recorder, whose
input-thread appends crashed scrolling in Coder.

So each one is listed in ``tools/escape-hatches.txt`` next to the thing that
actually makes it safe: a lock, the main actor, immutability. This check
fails when one appears that the list does not name, and when the list names
one that is gone, so the list is always the true inventory. Before adding an
entry, prefer the form the compiler checks: ``Mutex`` or ``Atomic`` (the
Synchronization module) with a plain ``Sendable``, or ``@MainActor``.

Run::

    python3 tools/scripts/check_escape_hatches.py

Exit 0 when the list and the sources agree, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LIST = Path("tools") / "escape-hatches.txt"

# Tutorial code steps are the reader's app, not the framework.
EXCLUDED_DIRS = (".docc",)

HATCH = re.compile(r"@unchecked\s+Sendable|nonisolated\(unsafe\)")
DECLARED_TYPE = re.compile(r"\b(?:class|struct|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_.]*)")
DECLARED_VARIABLE = re.compile(r"\b(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)")


def hatches_in_sources(root: Path) -> tuple[set[tuple[str, str]], list[str]]:
    """(path, declared name) for every escape hatch outside comments, and
    each hatch whose declaration this cannot read."""
    found: set[tuple[str, str]] = set()
    unreadable: list[str] = []
    for source in sorted((root / "Sources").rglob("*.swift")):
        relative = source.relative_to(root)
        if any(part.endswith(EXCLUDED_DIRS) for part in relative.parts):
            continue
        path = relative.as_posix()
        for number, line in enumerate(source.read_text().splitlines(), start=1):
            code = line.split("//", 1)[0]
            if not HATCH.search(code):
                continue
            declared = DECLARED_TYPE.search(code) or DECLARED_VARIABLE.search(code)
            if declared is None:
                unreadable.append(f"{path}:{number}: cannot tell what this escape hatch declares")
            else:
                found.add((path, declared.group(1)))
    return found, unreadable


def listed_hatches(root: Path) -> tuple[set[tuple[str, str]], list[str]]:
    """(path, declared name) for every entry the list gives a guard, and each
    line that is not an entry."""
    listed: set[tuple[str, str]] = set()
    unreadable: list[str] = []
    for number, line in enumerate((root / LIST).read_text().splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split(None, 2)
        if len(fields) < 3:
            unreadable.append(f"{LIST.as_posix()}:{number}: expected `path name guard`, got {line!r}")
        else:
            listed.add((fields[0], fields[1]))
    return listed, unreadable


def findings(root: Path) -> list[str]:
    """Everything that keeps ``root``'s list from being the true inventory of
    its sources' hatches: what cannot be read, every hatch the list does not
    name, every entry whose hatch is gone."""
    found, unreadable_sources = hatches_in_sources(root)
    listed, unreadable_entries = listed_hatches(root)
    return (unreadable_sources + unreadable_entries
            + [f"unlisted: {path} {name}: make the compiler check it (Mutex, Atomic, "
               f"@MainActor), or add it to {LIST.as_posix()} with what guards it"
               for path, name in sorted(found - listed)]
            + [f"gone: {path} {name}: remove its entry from {LIST.as_posix()}"
               for path, name in sorted(listed - found)])


def main() -> int:
    problems = findings(REPO_ROOT)
    if problems:
        print("\n".join(problems))
        return 1
    print("every escape hatch is listed with its guard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
