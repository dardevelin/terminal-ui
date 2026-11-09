#!/usr/bin/env python3
"""The committed width table is what its generator makes, and the terminal
model counts columns as it does.

``Character.displayWidth`` reads a table generated from EastAsianWidth.txt,
and the smoke suite replays an app's output through ``terminalui.vt``,
which counts with Python's ``unicodedata``. A table edited by hand, or a
model that counts another way, would let a row drawn a column late pass —
or fail one drawn right. The fixture is a verbatim subset of
EastAsianWidth-17.0.0.txt: the lines for the characters that once
disagreed, the deliberate choices and the defaults.

Run::

    python3 tools/tests/test_width_table.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import bisect
import contextlib
import io
import sys
import tempfile
import unicodedata
from pathlib import Path
from typing import Callable

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS / "scripts"))
sys.path.insert(0, str(TOOLS))

import generate_width_table as generator  # noqa: E402
from terminalui import vt  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402

FIXTURE = TOOLS / "tests" / "fixtures" / "EastAsianWidth-17.0.0-subset.txt"
COMMITTED_SOURCE = generator.TABLE.read_text(encoding="utf-8")
COMMITTED_VERSION, COMMITTED = generator.parse_table(COMMITTED_SOURCE)
FIRSTS = [entry.first for entry in COMMITTED]
FIXTURE_TEXT = FIXTURE.read_text(encoding="utf-8")
FIXTURE_VERSION, FIXTURE_WIDTHS = generator.parse(FIXTURE_TEXT)

# The characters the framework and the model must agree on under any
# Unicode version either carries: assigned long before both, and with an
# East_Asian_Width no version since has changed.
SHARED = ("a ~é…─│°±§①→■★Ω❯✓✔❤☀⚠🌡🖥"  # 1: narrow, ambiguous, text-default
          "⌚⌛⏩⏰⏳◽☔☕♈♓♿⚓⚡⚪⚽⛄⛎⛔⛪⛲⛵⛺⛽✅✊✨❌❎❓❗➕➰➿⬛⭐⭕"  # 2: BMP Emoji_Presentation
          "中文あカ한ᄀＡ！￥　〔︰\U00020000🙂👍🇺"  # 2: East Asian Wide, Fullwidth, plane 1
          "֑̀҃⃣゙️​‍⁠﻿\U000e0067")  # 0


def committed_width(code: int) -> int:
    index = bisect.bisect_right(FIRSTS, code) - 1
    if index >= 0 and code <= COMMITTED[index].last:
        return COMMITTED[index].width
    return 1


def listed_code_points(text: str) -> list[int]:
    points: list[int] = []
    for line in text.splitlines():
        data = generator.DATA_LINE.match(line)
        if data is not None:
            points.extend(range(int(data.group(1), 16), int(data.group(2) or data.group(1), 16) + 1))
    return points


def expect(actual: object, expected: object) -> None:
    assert actual == expected, f"expected {expected!r}, got {actual!r}"


def the_committed_table_is_what_the_generator_makes_of_the_fixture() -> None:
    expect(COMMITTED_VERSION, FIXTURE_VERSION)
    differing = [f"U+{code:04X}: committed {committed_width(code)}, generated {FIXTURE_WIDTHS.get(code, 1)}"
                 for code in listed_code_points(FIXTURE_TEXT)
                 if committed_width(code) != FIXTURE_WIDTHS.get(code, 1)]
    assert not differing, "\n".join(differing[:10])


def the_committed_table_is_exactly_the_generators_output() -> None:
    # Read back and rendered again, a table only the generator wrote is
    # unchanged: no hand-edited entry, header or format.
    expect(generator.render(COMMITTED_VERSION, COMMITTED), COMMITTED_SOURCE)
    expect(generator.ranges({code: committed_width(code) for entry in COMMITTED
                             for code in range(entry.first, entry.last + 1)}), COMMITTED)


def an_unlisted_code_point_takes_the_headers_default() -> None:
    _, widths = generator.parse("# EastAsianWidth-99.0.0.txt\n")
    for code in (0x3400, 0x4E00, 0xFA6E, 0x2A6E0, 0x2FFFD, 0x3FFFD):
        expect((hex(code), widths.get(code, 1)), (hex(code), 2))
    for code in (0x2FFFE, 0x40000, 0xE0000, 0x10FFFF):
        expect((hex(code), widths.get(code, 1)), (hex(code), 1))


def a_mark_is_zero_wide_though_the_file_calls_it_wide() -> None:
    for code in (0x302A, 0x302D, 0x3099, 0x309A):
        expect((hex(code), FIXTURE_WIDTHS.get(code, 1)), (hex(code), 0))
    # A spacing mark (Mc) is not one: U+302E is drawn, two wide.
    expect(FIXTURE_WIDTHS.get(0x302E, 1), 2)


def the_model_and_the_table_agree_on_the_shared_characters() -> None:
    differing = [f"{char!r} U+{ord(char):04X}: model {vt.column_width(char)}, table {committed_width(ord(char))}"
                 for char in SHARED if vt.column_width(char) != committed_width(ord(char))]
    assert not differing, "\n".join(differing)


def the_model_and_the_table_agree_on_every_character_of_one_unicode_version() -> None:
    # Python's unicodedata is its own Unicode version, which an older Python
    # does not share with the table: Unicode 16.0 made the Yijing trigrams
    # and hexagrams wide, so a 15.1 Python and the table rightly differ on
    # them. Under the one version, every assigned code point must agree.
    if unicodedata.unidata_version != COMMITTED_VERSION:
        print(f"  (Python's Unicode {unicodedata.unidata_version} is not the table's "
              f"{COMMITTED_VERSION}: compared the shared characters only)")
        the_model_and_the_table_agree_on_the_shared_characters()
        return
    differing = [f"U+{code:04X}: model {vt.column_width(chr(code))}, table {committed_width(code)}"
                 for code in range(0x110000)
                 if unicodedata.category(chr(code)) not in ("Cn", "Cs")
                 and vt.column_width(chr(code)) != committed_width(code)]
    assert not differing, f"{len(differing)} differ:\n" + "\n".join(differing[:10])


def check_reports_a_stale_table() -> None:
    with tempfile.TemporaryDirectory() as scratch:
        output = Path(scratch) / "UnicodeWidthTable.swift"

        def generate(*flags: str) -> int:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                return generator.main([str(FIXTURE), "--output", str(output), *flags])

        expect(generate(), 0)
        expect(generate("--check"), 0)
        output.write_text(output.read_text(encoding="utf-8").replace(", 2),", ", 1),", 1), encoding="utf-8")
        expect(generate("--check"), 1)


CASES: list[tuple[str, Callable[[], None]]] = [
    ("the committed table is what the generator makes of the fixture",
     the_committed_table_is_what_the_generator_makes_of_the_fixture),
    ("the committed table is exactly the generator's output",
     the_committed_table_is_exactly_the_generators_output),
    ("an unlisted code point takes the header's default", an_unlisted_code_point_takes_the_headers_default),
    ("a mark is zero wide though the file calls it wide", a_mark_is_zero_wide_though_the_file_calls_it_wide),
    ("the model and the table agree on the shared characters",
     the_model_and_the_table_agree_on_the_shared_characters),
    ("the model and the table agree on every character of one Unicode version",
     the_model_and_the_table_agree_on_every_character_of_one_unicode_version),
    ("--check reports a stale table", check_reports_a_stale_table),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
