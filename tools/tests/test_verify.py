#!/usr/bin/env python3
"""verify.py skips a turn that left no source changes, unless asked not to.

As the Stop hook it runs after every turn, and a turn that only edited
docs or memory should cost nothing. Run by hand on a merge whose changes
are all committed, the same skip would pass without checking anything, so
``--always`` runs the gate whatever the working tree holds.

Run::

    python3 tools/tests/test_verify.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import verify  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402


def a_turn_with_no_source_changes_skips() -> None:
    assert not verify.wants_gate([], has_source_changes=False)


def a_turn_with_source_changes_runs() -> None:
    assert verify.wants_gate([], has_source_changes=True)


def always_runs_a_clean_tree() -> None:
    assert verify.wants_gate(["--always"], has_source_changes=False)


def a_failure_names_what_failed_above_the_tail() -> None:
    output = "\n".join(
        ["✔ Test a() passed."] * 40
        + ['✘ Test aRowFits() recorded an issue at RowTests.swift:12:9: Expectation failed: 3 == 4',
           "✘ Test aRowFits() failed after 0.01 seconds with 1 issue."]
        + ["✔ Suite \"Other\" passed."] * 40
        + ["Note: Some test targets reported failures:"])
    shown = verify.failure_detail(output)
    assert "RowTests.swift:12:9" in shown and "aRowFits() failed" in shown, shown
    assert shown.splitlines()[-1] == "Note: Some test targets reported failures:", shown
    assert len(shown.splitlines()) < 40, shown


def a_failure_with_no_marked_lines_shows_its_tail() -> None:
    output = "\n".join(f"line {number}" for number in range(100))
    assert verify.failure_detail(output).splitlines() == [f"line {number}" for number in range(75, 100)]


CASES: list[tuple[str, Callable[[], None]]] = [
    ("a failure names what failed above the tail", a_failure_names_what_failed_above_the_tail),
    ("a failure with no marked lines shows its tail", a_failure_with_no_marked_lines_shows_its_tail),
    ("a turn with no source changes skips", a_turn_with_no_source_changes_skips),
    ("a turn with source changes runs", a_turn_with_source_changes_runs),
    ("--always runs a clean tree", always_runs_a_clean_tree),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
