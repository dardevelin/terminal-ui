#!/usr/bin/env python3
"""`swtui record start | mark | stop | status` record a running debug build.

They reach the app as `swtui ctl` does — `--pid`, `--dir`, or the one app
running from this checkout, refusing to pick when several run — and drive
its recorder over the control socket:

1. A recording started, marked and stopped from the command line holds the
   screen at each mark, and the app tells a mark's frame by its number: a
   mark is answered after every key sent before it is drawn.
2. With no recording open, `mark` and `stop` fail, saying so.
3. A relative path is the caller's directory's, not the app's.
4. With two apps running and none named, it refuses and lists them.

The app is spawned as one being recorded is, told it runs in an xterm with
24-bit colour, which the log's header keeps.

Run::

    swift build && python3 tools/scripts/test_record_cli.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.cases import run_cases  # noqa: E402
from terminalui.client import Client  # noqa: E402
from terminalui.runner import build_dir_path, spawn_and_connect  # noqa: E402


REPO_ROOT = Path(__file__).resolve().parents[2]
SWTUI_BIN = build_dir_path() / "swtui"


def swtui(*args: str, cwd: Path = REPO_ROOT) -> subprocess.CompletedProcess:
    """Run swtui from `cwd` — the checkout, by default, which is where it
    looks for running apps."""
    return subprocess.run([str(SWTUI_BIN), *args], cwd=str(cwd), capture_output=True, text=True,
                          check=False, timeout=30)


def record(app: Client, *args: str, cwd: Path = REPO_ROOT) -> dict[str, str]:
    """`swtui record <args> --pid <app>`, which must succeed; its
    `key=value` answer, the path last and whole."""
    result = swtui("record", *args, "--pid", str(app.pid), cwd=cwd)
    assert result.returncode == 0, f"swtui record {' '.join(args)}: rc={result.returncode} {result.stderr!r}"
    head, _, path = result.stdout.strip().partition(" path=")
    fields = dict(field.split("=", 1) for field in head.split())
    if path:
        fields["path"] = path
    return fields


def title_at(log: Path, label: str) -> str:
    """The Storybook page title `swtui record dump --at label` shows."""
    dump = swtui("record", "dump", str(log), "--at", label)
    assert dump.returncode == 0, f"dump --at {label}: {dump.stderr}"
    x, y, width, _ = Client._STORYBOOK_TITLE_RECT
    rows = dump.stdout.splitlines()
    return rows[y][x:x + width].strip() if len(rows) > y else ""


def a_recording_is_started_marked_and_stopped(app: Client, scratch: Path) -> None:
    log = scratch / "walk.tuirec"
    first_title = app.storybook_page_title()
    started = record(app, "start", str(log), "--label", "start", "--hold", "1.5s")
    assert started["active"] == "true" and started["marks"] == "1", started
    assert started["path"] == str(log), started
    assert record(app, "status")["active"] == "true"

    # Keys with nothing read back between them and the mark: the mark is
    # answered once they are drawn, so it names the frame that drew them.
    before = app.frame_number()
    app.send_key("down")
    app.send_key("down")
    marked = record(app, "mark", "two-down", "--hold", "400ms")
    assert int(marked["frame"]) > before, f"the mark's frame {marked['frame']} is not after {before}"
    stopped = record(app, "stop")
    assert stopped["active"] == "false" and stopped["marks"] == "2", stopped
    assert record(app, "status") == stopped, "status describes the recording just stopped"

    lines = [json.loads(line) for line in log.read_text().splitlines()]
    assert lines[0]["env"] == {"TERM": "xterm-256color", "COLORTERM": "truecolor"}, lines[0]
    mark_at = next(index for index, line in enumerate(lines) if line.get("mark") == "two-down")
    assert lines[mark_at].get("hold") == 400, lines[mark_at]
    shown = [line["frame"] for line in lines[:mark_at] if "frame" in line][-1]
    assert shown == int(marked["frame"]), f"the log's frame before the mark is {shown}, the app said {marked['frame']}"
    assert lines[-1].get("end") is True and lines[-1]["frames"] == int(stopped["frames"]), lines[-1]

    assert title_at(log, "start") == first_title
    moved_to = app.storybook_page_title()
    assert moved_to != first_title, "the keys did not move the page"
    assert title_at(log, "two-down") == moved_to


def with_nothing_recording_mark_and_stop_fail(app: Client, _scratch: Path) -> None:
    for verb in (["mark", "nothing"], ["stop"]):
        result = swtui("record", *verb, "--pid", str(app.pid))
        assert result.returncode == 1, f"record {verb[0]}: rc={result.returncode} {result.stdout!r}"
        assert "no recording is active" in result.stderr, result.stderr


def a_relative_path_is_the_callers(app: Client, scratch: Path) -> None:
    # Named by its socket's directory, which reaches the app from anywhere:
    # by pid, swtui looks among the apps of the checkout it runs in.
    socket_dir = str(Path(app.socket_path).parent)
    started = swtui("record", "start", "relative.tuirec", "--dir", socket_dir, cwd=scratch)
    assert started.returncode == 0, started.stderr
    assert swtui("record", "stop", "--dir", socket_dir).returncode == 0
    assert (scratch / "relative.tuirec").is_file(), f"no log in {scratch}: {list(scratch.iterdir())}"
    assert not (REPO_ROOT / "relative.tuirec").exists(), "the log went to the app's directory"


def several_apps_and_none_named_is_refused(app: Client, _scratch: Path) -> None:
    with spawn_and_connect("Storybook", inherit_terminal=False) as (second, _):
        result = swtui("record", "status")
        assert result.returncode == 2, f"rc={result.returncode} {result.stdout!r} {result.stderr!r}"
        assert f"--pid {app.pid}" in result.stderr and f"--pid {second.pid}" in result.stderr, result.stderr


CASES: list[tuple[str, Callable[[Client, Path], None]]] = [
    ("a recording is started, marked and stopped", a_recording_is_started_marked_and_stopped),
    ("with nothing recording, mark and stop fail", with_nothing_recording_mark_and_stop_fail),
    ("a relative path is the caller's", a_relative_path_is_the_callers),
    ("several apps and none named is refused", several_apps_and_none_named_is_refused),
]


if __name__ == "__main__":
    # One app for every case: spawning one per case would cost a sanitized
    # build most of the script's time limit.
    with tempfile.TemporaryDirectory(prefix="terminalui-record-cli-") as scratch, \
            spawn_and_connect("Storybook", inherit_terminal=False) as (_, app):
        code = run_cases([(name, lambda case=case: case(app, Path(scratch).resolve()))
                          for name, case in CASES])
    sys.exit(code)
