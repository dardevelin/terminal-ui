#!/usr/bin/env python3
"""`swtui record render --format png|gif` takes its settings from the flags
and from `[render]` in `.terminalui/terminalui.toml`, a flag winning.

It renders the hand-written logs the Swift tests use
(``Tests/TerminalUIRecordingTests/Fixtures``), from a project directory of
its own, so the settings file is the case's:

1. `[render]` sets the font size and padding a PNG is drawn at, and a flag
   on the command line wins over it.
2. `missing_glyph = "fail"` refuses a picture with a glyph no font has,
   naming its code point and frame; `--missing-glyph box` draws it, warned.
3. A key `[render]` does not take, or a line in it the parser cannot read
   (a bare decimal), is an error naming its line.
4. `--font system` is refused until the system engine is built; `--font
   PATH` draws with that file, and a missing one is named.
5. A PNG is a still: without `--at` or `--frame` it is refused.

Run::

    swift build && python3 tools/scripts/test_record_render.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import images  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402
from terminalui.runner import build_dir_path  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
SWTUI_BIN = build_dir_path() / "swtui"
FIXTURES = REPO_ROOT / "Tests" / "TerminalUIRecordingTests" / "Fixtures"
BUNDLED_REGULAR = REPO_ROOT / "tools" / "fonts" / "JetBrainsMono" / "JetBrainsMono-Regular.ttf"

# The `styles` log is 16 × 2 cells; a JetBrains Mono cell is 0.6 × 1.2 of
# the font's size.
STYLES_COLUMNS, STYLES_ROWS = 16, 2

# Where each case's project directory goes; removed when the script ends.
SCRATCH = tempfile.TemporaryDirectory(prefix="terminalui-render-")


def render(project: Path, log: str, *args: str) -> tuple[subprocess.CompletedProcess, Path]:
    """`swtui record render` of fixture `log` from `project`, into it."""
    output = project / "picture"
    if output.exists():
        output.unlink()
    result = subprocess.run([str(SWTUI_BIN), "record", "render", str(FIXTURES / f"{log}.tuirec"), *args,
                             "-o", str(output)], cwd=str(project), capture_output=True, text=True,
                            check=False, timeout=60)
    return result, output


def project_with(settings: str) -> Path:
    """A project directory whose `.terminalui/terminalui.toml` is `settings`."""
    project = Path(tempfile.mkdtemp(dir=SCRATCH.name))
    (project / ".terminalui").mkdir()
    (project / ".terminalui" / "terminalui.toml").write_text(settings)
    return project


def png_size(path: Path) -> tuple[int, int]:
    _, pixels, _ = images.decode_png(path.read_bytes())
    return len(pixels[0]), len(pixels)


def the_settings_file_sets_the_size_and_a_flag_wins() -> None:
    project = project_with("[render]\nfont_size = 30\npadding = 0\nline_height = \"1.2\"\n")
    result, output = render(project, "styles", "--format", "png", "--at", "styled")
    assert result.returncode == 0, result.stderr
    assert png_size(output) == (STYLES_COLUMNS * 18, STYLES_ROWS * 36), png_size(output)
    result, output = render(project, "styles", "--format", "png", "--at", "styled", "--font-size", "15")
    assert result.returncode == 0, result.stderr
    assert png_size(output) == (STYLES_COLUMNS * 9, STYLES_ROWS * 18), png_size(output)


def a_missing_glyph_fails_or_is_a_box_as_asked() -> None:
    project = project_with("[render]\nmissing_glyph = \"fail\"\n")
    result, output = render(project, "wide", "--format", "png", "--at", "cjk")
    assert result.returncode != 0, "a missing glyph under fail rendered"
    assert not output.exists(), "a refused picture was written"
    assert "U+754C 界 in frame 1" in result.stderr and "U+9762" in result.stderr, result.stderr
    result, output = render(project, "wide", "--format", "png", "--at", "cjk", "--missing-glyph", "box")
    assert result.returncode == 0, result.stderr
    assert "drawn as boxes" in result.stderr and "U+754C" in result.stderr, result.stderr
    assert output.exists()


def an_unknown_key_or_an_unreadable_line_names_its_line() -> None:
    result, _ = render(project_with("[render]\nfont_size = 15\nfont_colour = \"red\"\n"),
                       "styles", "--format", "png", "--at", "styled")
    assert result.returncode != 0 and "line 3" in result.stderr and "font_colour" in result.stderr, result.stderr
    result, _ = render(project_with("[trace]\nenabled = true\n\n[render]\nline_height = 1.2\n"),
                       "styles", "--format", "png", "--at", "styled")
    assert result.returncode != 0 and "line 5" in result.stderr, result.stderr


def the_system_font_is_refused_and_a_font_file_is_used() -> None:
    project = project_with("")
    result, _ = render(project, "styles", "--format", "png", "--at", "styled", "--font", "system")
    assert result.returncode != 0 and "--font bundled" in result.stderr, result.stderr
    result, output = render(project, "styles", "--format", "gif", "--font", str(BUNDLED_REGULAR))
    assert result.returncode == 0, result.stderr
    assert output.read_bytes()[:6] == b"GIF89a"
    result, _ = render(project, "styles", "--format", "png", "--at", "styled", "--font", str(project / "none.ttf"))
    assert result.returncode != 0 and "none.ttf" in result.stderr, result.stderr


def a_png_without_a_moment_is_refused() -> None:
    result, _ = render(project_with(""), "styles", "--format", "png")
    assert result.returncode != 0 and "--at" in result.stderr, result.stderr


CASES: list[tuple[str, Callable[[], None]]] = [
    ("[render] sets the size, and a flag wins", the_settings_file_sets_the_size_and_a_flag_wins),
    ("a missing glyph fails or is a box, as asked", a_missing_glyph_fails_or_is_a_box_as_asked),
    ("an unknown key or an unreadable line names its line", an_unknown_key_or_an_unreadable_line_names_its_line),
    ("--font system is refused, and a font file is used", the_system_font_is_refused_and_a_font_file_is_used),
    ("a PNG without --at or --frame is refused", a_png_without_a_moment_is_refused),
]


if __name__ == "__main__":
    with SCRATCH:
        code = run_cases(CASES)
    sys.exit(code)
