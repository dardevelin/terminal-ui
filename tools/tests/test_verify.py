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


def release_runs_the_gate_whatever_the_tree_holds() -> None:
    assert verify.wants_gate(["--release"], has_source_changes=False)


def release_runs_what_ci_runs_beyond_the_gate() -> None:
    commands = [" ".join(command) for _, command, _ in verify.release_steps()]
    def ran(*fragments: str) -> bool:
        return any(all(fragment in command for fragment in fragments) for command in commands)
    assert ran("swift build", "-c release"), commands
    assert ran("swift test", "--sanitize=thread"), commands
    assert ran("swift build", "--sanitize=thread"), commands
    assert ran("integration_suite.py", ".build-tsan/debug"), commands
    assert ran("storybook_smoke.py", ".build-tsan/debug"), commands
    assert ran("docker", "swift:6.2", "swift build", "--build-tests"), commands
    assert ran("docker", "swift:6.2", "swift test"), commands
    assert ran("linux_harness.sh", "storybook_smoke.py"), commands


def linux_runs_natively_for_this_machine() -> None:
    commands = [" ".join(command) for _, command, _ in verify.release_steps()]
    docker = [command for command in commands if "docker" in command or "linux_harness" in command]
    assert docker and all(verify.LINUX_PLATFORM in command for command in docker), docker
    assert all(verify.LINUX_SCRATCH_PATH in command for command in docker), docker


def an_everyday_gate_runs_none_of_it() -> None:
    assert not verify.wants_release(["--always"])
    assert verify.wants_release(["--release"])


def release_steps_stop_at_the_first_failure() -> None:
    ran: list[str] = []
    def runner(name: str, command: list[str], timeout: int) -> tuple[int, str]:
        ran.append(name)
        return (1, "boom") if name == "two" else (0, "fine")
    steps = [(name, ["true"], 1) for name in ("one", "two", "three")]
    assert verify.run_release_steps(steps, runner) == 2
    assert ran == ["one", "two"], ran


def a_known_issue_does_not_fail_a_release_step_but_an_issue_does() -> None:
    known = "✘ Test run with 3 tests in 1 suite passed after 1.0 seconds with 2 known issues."
    issue = "✘ Test aRowFits() recorded an issue at RowTests.swift:12:9: Expectation failed"
    steps = [("tests", ["true"], 1)]
    assert verify.run_release_steps(steps, lambda *_: (0, known)) == 0
    assert verify.run_release_steps(steps, lambda *_: (0, issue)) == 2


def main_runs_the_release_steps_after_the_gate() -> None:
    called: list[str] = []
    saved = (verify.run_gate, verify.run_release_steps, verify.reap_dead_apps)
    verify.run_gate = lambda: called.append("gate") or 0
    verify.run_release_steps = lambda steps, runner: called.append("release") or 0
    verify.reap_dead_apps = lambda *_: None
    try:
        assert verify.main(["--release"]) == 0
        assert called == ["gate", "release"], called
        called.clear()
        assert verify.main(["--always"]) == 0
        assert called == ["gate"], called
    finally:
        verify.run_gate, verify.run_release_steps, verify.reap_dead_apps = saved


CASES: list[tuple[str, Callable[[], None]]] = [
    ("release steps stop at the first failure", release_steps_stop_at_the_first_failure),
    ("a known issue does not fail a release step, but an issue does",
     a_known_issue_does_not_fail_a_release_step_but_an_issue_does),
    ("main runs the release steps after the gate", main_runs_the_release_steps_after_the_gate),
    ("linux runs natively for this machine", linux_runs_natively_for_this_machine),
    ("--release runs the gate whatever the tree holds", release_runs_the_gate_whatever_the_tree_holds),
    ("--release runs what CI runs beyond the gate", release_runs_what_ci_runs_beyond_the_gate),
    ("an everyday gate runs none of it", an_everyday_gate_runs_none_of_it),
    ("a failure names what failed above the tail", a_failure_names_what_failed_above_the_tail),
    ("a failure with no marked lines shows its tail", a_failure_with_no_marked_lines_shows_its_tail),
    ("a turn with no source changes skips", a_turn_with_no_source_changes_skips),
    ("a turn with source changes runs", a_turn_with_source_changes_runs),
    ("--always runs a clean tree", always_runs_a_clean_tree),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
