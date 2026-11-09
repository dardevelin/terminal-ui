"""A terminal reduced to where an app's output puts each glyph.

An app's buffer can hold one picture while the bytes it sends a terminal
draw another: a wide glyph's second cell sent as a character of its own put
everything after it on its row one column late, and every test that read
the buffer passed. ``Screen`` is what a terminal does with those bytes, so a
case can require the two to agree.

What it models, and nothing more:

- Printable text, advancing by each code point's column width: 2 for East
  Asian Wide and Fullwidth (UAX #11) and for the plane-1 emoji blocks the
  framework draws two wide, 0 for combining and enclosing marks and the
  zero-width format characters, 1 for everything else. A zero-width code
  point joins the glyph before it, as does whatever follows a ZWJ, an emoji
  skin-tone modifier, and the second of a pair of regional indicators —
  a grapheme-aware terminal draws each of those clusters as one glyph.
- Auto-wrap (DECAWM) with the pending wrap of the last column, as xterm
  does: a glyph printed there leaves the cursor on it until the next one.
- A glyph printed over either half of a wide glyph blanks the other half.
- C0: CR, LF (and VT, FF), BS, HT. ESC 7 / ESC 8, ESC c.
- CSI (ECMA-48 §5.4): CUP / HVP, CHA, VPA, CUU / CUD / CUF / CUB, ED, EL;
  DEC private modes 47 / 1047 / 1049 switch to the alternate screen, cleared.
  Every other control sequence — SGR among them — is consumed and ignored:
  this is a model of placement, not of colour.
- OSC, DCS, APC, PM and SOS strings are consumed up to BEL or ST.

Rows read back one string per row with one entry per column — the right
half of a wide glyph a space — the shape ``query_cells`` dumps an app's
buffer in, so ``Screen.text()`` compares with ``Client.text()`` directly.
"""

from __future__ import annotations

import codecs
import unicodedata
from typing import Optional

ESC = "\x1b"
BEL = "\x07"
BACKSPACE = "\x08"
TAB = "\t"
LINE_FEEDS = ("\n", "\x0b", "\x0c")
CARRIAGE_RETURN = "\r"
DELETE = "\x7f"
ZWJ = "‍"
# HT moves to the next multiple of eight, xterm's default tab stops.
TAB_STOP = 8
# Code points with no width that `unicodedata.category` files under Cf with
# others that have one (U+00AD SOFT HYPHEN is drawn): zero-width space and
# joiners, the directional marks, word joiner and invisible operators, BOM.
ZERO_WIDTH_FORMAT = frozenset(
    [chr(cp) for cp in range(0x200B, 0x2010)] + [chr(cp) for cp in range(0x2060, 0x2065)] + ["﻿"])
# The framework draws every code point in these plane-1 blocks two wide
# (`Character.displayWidth`), whether or not UAX #11 calls it Wide.
WIDE_EMOJI_BLOCKS = ((0x1F000, 0x1F2FF), (0x1F300, 0x1FAFF))
EMOJI_MODIFIERS = range(0x1F3FB, 0x1F400)
REGIONAL_INDICATORS = range(0x1F1E6, 0x1F200)
# DEC private modes that switch to the alternate screen buffer.
ALTERNATE_SCREEN_MODES = ("47", "1047", "1049")
# ECMA-48 §5.4: a control sequence's parameter bytes are 0x30–0x3F, its
# intermediates 0x20–0x2F and its final byte 0x40–0x7E.
CSI_FINAL = range(0x40, 0x7F)


def column_width(char: str) -> int:
    """Columns a single code point takes on a terminal: 0, 1 or 2."""
    code = ord(char)
    if char in ZERO_WIDTH_FORMAT or unicodedata.category(char) in ("Mn", "Me"):
        return 0
    if any(low <= code <= high for low, high in WIDE_EMOJI_BLOCKS):
        return 2
    return 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1


class Screen:
    """A grid of ``columns`` × ``rows`` cells that output bytes are fed to,
    in as many pieces as they arrive in."""

    def __init__(self, columns: int, rows: int) -> None:
        self.columns = columns
        self.rows = rows
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self._state = self._ground
        self._sequence = ""
        self._reset()

    def _reset(self) -> None:
        """RIS: the screen and cursor as a terminal starts them."""
        self._main = self._blank_grid()
        self._alternate: Optional[list[list[Optional[str]]]] = None
        self.row = 0
        self.col = 0
        self._pending_wrap = False
        self._saved = (0, 0)
        # What the code point before decides about the next one: that it
        # joins the glyph before it.
        self._joins_next = False
        self._regional_indicator_open = False

    # -- reading --

    @property
    def grid(self) -> list[list[Optional[str]]]:
        """The cells shown: a glyph's text, or None for the right half of
        the wide glyph to its left."""
        return self._alternate if self._alternate is not None else self._main

    def lines(self) -> list[str]:
        """Each row as one string, one entry per column."""
        return ["".join(" " if cell is None else cell for cell in row) for row in self.grid]

    def text(self) -> str:
        return "\n".join(self.lines())

    # -- feeding --

    def feed(self, data: bytes) -> None:
        for char in self._decoder.decode(data):
            self._state(char)

    def _ground(self, char: str) -> None:
        if char == ESC:
            self._state = self._escape
        elif char == CARRIAGE_RETURN:
            self.col = 0
            self._pending_wrap = False
        elif char in LINE_FEEDS:
            self._line_feed()
        elif char == BACKSPACE:
            self.col = max(0, self.col - 1)
            self._pending_wrap = False
        elif char == TAB:
            self.col = min(self.columns - 1, (self.col // TAB_STOP + 1) * TAB_STOP)
            self._pending_wrap = False
        elif char < " " or char == DELETE or "\x80" <= char <= "\x9f":
            pass
        else:
            self._print(char)

    def _escape(self, char: str) -> None:
        self._sequence = ""
        if char == "[":
            self._state = self._control_sequence
        elif char in "]PX^_":
            self._state = self._string
        elif " " <= char <= "/":
            self._state = self._escape_intermediate
        else:
            self._state = self._ground
            if char == "7":
                self._saved = (self.row, self.col)
            elif char == "8":
                self.row, self.col = self._saved
                self._pending_wrap = False
            elif char == "c":
                self._reset()

    def _escape_intermediate(self, char: str) -> None:
        if not " " <= char <= "/":
            self._state = self._ground

    def _string(self, char: str) -> None:
        if char == BEL:
            self._state = self._ground
        elif char == ESC:
            self._state = self._string_escape

    def _string_escape(self, char: str) -> None:
        # ST is ESC \; any other ESC aborts the string and starts anew.
        if char == "\\":
            self._state = self._ground
        else:
            self._escape(char)

    def _control_sequence(self, char: str) -> None:
        if ord(char) in CSI_FINAL:
            self._state = self._ground
            self._control(char, self._sequence)
        elif char == ESC:
            self._state = self._escape
        else:
            self._sequence += char

    # -- control functions --

    def _control(self, final: str, parameters: str) -> None:
        if parameters.startswith("?"):
            if final in "hl":
                self._private_mode(parameters[1:].split(";"), final == "h")
            return
        if parameters[:1] in ("<", "=", ">") or any(" " <= c <= "/" for c in parameters):
            return
        numbers = [int(p) if p.isdigit() else 0 for p in parameters.split(";")]

        def number(position: int, default: int = 1) -> int:
            value = numbers[position] if position < len(numbers) else 0
            return value or default

        if final in "Hf":
            self._move_to(number(0) - 1, number(1) - 1)
        elif final == "G":
            self._move_to(self.row, number(0) - 1)
        elif final == "d":
            self._move_to(number(0) - 1, self.col)
        elif final == "A":
            self._move_to(self.row - number(0), self.col)
        elif final == "B":
            self._move_to(self.row + number(0), self.col)
        elif final == "C":
            self._move_to(self.row, self.col + number(0))
        elif final == "D":
            self._move_to(self.row, self.col - number(0))
        elif final == "J":
            self._erase_display(number(0, default=0))
        elif final == "K":
            self._erase_line(number(0, default=0))

    def _private_mode(self, modes: list[str], on: bool) -> None:
        if not any(mode in ALTERNATE_SCREEN_MODES for mode in modes):
            return
        if on and self._alternate is None:
            self._saved = (self.row, self.col)
            self._alternate = self._blank_grid()
        elif not on and self._alternate is not None:
            self._alternate = None
            self.row, self.col = self._saved
        self._pending_wrap = False

    def _move_to(self, row: int, col: int) -> None:
        self.row = min(max(row, 0), self.rows - 1)
        self.col = min(max(col, 0), self.columns - 1)
        self._pending_wrap = False
        self._joins_next = False
        self._regional_indicator_open = False

    def _erase_display(self, mode: int) -> None:
        if mode in (2, 3):
            self.grid[:] = self._blank_grid()
            return
        rows = range(self.row + 1, self.rows) if mode == 0 else range(0, self.row)
        for row in rows:
            self.grid[row] = [" "] * self.columns
        self._erase_line(mode)

    def _erase_line(self, mode: int) -> None:
        line = self.grid[self.row]
        start, stop = {0: (self.col, self.columns), 1: (0, self.col + 1)}.get(mode, (0, self.columns))
        # A wide glyph the erase cuts in two leaves no half behind.
        if 0 < start < self.columns and line[start] is None:
            line[start - 1] = " "
        if stop < self.columns and line[stop] is None:
            line[stop] = " "
        for col in range(start, stop):
            line[col] = " "

    # -- printing --

    def _print(self, char: str) -> None:
        code = ord(char)
        joins = self._joins_next or (code in EMOJI_MODIFIERS) or \
            (code in REGIONAL_INDICATORS and self._regional_indicator_open)
        width = 0 if joins else column_width(char)
        self._joins_next = char == ZWJ
        if code in REGIONAL_INDICATORS:
            self._regional_indicator_open = not joins
        elif width:
            self._regional_indicator_open = False
        if width == 0:
            self._attach(char)
            return
        if self._pending_wrap or self.col + width > self.columns:
            self.col = 0
            self._pending_wrap = False
            self._line_feed()
        line = self.grid[self.row]
        self._erase_cell(self.col)
        if width == 2:
            self._erase_cell(self.col + 1)
            line[self.col + 1] = None
        line[self.col] = char
        if self.col + width >= self.columns:
            self.col = self.columns - 1
            self._pending_wrap = True
        else:
            self.col += width

    def _attach(self, char: str) -> None:
        """Join a zero-width code point onto the glyph left of the cursor —
        the cursor's own cell while a wrap is pending."""
        line = self.grid[self.row]
        base = self.col if self._pending_wrap else self.col - 1
        if base > 0 and line[base] is None:
            base -= 1
        if base >= 0 and line[base] is not None:
            line[base] += char

    def _erase_cell(self, col: int) -> None:
        """Blank the cell a glyph is about to cover, and whatever half of a
        wide glyph that leaves behind."""
        if col >= self.columns:
            return
        line = self.grid[self.row]
        if line[col] is None and col > 0:
            line[col - 1] = " "
        if col + 1 < self.columns and line[col + 1] is None:
            line[col + 1] = " "
        line[col] = " "

    def _line_feed(self) -> None:
        self._pending_wrap = False
        if self.row + 1 < self.rows:
            self.row += 1
        else:
            del self.grid[0]
            self.grid.append([" "] * self.columns)

    def _blank_grid(self) -> list[list[Optional[str]]]:
        return [[" "] * self.columns for _ in range(self.rows)]


def replay(data: bytes, columns: int, rows: int) -> str:
    """The screen a ``columns`` × ``rows`` terminal shows after ``data``,
    as ``Screen.text()``."""
    screen = Screen(columns, rows)
    screen.feed(data)
    return screen.text()
