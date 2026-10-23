#!/usr/bin/env python3
"""check_escape_hatches.py must hold the list and the sources to each other.

Each case builds a throwaway tree, a ``Sources/`` and a
``tools/escape-hatches.txt``, and asserts what the checker reports: a hatch
the list does not name, an entry whose hatch is gone, and nothing for
hatches it is told to leave alone.

Run::

    python3 tools/tests/test_check_escape_hatches.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_escape_hatches as checker  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402

UNCHECKED = "@unchecked" " Sendable"
UNSAFE = "nonisolated" "(unsafe)"


# Every case's tree, removed when the run ends.
SCRATCH = tempfile.TemporaryDirectory(prefix="terminalui-hatch-tests-")


def tree(sources: dict[str, str], listed: str = "") -> Path:
    root = Path(tempfile.mkdtemp(dir=SCRATCH.name))
    for relative, text in sources.items():
        path = root / "Sources" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    (root / "tools").mkdir()
    (root / "tools" / "escape-hatches.txt").write_text(listed)
    return root


def a_listed_hatch_passes() -> None:
    root = tree({"A/Box.swift": f"final class Box: {UNCHECKED} {{}}\n"},
                "# comment\n\nSources/A/Box.swift Box Mutated only on the main actor.\n")
    assert checker.findings(root) == []


def an_unlisted_type_is_reported() -> None:
    root = tree({"A/Box.swift": f"final class Box: {UNCHECKED} {{}}\n"})
    [finding] = checker.findings(root)
    assert finding.startswith("unlisted: Sources/A/Box.swift Box:"), finding


def an_unlisted_variable_is_reported() -> None:
    root = tree({"A/State.swift": f"{UNSAFE} private var handlers: [Int] = []\n"})
    [finding] = checker.findings(root)
    assert finding.startswith("unlisted: Sources/A/State.swift handlers:"), finding


def an_extension_names_the_type_it_extends() -> None:
    root = tree({"A/Box.swift": f"extension Outer.Box: {UNCHECKED} {{}}\n"})
    [finding] = checker.findings(root)
    assert finding.startswith("unlisted: Sources/A/Box.swift Outer.Box:"), finding


def an_entry_whose_hatch_is_gone_is_reported() -> None:
    root = tree({"A/Box.swift": "final class Box: Sendable {}\n"},
                "Sources/A/Box.swift Box Mutated only on the main actor.\n")
    [finding] = checker.findings(root)
    assert finding.startswith("gone: Sources/A/Box.swift Box:"), finding


def a_hatch_in_a_comment_is_not_one() -> None:
    root = tree({"A/Box.swift": f"final class Box {{}} // not {UNCHECKED}\n"})
    assert checker.findings(root) == []


def tutorial_code_is_not_the_framework() -> None:
    root = tree({"A/A.docc/Resources/step.swift": f"final class Model: {UNCHECKED} {{}}\n"})
    assert checker.findings(root) == []


def a_hatch_that_declares_nothing_is_reported() -> None:
    root = tree({"A/Box.swift": f"final class Box:\n    {UNCHECKED} {{}}\n"})
    [finding] = checker.findings(root)
    assert finding.startswith("Sources/A/Box.swift:2: cannot tell"), finding


def an_entry_without_a_guard_is_reported() -> None:
    root = tree({}, "# comment\nSources/A/Box.swift Box\n")
    [finding] = checker.findings(root)
    assert finding.startswith("tools/escape-hatches.txt:2: expected"), finding


CASES: list[tuple[str, Callable[[], None]]] = [
    ("a listed hatch passes", a_listed_hatch_passes),
    ("an unlisted type is reported", an_unlisted_type_is_reported),
    ("an unlisted variable is reported", an_unlisted_variable_is_reported),
    ("an extension names the type it extends", an_extension_names_the_type_it_extends),
    ("an entry whose hatch is gone is reported", an_entry_whose_hatch_is_gone_is_reported),
    ("a hatch in a comment is not one", a_hatch_in_a_comment_is_not_one),
    ("tutorial code is not the framework", tutorial_code_is_not_the_framework),
    ("a hatch that declares nothing is reported", a_hatch_that_declares_nothing_is_reported),
    ("an entry without a guard is reported", an_entry_without_a_guard_is_reported),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
