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
LIST = REPO_ROOT / "tools" / "escape-hatches.txt"

# Tutorial code steps are the reader's app, not the framework.
EXCLUDED_DIRS = (".docc",)

HATCH = re.compile(r"@unchecked\s+Sendable|nonisolated\(unsafe\)")
DECLARED_TYPE = re.compile(r"\b(?:class|struct|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_.]*)")
DECLARED_VARIABLE = re.compile(r"\b(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)")


def hatches_in_sources() -> set[tuple[str, str]]:
    """(path, declared name) for every escape hatch outside comments."""
    found: set[tuple[str, str]] = set()
    for source in sorted((REPO_ROOT / "Sources").rglob("*.swift")):
        if any(part.endswith(EXCLUDED_DIRS) for part in source.parts):
            continue
        relative = source.relative_to(REPO_ROOT).as_posix()
        for number, line in enumerate(source.read_text().splitlines(), start=1):
            code = line.split("//", 1)[0]
            if not HATCH.search(code):
                continue
            declared = DECLARED_TYPE.search(code) or DECLARED_VARIABLE.search(code)
            if declared is None:
                raise SystemExit(f"{relative}:{number}: cannot tell what this escape hatch declares")
            found.add((relative, declared.group(1)))
    return found


def listed_hatches() -> dict[tuple[str, str], str]:
    """(path, declared name) → the guard the list states for it."""
    listed: dict[tuple[str, str], str] = {}
    for number, line in enumerate(LIST.read_text().splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split(None, 2)
        if len(fields) < 3 or not fields[2].strip():
            raise SystemExit(f"{LIST.name}:{number}: expected `path name guard`, got {line!r}")
        listed[(fields[0], fields[1])] = fields[2].strip()
    return listed


def main() -> int:
    found = hatches_in_sources()
    listed = listed_hatches()
    unlisted = sorted(found - listed.keys())
    gone = sorted(listed.keys() - found)
    for path, name in unlisted:
        print(f"unlisted: {path} {name}: make the compiler check it (Mutex, Atomic, "
              f"@MainActor), or add it to {LIST.relative_to(REPO_ROOT)} with what guards it")
    for path, name in gone:
        print(f"gone: {path} {name}: remove its entry from {LIST.relative_to(REPO_ROOT)}")
    if unlisted or gone:
        return 1
    print(f"{len(found)} escape hatches, each listed with its guard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
