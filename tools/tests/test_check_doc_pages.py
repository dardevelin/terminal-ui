#!/usr/bin/env python3
"""check_doc_pages.py must find every published page that says nothing.

Each case hands the checker a DocC coverage report, as
``--experimental-documentation-coverage`` writes it, and asserts what it
reports: a symbol page without an abstract, nothing for one with an abstract
or for an article, and nothing for the pages the compiler writes that no
source line can document.

Run::

    python3 tools/tests/test_check_doc_pages.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_doc_pages as checker  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402


def page(path: str, kind: str = "Instance Property", abstract: bool = False,
         symbol: bool = True) -> dict:
    title = path.rsplit("/", 1)[-1]
    return {
        "kind": {"name": kind, "isSymbol": symbol},
        "hasAbstract": abstract,
        "title": title,
        "referencePath": f"doc://TerminalUI/documentation/TerminalUI/{path}",
    }


def a_page_with_nothing_to_say_is_reported() -> None:
    [finding] = checker.naked_pages([page("Edge/top", "Enumeration Case")])
    assert finding == "Edge/top (Enumeration Case)", finding


def a_documented_page_passes() -> None:
    assert checker.naked_pages([page("Edge/top", abstract=True)]) == []


def an_article_is_not_a_symbol() -> None:
    assert checker.naked_pages([page("GettingStarted", "Article", symbol=False)]) == []


def a_synthesized_decoder_is_not_ours_to_document() -> None:
    assert checker.naked_pages([page("CellSlice/init(from:)", "Initializer")]) == []


def a_hand_written_initializer_still_needs_words() -> None:
    [finding] = checker.naked_pages([page("MarkdownListItem/init(blocks:)", "Initializer")])
    assert finding.startswith("MarkdownListItem/init(blocks:)"), finding


def warnings_are_counted() -> None:
    log = "warning: 'Gone' doesn't exist at '/TerminalUI/Thing'\nnote: fine\nwarning: another\n"
    assert checker.docc_warnings(log) == [
        "warning: 'Gone' doesn't exist at '/TerminalUI/Thing'", "warning: another"]


CASES: list[tuple[str, Callable[[], None]]] = [
    ("a page with nothing to say is reported", a_page_with_nothing_to_say_is_reported),
    ("a documented page passes", a_documented_page_passes),
    ("an article is not a symbol", an_article_is_not_a_symbol),
    ("a synthesized decoder is not ours to document", a_synthesized_decoder_is_not_ours_to_document),
    ("a hand-written initializer still needs words", a_hand_written_initializer_still_needs_words),
    ("warnings are counted", warnings_are_counted),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
