#!/usr/bin/env python3
"""check_colour_literals.py must hold the list and the drawing code to each other.

Each case builds a throwaway tree, a ``Sources/`` and a
``tools/colour-literals.txt``, and asserts what the checker reports: a
literal its file's entries do not name, more or fewer of one than its entry
allows, an entry that cannot be read, and nothing for what it is told to
leave alone.

Run::

    python3 tools/tests/test_check_colour_literals.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_colour_literals as checker  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402

# Every case's tree, removed when the run ends.
SCRATCH = tempfile.TemporaryDirectory(prefix="terminalui-colour-tests-")


def tree(sources: dict[str, str], listed: str = "") -> Path:
    root = Path(tempfile.mkdtemp(dir=SCRATCH.name))
    for relative, text in sources.items():
        path = root / "Sources" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    (root / "tools").mkdir()
    (root / "tools" / "colour-literals.txt").write_text(listed)
    return root


def a_role_is_not_a_literal() -> None:
    root = tree({"TerminalUI/Views/Badge.swift": "Text(label).foreground(theme.accent)\n"})
    assert checker.findings(root) == []


def an_unlisted_literal_is_reported() -> None:
    root = tree({"TerminalUI/Views/Badge.swift": "Text(label).foreground(.gray)\n"})
    [finding] = checker.findings(root)
    assert finding.startswith("Sources/TerminalUI/Views/Badge.swift:1: .gray"), finding


def every_spelling_of_a_literal_is_one() -> None:
    root = tree({"TerminalUI/Views/Badge.swift":
                 "a(.brightWhite)\nb(.ansi256(240))\nc(.rgb(1, 2, 3))\nd(Color.gray)\ne(foreground: Color.red)\n"})
    assert len(checker.findings(root)) == 5, checker.findings(root)


def every_library_that_draws_is_checked() -> None:
    root = tree({"TerminalUIIO/Placeholder.swift": "Text(\"no image\").foreground(.gray)\n",
                 "TerminalUI/Rendering/Blend.swift": "let ground = cell.background ?? .rgb(0, 0, 0)\n"})
    assert len(checker.findings(root)) == 2, checker.findings(root)


def a_listed_literal_may_appear_as_often_as_its_entry_says() -> None:
    root = tree({"TerminalUI/Graph/Renderer.swift": "x(.black)\ny(.dim(.ansi256(239)))\n"},
                "# comment\n\n"
                "Sources/TerminalUI/Graph/Renderer.swift .black 1 No role pairs text with the focus fill.\n"
                "Sources/TerminalUI/Graph/Renderer.swift .ansi256 1 No scrim role.\n")
    assert checker.findings(root) == []


def a_listed_literal_does_not_cover_another() -> None:
    root = tree({"TerminalUI/Graph/Renderer.swift": "x(.white)\n"},
                "Sources/TerminalUI/Graph/Renderer.swift .black 1 Focus marker.\n")
    findings = checker.findings(root)
    assert len(findings) == 2, findings
    assert findings[0].startswith("Sources/TerminalUI/Graph/Renderer.swift:1: .white"), findings
    assert "holds 0 of .black, and the list allows 1" in findings[1], findings


def one_more_than_listed_is_reported() -> None:
    root = tree({"TerminalUI/Graph/Renderer.swift": "x(.black)\ny(.black)\n"},
                "Sources/TerminalUI/Graph/Renderer.swift .black 1 Focus marker.\n")
    [finding] = checker.findings(root)
    assert "holds 2 of .black, and the list allows 1" in finding, finding


def comments_strings_and_names_are_not_literals() -> None:
    root = tree({"TerminalUI/Views/Badge.swift":
                 "/// draws `.gray`\nlet x = theme.red // .gray\nlet greenish = colours.redness\n"
                 "Text(\"see http://x.red .gray\")\n"})
    assert checker.findings(root) == []


def a_pattern_matches_a_colour_rather_than_drawing_one() -> None:
    root = tree({"TerminalUI/Rendering/Cell.swift":
                 "case (.red, .red): return true\ncase .gray:\ncase (.black, .black),\n     (.white, .white):\n"
                 "    true\nlet after = Color.cyan\n"})
    [finding] = checker.findings(root)
    assert finding.startswith("Sources/TerminalUI/Rendering/Cell.swift:6: .cyan"), finding


def an_enum_case_is_not_a_pattern() -> None:
    root = tree({"TerminalUI/Views/Chart.swift": "enum Palette {\n    case green\n}\nlet fill = Color.gray\n"})
    [finding] = checker.findings(root)
    assert finding.startswith("Sources/TerminalUI/Views/Chart.swift:4: .gray"), finding


def a_colour_computed_from_data_is_not_named() -> None:
    root = tree({"TerminalUIIO/Blocks.swift": "Style(foreground: .rgb(top.r, top.g, top.b))\nx(.ansi256(level))\n"})
    assert checker.findings(root) == []


def the_colour_model_and_debug_tools_are_not_drawing_code() -> None:
    root = tree({"TerminalUI/Style/Theme.swift": "var accent: Color = .cyan\n",
                 "TerminalUI/DevTools/DebugPanel.swift": "Text(\"fps\").foreground(.yellow)\n",
                 "TerminalUI/TerminalUI.docc/Resources/step.swift": "Text(\"x\").foreground(.red)\n"})
    assert checker.findings(root) == []


def an_entry_without_a_reason_is_reported() -> None:
    root = tree({}, "Sources/TerminalUI/Graph/Renderer.swift .black 2\n")
    [finding] = checker.findings(root)
    assert finding.startswith("tools/colour-literals.txt:1: expected"), finding


CASES: list[tuple[str, Callable[[], None]]] = [
    ("a role is not a literal", a_role_is_not_a_literal),
    ("an unlisted literal is reported", an_unlisted_literal_is_reported),
    ("every spelling of a literal is one", every_spelling_of_a_literal_is_one),
    ("every library that draws is checked", every_library_that_draws_is_checked),
    ("a listed literal may appear as often as its entry says",
     a_listed_literal_may_appear_as_often_as_its_entry_says),
    ("a listed literal does not cover another", a_listed_literal_does_not_cover_another),
    ("one more than listed is reported", one_more_than_listed_is_reported),
    ("comments, strings and names are not literals", comments_strings_and_names_are_not_literals),
    ("a pattern matches a colour rather than drawing one", a_pattern_matches_a_colour_rather_than_drawing_one),
    ("a colour computed from data is not named", a_colour_computed_from_data_is_not_named),
    ("an enum case is not a pattern", an_enum_case_is_not_a_pattern),
    ("the colour model and debug tools are not drawing code",
     the_colour_model_and_debug_tools_are_not_drawing_code),
    ("an entry without a reason is reported", an_entry_without_a_reason_is_reported),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
