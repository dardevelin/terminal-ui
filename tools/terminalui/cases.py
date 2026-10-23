"""Run a harness script's cases and report them, one line each.

Each case is a name and a function that raises to fail: an
``AssertionError`` with its message, anything else with its type too.
Every case runs, whichever fail."""

from __future__ import annotations

from typing import Callable, Optional, Sequence


def run_cases(cases: Sequence[tuple[str, Callable[[], None]]]) -> int:
    """Run ``cases`` in order, print ``[OK]`` or ``[FAIL]`` for each and
    then how many passed; the exit status for the script."""
    failures = 0
    for name, case in cases:
        failure = _failure(case)
        if failure is None:
            print(f"[OK] {name}")
        else:
            print(f"[FAIL] {name} — {failure}")
            failures += 1
    print("---")
    print(f"{len(cases) - failures}/{len(cases)} pass")
    return 1 if failures else 0


def _failure(case: Callable[[], None]) -> Optional[str]:
    try:
        case()
    except AssertionError as exc:
        return str(exc)
    except Exception as exc:  # noqa: BLE001 - a case's failure, reported
        return f"{type(exc).__name__}: {exc}"
    return None
