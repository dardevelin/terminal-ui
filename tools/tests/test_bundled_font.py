#!/usr/bin/env python3
"""The bundled font is the release its README names, and nothing else.

``tools/fonts/JetBrainsMono/`` holds JetBrains Mono's four TrueType files
and its licence, which the builtin rasterizer's goldens and the docs'
pictures are drawn from. Its README pins each file's SHA-256; this checks
the files against that table, that the directory holds exactly those files
and the README, and that NOTICE still names the font and its licence.

Run::

    python3 tools/tests/test_bundled_font.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.cases import run_cases  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
FONT_DIR = ROOT / "tools" / "fonts" / "JetBrainsMono"
EXPECTED_FILES = {
    "JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf", "JetBrainsMono-Italic.ttf",
    "JetBrainsMono-BoldItalic.ttf", "OFL.txt",
}
ROW = re.compile(r"^\| `(?P<name>[^`]+)` \| (?P<size>\d+) \| `(?P<sha>[0-9a-f]{64})` \|$")
# sfnt version 1.0 (OpenType "Font file"): a TrueType font, not CFF.
TRUETYPE_SIGNATURE = b"\x00\x01\x00\x00"


def pinned() -> dict[str, tuple[int, str]]:
    rows = {}
    for line in (FONT_DIR / "README.md").read_text(encoding="utf-8").splitlines():
        match = ROW.match(line)
        if match:
            rows[match["name"]] = (int(match["size"]), match["sha"])
    return rows


def test_every_file_is_pinned() -> None:
    rows = pinned()
    assert set(rows) == EXPECTED_FILES, f"README pins {sorted(rows)}"


def test_hashes_match() -> None:
    for name, (size, sha) in pinned().items():
        data = (FONT_DIR / name).read_bytes()
        assert len(data) == size, f"{name}: {len(data)} bytes, pinned {size}"
        assert hashlib.sha256(data).hexdigest() == sha, f"{name}: SHA-256 differs from the README"


def test_nothing_else_is_bundled() -> None:
    present = {path.name for path in FONT_DIR.iterdir() if not path.name.startswith(".")}
    assert present == EXPECTED_FILES | {"README.md"}, f"unexpected: {sorted(present - EXPECTED_FILES)}"


def test_fonts_are_truetype() -> None:
    for name in EXPECTED_FILES - {"OFL.txt"}:
        assert (FONT_DIR / name).read_bytes()[:4] == TRUETYPE_SIGNATURE, f"{name} is not a TrueType font"


def test_licence_names_the_copyright_holder() -> None:
    licence = (FONT_DIR / "OFL.txt").read_text(encoding="utf-8")
    assert licence.startswith("Copyright 2020 The JetBrains Mono Project Authors"), licence[:80]
    assert "SIL OPEN FONT LICENSE Version 1.1" in licence


def test_notice_names_the_font() -> None:
    notice = (ROOT / "NOTICE").read_text(encoding="utf-8")
    for needle in ("JetBrains Mono", "Copyright 2020 The JetBrains Mono Project Authors",
                   "SIL Open Font License, Version 1.1", "tools/fonts/JetBrainsMono/OFL.txt"):
        assert needle in notice, f"NOTICE does not mention {needle!r}"


CASES = [
    ("the README pins every bundled file", test_every_file_is_pinned),
    ("each file's size and SHA-256 are the pinned ones", test_hashes_match),
    ("the directory holds only the pinned files and the README", test_nothing_else_is_bundled),
    ("each font file is TrueType", test_fonts_are_truetype),
    ("the licence is the OFL, with the font's copyright", test_licence_names_the_copyright_holder),
    ("NOTICE names the font, its copyright and licence", test_notice_names_the_font),
]

if __name__ == "__main__":
    sys.exit(run_cases(CASES))
