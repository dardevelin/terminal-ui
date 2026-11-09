#!/usr/bin/env python3
"""check_font_glyphs.py must hold the list and the framework's literals to each other.

Each case builds a throwaway tree, a ``Sources/TerminalUI`` and a
``tools/font-glyphs.txt``, and asserts what the checker reports: a
character no entry covers, an entry no source draws, an entry that cannot
be read, and nothing for what is not a literal.

Run::

    python3 tools/tests/test_check_font_glyphs.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_font_glyphs as checker  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402

# Every case's tree, removed when the run ends.
SCRATCH = tempfile.TemporaryDirectory(prefix="terminalui-glyph-tests-")

BOX = "U+2500..U+257F ─..╿ shape Box drawing.\n"


def tree(sources: dict[str, str], listed: str = "") -> Path:
    root = Path(tempfile.mkdtemp(dir=SCRATCH.name))
    for relative, text in sources.items():
        path = root / "Sources" / "TerminalUI" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    (root / "tools").mkdir()
    (root / "tools" / "font-glyphs.txt").write_text(listed)
    return root


def a_range_covers_its_characters() -> None:
    root = tree({"Style/Border.swift": 'let corners = ["┌", "┐", "└", "┘"]\n'}, BOX)
    assert checker.findings(root) == [], checker.findings(root)


def an_unlisted_character_is_reported_where_it_is() -> None:
    root = tree({"Views/Prompt.swift": 'let a = "x"\nlet prompt = "❯ "\n'})
    [finding] = checker.findings(root)
    assert finding.startswith("Sources/TerminalUI/Views/Prompt.swift:2: U+276F ❯"), finding


def an_escape_is_the_character_it_writes() -> None:
    root = tree({"Views/Tree.swift": 'let branch = "\\u{251C}\\u{2500} "\nlet esc = "\\u{1B}["\n'})
    found = checker.findings(root)
    assert [line.split(": ")[1] for line in found] == ["U+2500 ─", "U+251C ├"], found


def comments_are_not_drawn() -> None:
    root = tree({"Views/Tree.swift": '/// Draws "├── " rows.\n// └─\n/* a /* nested ━ */ │ */\nlet x = 1 // "┃"\n'})
    assert checker.findings(root) == [], checker.findings(root)


def every_kind_of_literal_counts() -> None:
    root = tree({"Views/Text.swift":
                 'let multi = """\n    ▸ item\n    """\n'
                 'let raw = #"a "quoted" ●"#\n'
                 'let raw2 = #"no \\u{2612} escape in a raw string, but \\#u{2611} is"#\n'
                 'let nested = "\\(flag ? "☐" : "x") done"\n'
                 'let char: Character = "…"\n'})
    found = sorted(line.split(": ")[1] for line in checker.findings(root))
    assert found == ["U+2026 …", "U+25B8 ▸", "U+25CF ●", "U+2610 ☐", "U+2611 ☑"], found


def the_tutorial_steps_are_checked() -> None:
    root = tree({"TerminalUI.docc/Resources/tasks-02-02.swift": 'Text(done ? "☑" : "☐")\n'})
    assert len(checker.findings(root)) == 2, checker.findings(root)


def an_entry_no_source_draws_is_reported() -> None:
    root = tree({"Views/A.swift": 'let a = "─"\n'}, BOX + "U+276F ❯ shape The prompt.\n")
    [finding] = checker.findings(root)
    assert finding == "tools/font-glyphs.txt:2: no source draws U+276F; remove the entry", finding


def an_unreadable_entry_is_reported() -> None:
    entries = ("U+2014 — font\n"                       # no reason
               "U+2014 – font Wrong glyph.\n"          # the glyph is not the code point's
               "U+2014 — glyph Not a kind.\n"
               "2014 — font No U+.\n"
               "U+257F..U+2500 ╿..─ shape Backwards.\n")
    root = tree({"Views/A.swift": 'let a = "b"\n'}, entries)
    found = checker.findings(root)
    assert len(found) == 5 and all(line.startswith("tools/font-glyphs.txt:") for line in found), found


def an_invisible_character_is_listed_as_a_dash() -> None:
    source = {"Views/Input.swift": 'let breaks: Set<Character> = ["\\u{2028}", "\\u{0085}"]\n'}
    root = tree(source, "U+2028 - font A line break, never drawn.\nU+0085 - font A line break, never drawn.\n")
    assert checker.findings(root) == [], checker.findings(root)
    visible = tree({"Views/A.swift": 'let a = "—"\n'}, "U+2014 - font A dash.\n")
    assert len(checker.findings(visible)) == 2, checker.findings(visible)


CASES: list[tuple[str, Callable[[], None]]] = [
    ("a range covers its characters", a_range_covers_its_characters),
    ("an unlisted character is reported where it is", an_unlisted_character_is_reported_where_it_is),
    ("an escape is the character it writes", an_escape_is_the_character_it_writes),
    ("comments are not drawn", comments_are_not_drawn),
    ("every kind of literal counts", every_kind_of_literal_counts),
    ("the tutorial steps are checked", the_tutorial_steps_are_checked),
    ("an entry no source draws is reported", an_entry_no_source_draws_is_reported),
    ("an unreadable entry is reported", an_unreadable_entry_is_reported),
    ("an invisible character is listed as a dash", an_invisible_character_is_listed_as_a_dash),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
