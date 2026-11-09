#!/usr/bin/env python3
"""Every character outside ASCII the framework draws is a shape or listed.

A picture made from a recording draws box drawing, block elements, braille
and the framework's own marks as shapes (``GlyphGeometry``), and everything
else with a font, where a missing glyph falls back to another font at
another size or to an empty box. ``tools/font-glyphs.txt`` lists each
non-ASCII character in a string or character literal of ``Sources/TerminalUI``
(the tutorial's steps, under ``TerminalUI.docc/Resources``, included):
either ``shape``, drawn from geometry, or ``font``, with why a font may draw
it. This check fails on a character no entry covers and on an entry no
source holds any more, so the list is always the true inventory;
``GlyphGeometryTests`` holds each ``shape`` entry to being one, and each
``font`` entry to not being one.

A literal is what the code writes, ``"\\u{2502}"`` as much as ``"│"``;
comments are not drawn.

Run::

    python3 tools/scripts/check_font_glyphs.py

Exit 0 when the list and the sources agree, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LIST = Path("tools") / "font-glyphs.txt"
SOURCES = Path("Sources") / "TerminalUI"
KINDS = ("shape", "font")

# `\u{…}`, one to eight hex digits (The Swift Programming Language,
# "Special Characters in String Literals").
UNICODE_ESCAPE = re.compile(r"u\{([0-9A-Fa-f]{1,8})\}")
CODE_POINT = re.compile(r"U\+([0-9A-F]{4,6})")
RAW_STRING_START = re.compile(r'#+"')
# Unicode general categories C (controls, format) and Z (separators): no
# glyph to write in the list's glyph column, which holds NO_GLYPH instead.
INVISIBLE_CATEGORIES = "CZ"
NO_GLYPH = "-"


def string_scalars(text: str) -> list[tuple[int, int]]:
    """(code point, line) for each scalar inside a string or character
    literal of Swift source `text`, an escape counted as the scalar it
    writes: single-line, multi-line (`\"\"\"`) and raw (`#\"…\"#`) strings,
    interpolations' own literals, nested `/* */` comments skipped."""
    found: list[tuple[int, int]] = []
    index = 0
    line = 1

    def code(until_paren: bool) -> None:
        """Scans code from `index`; when `until_paren`, up to the `)` that
        closes an interpolation."""
        nonlocal index, line
        depth = 0
        while index < len(text):
            char = text[index]
            if char == "\n":
                line += 1
            if text.startswith("//", index):
                end = text.find("\n", index)
                index = len(text) if end < 0 else end
                continue
            if text.startswith("/*", index):
                comment()
                continue
            if char == '"' or (char == "#" and RAW_STRING_START.match(text, index)):
                string()
                continue
            if until_paren:
                if char == "(":
                    depth += 1
                elif char == ")":
                    if depth == 0:
                        index += 1
                        return
                    depth -= 1
            index += 1

    def comment() -> None:
        nonlocal index, line
        depth = 0
        while index < len(text):
            if text.startswith("/*", index):
                depth += 1
                index += 2
            elif text.startswith("*/", index):
                depth -= 1
                index += 2
                if depth == 0:
                    return
            else:
                if text[index] == "\n":
                    line += 1
                index += 1

    def string() -> None:
        nonlocal index, line
        hashes = 0
        while text.startswith("#", index):
            hashes += 1
            index += 1
        multiline = text.startswith('"""', index)
        index += 3 if multiline else 1
        closing = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        while index < len(text):
            if text.startswith(closing, index):
                index += len(closing)
                return
            if text.startswith(escape, index):
                index += len(escape)
                if text.startswith("(", index):
                    index += 1
                    code(until_paren=True)
                    continue
                match = UNICODE_ESCAPE.match(text, index)
                if match:
                    found.append((int(match.group(1), 16), line))
                    index = match.end()
                    continue
                if text.startswith("\n", index):
                    line += 1
                index += 1
                continue
            char = text[index]
            if char == "\n":
                line += 1
                if not multiline:
                    return
            elif ord(char) > 0x7F:
                found.append((ord(char), line))
            index += 1

    code(until_paren=False)
    return found


def drawn_characters(root: Path) -> dict[int, list[str]]:
    """Code point → where each non-ASCII literal appears, as `path:line`."""
    found: dict[int, list[str]] = {}
    for source in sorted((root / SOURCES).rglob("*.swift")):
        path = source.relative_to(root).as_posix()
        for value, number in string_scalars(source.read_text()):
            if value > 0x7F:
                found.setdefault(value, []).append(f"{path}:{number}")
    return found


@dataclass
class Entry:
    first: int
    last: int
    kind: str
    line: int

    def covers(self, value: int) -> bool:
        return self.first <= value <= self.last


def listed_glyphs(root: Path) -> tuple[list[Entry], list[str]]:
    """The list's entries, and each line that is not one."""
    entries: list[Entry] = []
    unreadable: list[str] = []
    for number, line in enumerate((root / LIST).read_text().splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        where = f"{LIST.as_posix()}:{number}"
        fields = line.split(None, 3)
        bounds = fields[0].split("..") if fields else []
        points = [CODE_POINT.fullmatch(bound) for bound in bounds]
        if len(fields) < 4 or not 1 <= len(points) <= 2 or not all(points) or fields[2] not in KINDS:
            unreadable.append(f"{where}: expected `U+XXXX[..U+YYYY] glyph shape|font reason`, got {line!r}")
            continue
        first, last = (int(point.group(1), 16) for point in (points[0], points[-1]))
        glyphs = chr(first) if first == last else f"{chr(first)}..{chr(last)}"
        # A control or separator has no glyph to write; `-` stands for it.
        invisible = first == last and unicodedata.category(chr(first))[0] in INVISIBLE_CATEGORIES
        if invisible:
            glyphs = NO_GLYPH
        if first > last or fields[1] != glyphs:
            unreadable.append(f"{where}: {fields[0]} is {glyphs!r}, not {fields[1]!r}")
            continue
        entries.append(Entry(first, last, fields[2], number))
    return entries, unreadable


def findings(root: Path) -> list[str]:
    """Every drawn character no entry covers, every entry no drawn
    character falls under, and every line of the list that cannot be read."""
    drawn = drawn_characters(root)
    entries, problems = listed_glyphs(root)
    for value, sites in sorted(drawn.items()):
        if not any(entry.covers(value) for entry in entries):
            problems += [f"{site}: U+{value:04X} {chr(value)}: draw it as a shape in GlyphGeometry, or list it "
                         f"in {LIST.as_posix()} with why the font may draw it" for site in sites]
    for entry in entries:
        if not any(entry.covers(value) for value in drawn):
            problems.append(f"{LIST.as_posix()}:{entry.line}: no source draws U+{entry.first:04X}"
                            + ("" if entry.first == entry.last else f"..U+{entry.last:04X}")
                            + "; remove the entry")
    return problems


def main() -> int:
    problems = findings(REPO_ROOT)
    if problems:
        print("\n".join(problems))
        return 1
    print("every non-ASCII character the framework draws is a shape or listed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
