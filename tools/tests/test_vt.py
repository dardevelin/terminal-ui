#!/usr/bin/env python3
"""The terminal model puts each glyph where a terminal would.

``terminalui.vt`` is what the smoke suite holds an app's output bytes to:
a model that agreed with whatever it was fed would pass a frame drawn one
column late, so the shift it exists to catch is pinned here first.

Run::

    python3 tools/tests/test_vt.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import vt  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402

HOME = b"\x1b[H"


def lines(data: bytes, columns: int, rows: int = 1) -> list[str]:
    screen = vt.Screen(columns, rows)
    screen.feed(data)
    return screen.lines()


def expect(actual: object, expected: object) -> None:
    assert actual == expected, f"expected {expected!r}, got {actual!r}"


def text_after_a_wide_glyph_lands_two_columns_on() -> None:
    expect(lines(HOME + "中a".encode(), 5), ["中 a  "])


def a_row_drawn_one_column_late_does_not_match() -> None:
    # A buffer holding `中a` in six columns dumps its row as below. Sending
    # the glyph's second cell as a space of its own, as it once did, draws
    # everything after it one column late: the model must tell the two apart.
    buffer_rows = ["中 a   ", "      "]
    expect(lines(HOME + "中a   ".encode(), 6, 2), buffer_rows)
    late = lines(HOME + "中 a   ".encode(), 6, 2)
    assert late != buffer_rows, f"a row drawn one column late matched: {late!r}"
    expect(late, ["中  a  ", "      "])


def cup_and_cha_place_the_cursor() -> None:
    expect(lines(b"\x1b[2;3Hx\x1b[1Gy", 4, 2), ["    ", "y x "])


def the_last_column_holds_a_pending_wrap() -> None:
    expect(lines(HOME + b"abc", 3, 2), ["abc", "   "])
    expect(lines(HOME + b"abcd", 3, 2), ["abc", "d  "])
    expect(lines(HOME + b"abc\r\nd", 3, 2), ["abc", "d  "])


def a_wide_glyph_that_does_not_fit_wraps_whole() -> None:
    expect(lines(HOME + "ab中".encode(), 3, 2), ["ab ", "中  "])


def printing_over_a_wide_glyphs_half_blanks_the_other() -> None:
    expect(lines(HOME + "中x".encode() + b"\x1b[1;2Hb", 4), [" bx "])
    expect(lines(HOME + "中x".encode() + b"\x1b[1;1Ha", 4), ["a x "])
    expect(lines(HOME + "中文".encode() + "\x1b[1;2H字".encode(), 4), [" 字  "])


def a_combining_mark_joins_its_base() -> None:
    expect(lines(HOME + "café!".encode(), 5), ["café!"])
    expect(lines(HOME + "é".encode(), 1), ["é"])


def emoji_clusters_are_one_wide_glyph() -> None:
    family = "\U0001F468‍\U0001F469‍\U0001F467"
    thumbs = "\U0001F44D\U0001F3FD"
    flag = "\U0001F1FA\U0001F1F8"
    for cluster in (family, thumbs, flag, "\U0001F642️"):
        expect(lines(HOME + (cluster + "a").encode(), 4), [cluster + " a "])
    expect(lines(HOME + (flag + flag).encode(), 4), [flag + " " + flag + " "])


def column_widths_follow_east_asian_width() -> None:
    for char, width in (("a", 1), ("中", 2), ("Ａ", 2), ("…", 1), ("─", 1),
                        ("́", 0), ("​", 0), ("️", 0), ("\U000E0067", 0), ("\U0001F642", 2),
                        ("⭐", 2), ("⌚", 2), ("✅", 2), ("\U0001F1FA", 2), ("❤", 1), ("\U0001F321", 1)):
        expect((char, vt.column_width(char)), (char, width))


def a_wide_emoji_below_plane_1_takes_two_columns() -> None:
    expect(lines(HOME + "⭐a⌚b".encode(), 6), ["⭐ a⌚ b"])


def an_emoji_presentation_selector_widens_a_narrow_glyph() -> None:
    heart = "❤️"
    expect(lines(HOME + (heart + "a").encode(), 4), [heart + " a "])
    keycap = "1️⃣"
    expect(lines(HOME + (keycap + "a").encode(), 4), [keycap + " a "])
    # Over whatever was in the column it widens into, and into a pending
    # wrap when that column is the last.
    expect(lines(HOME + b"xyz\x1b[1;1H" + heart.encode(), 3), [heart + " z"])
    expect(lines(HOME + ("ab" + heart).encode() + b"c", 4, 2), ["ab" + heart + " ", "c   "])
    # A wide glyph stays two columns, and one in the last column stays one.
    expect(lines(HOME + "⭐️a".encode(), 4), ["⭐️ a "])
    expect(lines(HOME + ("ab" + heart).encode(), 3), ["ab" + heart])


def sgr_and_strings_draw_nothing() -> None:
    styled = b"\x1b[0m\x1b[38;2;1;2;3m\x1b[1ma\x1b[0m"
    osc = b"\x1b]11;rgb:00/00/00\x07\x1b]0;title\x1b\\"
    modes = b"\x1b[?25l\x1b[?2004h\x1b[>1u\x1b[2 q"
    expect(lines(HOME + styled + osc + modes + b"b", 3), ["ab "])


def the_alternate_screen_starts_clear_and_restores_the_main() -> None:
    screen = vt.Screen(3, 1)
    screen.feed(b"abc\x1b[?1049h")
    expect(screen.lines(), ["   "])
    screen.feed(b"\x1b[Hx\x1b[?1049l")
    expect(screen.lines(), ["abc"])


def erasing_clears_and_splits_no_glyph() -> None:
    expect(lines(HOME + b"abcd\x1b[1;3H\x1b[K", 4), ["ab  "])
    expect(lines(HOME + b"abcd\x1b[2J", 4), ["    "])
    expect(lines(HOME + "a中b".encode() + b"\x1b[1;3H\x1b[1K", 4), ["   b"])


def output_fed_in_pieces_reads_as_a_whole() -> None:
    data = HOME + "\x1b[1m中é".encode() + b"\x1b[1;5Hz"
    screen = vt.Screen(5, 1)
    for index in range(len(data)):
        screen.feed(data[index:index + 1])
    expect(screen.lines(), [vt.replay(data, 5, 1)])
    expect(screen.lines(), ["中 é z"])


CASES: list[tuple[str, Callable[[], None]]] = [
    ("text after a wide glyph lands two columns on", text_after_a_wide_glyph_lands_two_columns_on),
    ("a row drawn one column late does not match", a_row_drawn_one_column_late_does_not_match),
    ("CUP and CHA place the cursor", cup_and_cha_place_the_cursor),
    ("the last column holds a pending wrap", the_last_column_holds_a_pending_wrap),
    ("a wide glyph that does not fit wraps whole", a_wide_glyph_that_does_not_fit_wraps_whole),
    ("printing over a wide glyph's half blanks the other", printing_over_a_wide_glyphs_half_blanks_the_other),
    ("a combining mark joins its base", a_combining_mark_joins_its_base),
    ("emoji clusters are one wide glyph", emoji_clusters_are_one_wide_glyph),
    ("column widths follow East Asian Width", column_widths_follow_east_asian_width),
    ("a wide emoji below plane 1 takes two columns", a_wide_emoji_below_plane_1_takes_two_columns),
    ("an emoji presentation selector widens a narrow glyph",
     an_emoji_presentation_selector_widens_a_narrow_glyph),
    ("SGR and strings draw nothing", sgr_and_strings_draw_nothing),
    ("the alternate screen starts clear and restores the main",
     the_alternate_screen_starts_clear_and_restores_the_main),
    ("erasing clears, and splits no glyph", erasing_clears_and_splits_no_glyph),
    ("output fed in pieces reads as a whole", output_fed_in_pieces_reads_as_a_whole),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
