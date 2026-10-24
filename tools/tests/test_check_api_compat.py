#!/usr/bin/env python3
"""check_api_compat.py must hold the public API to its last release.

Each case hands the checker digester output and an allowlist and asserts
what it reports: a break the list does not accept, an accepted break that no
longer occurs, a run that never compared anything, and nothing when the two
agree.

Run::

    python3 tools/tests/test_check_api_compat.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_api_compat as checker  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402

REMOVED = "API breakage: func Text.bold() has been removed"
ADDED_CASE = "API breakage: enumelement BorderStyle.halfBlock has been added as a new enum case"

DIGESTER = f"""\
[20 / 26] Storybook-product
Build complete! (5,41 sec)

No breaking changes detected in TerminalInk

2 breaking changes detected in TerminalUI:
  💔 {ADDED_CASE}
  💔 {REMOVED}

No breaking changes detected in TerminalUIIO
"""

CLEAN = """\
Build complete! (2,10 sec)

No breaking changes detected in TerminalInk

No breaking changes detected in TerminalUI
"""


def allowlist(*entries: str, baseline: str = "v1.0.0") -> checker.Allowlist:
    text = "# accepted for 2.0.0\n\nbaseline " + baseline + "\n" + "".join(e + "\n" for e in entries)
    return checker.read_allowlist(text)


def breaks_are_read_with_their_module() -> None:
    assert checker.reported_breaks(DIGESTER) == {
        f"TerminalUI: {ADDED_CASE}",
        f"TerminalUI: {REMOVED}",
    }


def a_clean_run_reports_nothing() -> None:
    assert checker.reported_breaks(CLEAN) == set()


def the_list_names_its_baseline() -> None:
    accepted = allowlist(f"TerminalUI: {REMOVED}", baseline="v1.2.0")
    assert accepted.baseline == "v1.2.0", accepted
    assert accepted.entries == {f"TerminalUI: {REMOVED}"}, accepted
    assert accepted.unreadable == [], accepted


def a_list_without_a_baseline_is_reported() -> None:
    accepted = checker.read_allowlist(f"TerminalUI: {REMOVED}\n")
    assert accepted.baseline is None
    [finding] = checker.findings(DIGESTER, accepted)
    assert "baseline" in finding, finding


def accepted_breaks_pass() -> None:
    accepted = allowlist(f"TerminalUI: {ADDED_CASE}", f"TerminalUI: {REMOVED}")
    assert checker.findings(DIGESTER, accepted) == []


def an_unaccepted_break_is_reported() -> None:
    accepted = allowlist(f"TerminalUI: {ADDED_CASE}")
    [finding] = checker.findings(DIGESTER, accepted)
    assert finding.startswith(f"unaccepted: TerminalUI: {REMOVED}"), finding


def an_accepted_break_that_is_gone_is_reported() -> None:
    accepted = allowlist(f"TerminalUI: {ADDED_CASE}", f"TerminalUI: {REMOVED}")
    finding = checker.findings(CLEAN, accepted)[0]
    assert finding.startswith("gone: TerminalUI:"), finding
    assert len(checker.findings(CLEAN, accepted)) == 2


def hiding_a_page_from_the_docs_breaks_nothing() -> None:
    hidden = DIGESTER.replace(
        "2 breaking changes", "3 breaking changes").replace(
        f"  💔 {REMOVED}\n",
        f"  💔 {REMOVED}\n  💔 API breakage: var Button.body is now with @_documentation\n")
    accepted = allowlist(f"TerminalUI: {ADDED_CASE}", f"TerminalUI: {REMOVED}")
    assert checker.findings(hidden, accepted) == []


def a_run_that_compared_nothing_is_reported() -> None:
    failed = "error: the baseline failed to build\n"
    [finding] = checker.findings(failed, allowlist())
    assert finding.startswith("the digester compared nothing"), finding


CASES: list[tuple[str, Callable[[], None]]] = [
    ("breaks are read with their module", breaks_are_read_with_their_module),
    ("a clean run reports nothing", a_clean_run_reports_nothing),
    ("the list names its baseline", the_list_names_its_baseline),
    ("a list without a baseline is reported", a_list_without_a_baseline_is_reported),
    ("accepted breaks pass", accepted_breaks_pass),
    ("an unaccepted break is reported", an_unaccepted_break_is_reported),
    ("an accepted break that is gone is reported", an_accepted_break_that_is_gone_is_reported),
    ("hiding a page from the docs breaks nothing", hiding_a_page_from_the_docs_breaks_nothing),
    ("a run that compared nothing is reported", a_run_that_compared_nothing_is_reported),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
