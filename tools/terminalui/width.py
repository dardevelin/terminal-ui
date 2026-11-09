"""How many columns a terminal gives one code point: the rules the
framework's generated width table and the terminal model share.

UAX #11's East_Asian_Width is the count terminals share: xterm's
``wcwidth``, VTE, kitty, iTerm2, WezTerm and Ghostty draw a code point two
columns wide when EastAsianWidth.txt calls it W or F — each by the Unicode
version it was built with. On top of it:

- 0 for nonspacing and enclosing marks (General_Category Mn and Me), which
  draw on the glyph before them, as ``wcwidth`` has it — a mark first, even
  the few EastAsianWidth.txt calls W (U+302A..U+302D, U+3099..U+309A) —
  and for the ignorable format characters in ``ZERO_WIDTH_FORMAT``.
- 2 for the regional indicators, which EastAsianWidth.txt calls N.
- 1 for the rest. Ambiguous (A) included: UAX #11 §5 resolves it narrow
  outside a legacy East Asian context, and terminals draw it narrow unless
  told otherwise.

``tools/scripts/generate_width_table.py`` applies these to an
EastAsianWidth.txt to write ``Character.displayWidth``'s table, and
``column_width`` applies them to Python's own ``unicodedata``, which carries
the Unicode version of the Python running it.
"""

from __future__ import annotations

import unicodedata

WIDE_VALUES = ("W", "F")
ZERO_WIDTH_CATEGORIES = ("Mn", "Me")
# The format characters (General_Category Cf) that are also
# Default_Ignorable_Code_Point (DerivedCoreProperties.txt), which draw
# nothing: the Arabic letter mark, the Mongolian vowel separator, zero width
# space, ZWNJ, ZWJ and the bidi marks, embeddings and isolates, the word
# joiner and invisible operators, the byte order mark, shorthand format
# controls, musical symbol beams, and the tag characters of an emoji tag
# sequence (UTS #51 §2.3). Left drawn, as ``wcwidth`` leaves them: U+00AD
# SOFT HYPHEN, whose hyphen a terminal shows, and the Cf characters that are
# not ignorable — the prepended concatenation marks (U+0600…), which span
# the digits after them, the interlinear annotation characters and the
# Egyptian hieroglyph format controls.
ZERO_WIDTH_FORMAT = ((0x061C, 0x061C), (0x180E, 0x180E), (0x200B, 0x200F), (0x202A, 0x202E),
                     (0x2060, 0x2064), (0x2066, 0x206F), (0xFEFF, 0xFEFF), (0x1BCA0, 0x1BCA3),
                     (0x1D173, 0x1D17A), (0xE0001, 0xE0001), (0xE0020, 0xE007F))
# UTS #51 gives the regional indicators Emoji_Presentation, and a pair is a
# flag every terminal draws in two columns — one glyph, or two narrow
# letters. The framework draws the pair as wide as its first indicator, so
# an indicator is 2.
REGIONAL_INDICATORS = (0x1F1E6, 0x1F1FF)


def is_zero_width_format(code: int) -> bool:
    return any(first <= code <= last for first, last in ZERO_WIDTH_FORMAT)


def is_regional_indicator(code: int) -> bool:
    return REGIONAL_INDICATORS[0] <= code <= REGIONAL_INDICATORS[1]


def width_of(code: int, east_asian_width: str, category: str) -> int:
    """The columns of a code point with these UCD property values: 0, 1 or 2."""
    if category in ZERO_WIDTH_CATEGORIES or is_zero_width_format(code):
        return 0
    if east_asian_width in WIDE_VALUES or is_regional_indicator(code):
        return 2
    return 1


def column_width(char: str) -> int:
    """Columns a single code point takes on a terminal, by ``unicodedata``."""
    return width_of(ord(char), unicodedata.east_asian_width(char), unicodedata.category(char))
