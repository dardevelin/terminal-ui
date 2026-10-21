#!/usr/bin/env python3
"""check_tracker_ids.py must catch an id wherever the rule names one.

CLAUDE.md forbids issue identifiers in file names, code, comments and
commit messages. Each case builds a throwaway git repository holding one
kind of leak and asserts the checker reports it — or, for the cases that
must stay quiet, that it does not.

Run::

    python3 tools/scripts/test_check_tracker_ids.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_tracker_ids as checker  # noqa: E402
from kanban import ID_PREFIX  # noqa: E402

BOARD_ID = f"{ID_PREFIX}-12"


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)


def repo(files: dict[str, bytes], message: str = "Initial") -> Path:
    root = Path(tempfile.mkdtemp())
    git(root, "init", "-q")
    for name, content in files.items():
        (root / name).write_bytes(content)
    git(root, "add", "-A")
    git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
        "--allow-empty", "-m", message)
    return root


def finds_an_id_in_a_comment() -> None:
    root = repo({"a.swift": f"// see {BOARD_ID}\n".encode()})
    assert checker.tree_findings(root) == [f"a.swift:1: {BOARD_ID}"]


def finds_an_id_in_a_file_name() -> None:
    root = repo({f"{BOARD_ID}.md": b"notes\n"})
    assert checker.tree_findings(root) == [f"{BOARD_ID}.md: the file name"]


def finds_a_linear_id() -> None:
    root = repo({"a.py": b"x = 1  # HYP" b"-7\n"})
    assert checker.tree_findings(root) == ["a.py:1: HYP" "-7"]


def scans_a_file_with_one_bad_byte() -> None:
    root = repo({"a.md": b"caf\xe9\n" + f"{BOARD_ID}\n".encode()})
    assert checker.tree_findings(root) == [f"a.md:2: {BOARD_ID}"]


def skips_binaries() -> None:
    root = repo({"a.png": b"\x89PNG\0\0" + BOARD_ID.encode()})
    assert checker.tree_findings(root) == []


def ignores_standards_citations() -> None:
    root = repo({"a.swift": b"// UTF-8, ECMA-48, RFC-1951, SHA-256\n"})
    assert checker.tree_findings(root) == []


def finds_an_id_in_a_commit_message() -> None:
    root = repo({"a.txt": b"x\n"})
    (root / "a.txt").write_bytes(b"y\n")
    git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
        "-am", f"Fix the thing\n\nCloses {BOARD_ID}.")
    findings = checker.commit_findings("HEAD~1..HEAD", root)
    assert len(findings) == 1 and findings[0].endswith(f": {BOARD_ID}"), findings


def commits_outside_the_range_are_not_checked() -> None:
    root = repo({"a.txt": b"x\n"}, message=f"Old {BOARD_ID}")
    (root / "a.txt").write_bytes(b"y\n")
    git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
        "-am", "Clean subject")
    assert checker.commit_findings("HEAD~1..HEAD", root) == []


CASES: list[tuple[str, Callable[[], None]]] = [
    ("finds an id in a comment", finds_an_id_in_a_comment),
    ("finds an id in a file name", finds_an_id_in_a_file_name),
    ("finds a Linear id", finds_a_linear_id),
    ("scans a file with one bad byte", scans_a_file_with_one_bad_byte),
    ("skips binaries", skips_binaries),
    ("ignores standards citations", ignores_standards_citations),
    ("finds an id in a commit message", finds_an_id_in_a_commit_message),
    ("commits outside the range are not checked", commits_outside_the_range_are_not_checked),
]


def main() -> int:
    failures = 0
    for name, case in CASES:
        try:
            case()
            print(f"[OK] {name}")
        except Exception as error:  # noqa: BLE001 — report every case
            failures += 1
            print(f"[FAIL] {name} — {error!r}")
    print("---")
    print(f"{len(CASES) - failures}/{len(CASES)} pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
