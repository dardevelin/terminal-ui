#!/usr/bin/env python3
"""No issue-tracker identifier appears in the repository or its new commits.

Trackers rot and code outlives them: a comment that points at a ticket stops
meaning anything the day the tracker moves, and the board's ids are working
state that is never committed. What a ticket taught belongs in the code, a
test or a document, written out — and so does its structure: a slice, phase
or epic name is the tracker's, not the code's. This check fails on any tracked
file — its name or its text — that names an id from one of the trackers this
project has used, and with ``--commits`` on any commit message in a range.

Run::

    python3 tools/scripts/check_tracker_ids.py
    python3 tools/scripts/check_tracker_ids.py --commits origin/main..HEAD

Exit 0 when nothing names one, 1 otherwise.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

from kanban import ID_PREFIX

REPO_ROOT = Path(__file__).resolve().parents[2]

# The Linear team, and the local board, whose prefix kanban.py owns. Named
# trackers rather than a generic LETTERS-digits shape: that shape is also
# every standard the comments are asked to cite (UTF-8, ECMA-48, RFC-1951).
LINEAR_TEAM = "HYP"
TRACKER_ID = re.compile(rf"\b(?:{LINEAR_TEAM}|{re.escape(ID_PREFIX)})-\d+\b")

# Git's own binary test: a NUL byte in the content.
BINARY_MARKER = b"\0"


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=root, capture_output=True,
                          check=True).stdout.decode(errors="replace")


def text_findings(label: str, text: str) -> list[str]:
    if not TRACKER_ID.search(text):
        return []
    return [f"{label}:{number}: {match.group()}"
            for number, line in enumerate(text.splitlines(), start=1)
            for match in TRACKER_ID.finditer(line)]


def tree_findings(root: Path) -> list[str]:
    findings: list[str] = []
    for name in filter(None, git(root, "ls-files", "-z").split("\0")):
        if TRACKER_ID.search(name):
            findings.append(f"{name}: the file name")
        try:
            data = (root / name).read_bytes()
        except (FileNotFoundError, IsADirectoryError):
            continue
        if BINARY_MARKER not in data:
            findings += text_findings(name, data.decode(errors="replace"))
    return findings


def commit_findings(revision_range: str, root: Path) -> list[str]:
    findings: list[str] = []
    for record in filter(None, git(root, "log", "-z", "--format=%h%n%B",
                                   revision_range).split("\0")):
        commit, _, message = record.partition("\n")
        findings += text_findings(f"commit {commit}", message)
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--commits", metavar="RANGE",
                        help="check commit messages in RANGE instead of the tree")
    args = parser.parse_args()

    if args.commits:
        findings = commit_findings(args.commits, REPO_ROOT)
    else:
        findings = tree_findings(REPO_ROOT)
    if findings:
        print("Tracker ids — write out what they stood for instead:")
        print("\n".join(f"  {finding}" for finding in findings))
        return 1
    print("no tracker ids")
    return 0


if __name__ == "__main__":
    sys.exit(main())
