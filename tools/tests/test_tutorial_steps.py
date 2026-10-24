#!/usr/bin/env python3
"""The tutorial's step list must cover every step, and drive each preview
with what a recording can press.

``tools/terminalui/tutorial.py`` lists, for each code step, the stages
``check_tutorial_steps.py`` drives it through and the one its preview
captures. A step file with no entry would gate nothing; an entry with no
file would fail the check for the wrong reason; and a click before a
preview's stage could not be recorded, since vhs only types.

Run::

    python3 tools/tests/test_tutorial_steps.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_tutorial_steps as checker  # noqa: E402
import record_media  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402
from terminalui.tutorial import STEPS, Click, Press, Stage, Step, Type, step_files  # noqa: E402


def every_step_file_is_listed_once() -> None:
    listed = [step.name for step in STEPS]
    files = [path.stem for path in step_files()]
    assert sorted(listed) == files, f"listed but no file: {sorted(set(listed) - set(files))}; " \
                                    f"file but not listed: {sorted(set(files) - set(listed))}"
    assert len(set(listed)) == len(listed), "a step is listed twice"


def every_preview_can_be_recorded() -> None:
    for step in STEPS:
        assert 0 <= step.preview < len(step.stages), f"{step.name}: no stage {step.preview}"
        assert not any(stage.relaunch for stage in step.stages[:step.preview + 1]), step.name
        for action in step.preview_keys():
            record_media.vhs_command(action)


def every_stage_checks_something() -> None:
    for step in STEPS:
        for index, stage in enumerate(step.stages):
            assert stage.shows or stage.hides or stage.quits, f"{step.name} stage {index + 1}"


def a_quit_ends_the_steps() -> None:
    for step in STEPS:
        assert not any(stage.quits for stage in step.stages[:-1]), step.name


def a_click_has_no_key_in_a_recording() -> None:
    try:
        record_media.vhs_command(Click("Ship it"))
    except ValueError:
        return
    raise AssertionError("a click became a vhs command")


def keys_become_vhs_commands() -> None:
    assert record_media.vhs_command(Press("tab", ("shift",))) == "Shift+Tab"
    assert record_media.vhs_command(Type("Feed the fox")) == 'Type "Feed the fox"'


def a_preview_is_driven_by_the_keys_up_to_its_stage() -> None:
    step = Step("x", [Stage([Press("down")]), Stage([Press("enter")]), Stage([Press("space")])],
                preview=1)
    assert step.preview_keys() == [Press("down"), Press("enter")]


def a_relaunch_starts_a_new_run() -> None:
    first, second, third = Stage([Press("down")]), Stage(relaunch=True), Stage()
    runs = checker.launches(Step("x", [first, second, third]))
    assert runs == [[(0, first)], [(1, second), (2, third)]], runs


def a_click_lands_where_its_text_is_drawn() -> None:
    assert checker.locate("Tasks\n  ☐ Ship it\n", "Ship it") == (4, 1)


CASES: list[tuple[str, Callable[[], None]]] = [
    ("every step file is listed once", every_step_file_is_listed_once),
    ("every preview can be recorded", every_preview_can_be_recorded),
    ("every stage checks something", every_stage_checks_something),
    ("a quit ends the steps", a_quit_ends_the_steps),
    ("a click has no key in a recording", a_click_has_no_key_in_a_recording),
    ("keys become vhs commands", keys_become_vhs_commands),
    ("a preview is driven by the keys up to its stage", a_preview_is_driven_by_the_keys_up_to_its_stage),
    ("a relaunch starts a new run", a_relaunch_starts_a_new_run),
    ("a click lands where its text is drawn", a_click_lands_where_its_text_is_drawn),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
