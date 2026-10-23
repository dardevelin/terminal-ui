#!/usr/bin/env python3
"""The framework draws in the app's theme; every colour it names is listed.

Components drew gray, white, cyan and fixed 256-colour bands of their own,
whatever theme the app set, and each one was found by someone looking at a
themed app. A component asks the theme for a role instead: ``accent``,
``foregroundMuted``, ``backgroundRaised``. The few places that still name a
colour do so for a reason, a data palette or a mark no role covers yet, and
``tools/colour-literals.txt`` lists each with the file it is in, how often
it appears there and why. This check fails on a literal its file's entries
do not name, and on a listed one that appears more or fewer times than its
entry says, so the list is always the true inventory.

Drawing code is every library that draws, ``TerminalUI`` and
``TerminalUIIO``, except the colour model and the stock theme (``Style/``),
the debug tools, which draw for the developer rather than the app, and the
tutorial's code. A colour in a ``case`` pattern matches one rather than
drawing it, and one in a string or a comment is text.

Run::

    python3 tools/scripts/check_colour_literals.py

Exit 0 when the list and the sources agree, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LIST = Path("tools") / "colour-literals.txt"
LIBRARIES = (Path("Sources") / "TerminalUI", Path("Sources") / "TerminalUIIO")

# Where colours are defined or debugged rather than drawn for an app.
NOT_DRAWING = ("Style", "DevTools", "TerminalUI.docc")

# A `Color` named outright, bare or qualified: an ANSI palette case, or a
# 256-colour or RGB value given in numbers. Not after a word or a dot, so
# `theme.red` and `.dim(` are not, and not a colour computed from data, such
# as `.rgb(pixel.r, pixel.g, pixel.b)`.
LITERAL = re.compile(
    r"(?<![\w.])(?:Color)?(\.(?:black|red|green|yellow|blue|magenta|cyan|white|gray"
    r"|brightBlack|brightRed|brightGreen|brightYellow|brightBlue|brightMagenta|brightCyan|brightWhite)\b"
    r"|\.ansi256(?=\(\s*\d+\s*\))|\.rgb(?=\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\)))")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
# A pattern — `case .red:`, `case (.red, .red),`, `if case .rgb = …` — which
# runs on over lines that end in a comma. Not an enum's `case green`.
PATTERN = re.compile(r"^\s*(?:(?:if|guard|while)\s+)?case\s+(?:[.(_]|let\b|var\b|is\b)")


def literals_in_sources(root: Path) -> dict[tuple[str, str], list[str]]:
    """(path, literal) → where each appears, as `path:line`, in drawing code."""
    found: dict[tuple[str, str], list[str]] = {}
    for library in LIBRARIES:
        for source in sorted((root / library).rglob("*.swift")):
            if source.relative_to(root / library).parts[0] in NOT_DRAWING:
                continue
            path = source.relative_to(root).as_posix()
            in_pattern = False
            for number, line in enumerate(source.read_text().splitlines(), start=1):
                code = STRING.sub('""', line).split("//", 1)[0]
                if in_pattern or PATTERN.match(code):
                    in_pattern = code.rstrip().endswith(",")
                    continue
                for match in LITERAL.finditer(code):
                    found.setdefault((path, match.group(1)), []).append(f"{path}:{number}")
    return found


def listed_literals(root: Path) -> tuple[dict[tuple[str, str], int], list[str]]:
    """(path, literal) → how often its entry allows it, and each line that
    is not an entry."""
    listed: dict[tuple[str, str], int] = {}
    unreadable: list[str] = []
    for number, line in enumerate((root / LIST).read_text().splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split(None, 3)
        if len(fields) < 4 or not fields[2].isdigit():
            unreadable.append(f"{LIST.as_posix()}:{number}: expected `path literal count reason`, got {line!r}")
        else:
            listed[(fields[0], fields[1])] = int(fields[2])
    return listed, unreadable


def findings(root: Path) -> list[str]:
    """Every literal no entry names, every listed literal that appears more or
    fewer times than its entry says, and every line of the list that cannot
    be read."""
    found = literals_in_sources(root)
    listed, unreadable = listed_literals(root)
    problems = list(unreadable)
    for (path, literal), sites in found.items():
        if (path, literal) not in listed:
            problems += [f"{site}: {literal}: draw a theme role, or list it in {LIST.as_posix()} with why"
                         for site in sites]
    counts = Counter({key: len(sites) for key, sites in found.items()})
    for (path, literal), allowed in sorted(listed.items()):
        if counts[(path, literal)] != allowed:
            problems.append(f"{path}: holds {counts[(path, literal)]} of {literal}, and the list allows "
                            f"{allowed}; draw a theme role, or change the entry in {LIST.as_posix()}")
    return problems


def main() -> int:
    problems = findings(REPO_ROOT)
    if problems:
        print("\n".join(problems))
        return 1
    print("every colour the drawing code names is listed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
