#!/usr/bin/env python3
"""The public API breaks nothing its last release offered, unless listed.

Released is a promise: an app written against a release keeps compiling on
every later release of the same major version. Nothing checked it, and
between 1.0.0 and 2.0.0 six things a 1.0 app could have written stopped
compiling — a theme's `muted` was silently ignored besides — found only when
the release was being cut.

Swift's API digester (``swift package diagnose-api-breaking-changes``)
compares every library module against a baseline release and names each
removed, renamed or retyped declaration and each new enum case or protocol
requirement. It is strict: a parameter added with a default is "removed" to
it, though every call still compiles. So a break the release accepts — by
judgement that it compiles, or because the next version is a major one — is
listed in ``tools/api-breakage-allowlist.txt``, under the baseline it was
accepted against. This check fails on a break the list does not accept and
on an entry that no longer occurs, so the list is always the true account.

After a major release is tagged, the list starts over: its baseline becomes
the new tag and its entries go.

Run::

    python3 tools/scripts/check_api_compat.py [--scratch-path .build-api]

It builds in a directory of its own, without warnings as errors: the
baseline is an old release built by today's compiler, whose new warnings are
not this release's to gate, and a build setting that differs from the one
beside it would rebuild that directory from scratch every time.

Exit 0 when the API and the list agree, 1 otherwise.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
LIST = Path("tools") / "api-breakage-allowlist.txt"

# The digester's report: a heading per module, then one line per break.
MODULE_WITH_BREAKS = re.compile(r"^\d+ breaking changes? detected in (\S+):$")
MODULE_WITHOUT_BREAKS = re.compile(r"^No breaking changes detected in (\S+)$")
BREAK = re.compile(r"^\s*💔\s*(API breakage: .*)$")
BASELINE = re.compile(r"^baseline\s+(\S+)$")
# What the digester reports that no caller can notice: hiding a declaration
# from the documentation changes no line that compiles against it.
NOT_A_BREAK = re.compile(r" is now with @_documentation$")


@dataclass
class Allowlist:
    baseline: Optional[str] = None
    entries: set[str] = field(default_factory=set)
    unreadable: list[str] = field(default_factory=list)


def reported_breaks(output: str) -> set[str]:
    """Every break in the digester's output, as ``Module: message``."""
    breaks: set[str] = set()
    module: Optional[str] = None
    for line in output.splitlines():
        heading = MODULE_WITH_BREAKS.match(line.strip())
        if heading:
            module = heading.group(1)
            continue
        if MODULE_WITHOUT_BREAKS.match(line.strip()):
            module = None
            continue
        found = BREAK.match(line)
        if found and module and not NOT_A_BREAK.search(found.group(1)):
            breaks.add(f"{module}: {found.group(1)}")
    return breaks


def compared_anything(output: str) -> bool:
    return any(MODULE_WITH_BREAKS.match(line.strip()) or MODULE_WITHOUT_BREAKS.match(line.strip())
               for line in output.splitlines())


def read_allowlist(text: str) -> Allowlist:
    accepted = Allowlist()
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        baseline = BASELINE.match(line.strip())
        if baseline:
            accepted.baseline = baseline.group(1)
        elif ": API breakage: " in line:
            accepted.entries.add(line.strip())
        else:
            accepted.unreadable.append(
                f"{LIST.as_posix()}:{number}: expected `Module: API breakage: …`, got {line!r}")
    return accepted


def findings(output: str, accepted: Allowlist) -> list[str]:
    """Everything that keeps the list from being the true account of how
    the API differs from its baseline."""
    if accepted.baseline is None:
        return [f"{LIST.as_posix()} names no `baseline <tag>` to compare against"]
    if not compared_anything(output):
        tail = "\n".join(output.strip().splitlines()[-15:])
        return [f"the digester compared nothing against {accepted.baseline}:\n{tail}"]
    reported = reported_breaks(output)
    return (accepted.unreadable
            + [f"unaccepted: {entry}: keep the API source-compatible, or list it in "
               f"{LIST.as_posix()} if this is a major release or it still compiles"
               for entry in sorted(reported - accepted.entries)]
            + [f"gone: {entry}: remove it from {LIST.as_posix()}"
               for entry in sorted(accepted.entries - reported)])


def digest(baseline: str, scratch_path: str) -> str:
    """The digester's report against ``baseline``. Its baseline API is
    kept per tag under the scratch path, so only the first run builds the
    old release."""
    baseline_dir = Path(scratch_path) / "api-baseline" / baseline
    result = subprocess.run(
        ["swift", "package", "--scratch-path", scratch_path,
         "diagnose-api-breaking-changes", baseline, "--baseline-dir", str(baseline_dir)],
        cwd=REPO_ROOT, capture_output=True, text=True,
        env={name: value for name, value in os.environ.items() if name != "TUI_WARNINGS_AS_ERRORS"})
    return result.stdout + result.stderr


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--scratch-path", default=".build-api")
    args = parser.parse_args()
    accepted = read_allowlist((REPO_ROOT / LIST).read_text())
    output = digest(accepted.baseline, args.scratch_path) if accepted.baseline else ""
    problems = findings(output, accepted)
    if problems:
        print("\n".join(problems))
        return 1
    print(f"the public API breaks nothing {accepted.baseline} offered that the list does not accept")
    return 0


if __name__ == "__main__":
    sys.exit(main())
