#!/usr/bin/env python3
"""Concurrent live-instances integration contract.

Spawn two
Storybook processes from the same checkout in separate harnessed
PTYs and prove the architectural guarantees end-to-end:

1. **Distinct PID-isolated dirs.** Each instance writes to
   ``/tmp/terminalui-{cwd-hash}-{pid}/`` so identity is structural —
   the path itself encodes which process owns it. Two instances from
   the same checkout never collide.
2. **PID-targeted socket lookup.** ``default_socket_path(pid=N)``
   resolves to that PID's socket file specifically.
3. **PID-targeted ctl queries.** ``swtui ctl --pid <N> focus`` reaches
   the named instance's socket and returns its focus state. Two
   independent instances answer independently.
4. **kill --pid is surgical.** Killing instance A writes `quit` to A's
   socket but does NOT touch instance B's socket file or its
   responsiveness to subsequent ctl queries.
5. **A ctl call that names no app.** With two apps running, `swtui ctl`
   without `--pid` refuses and lists both; with one, it reaches it.
6. **SIGTERM quits through teardown.** An app ended by SIGTERM removes its
   own data dir and socket, then dies of the signal.

The kill contract is "kill --pid writes quit to that PID's socket and
ONLY that socket"; this test asserts that side, not that A then exits.

Run::

    swift build && python3 tools/scripts/test_concurrent_instances.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
import sys
import time
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.cases import run_cases  # noqa: E402
from terminalui.runner import build_dir_path, spawn_and_connect  # noqa: E402
from terminalui.client import default_socket_path  # noqa: E402


REPO_ROOT = Path(__file__).resolve().parents[2]
SWTUI_BIN = build_dir_path() / "swtui"


def _swtui_ctl(*args: str, cwd: Optional[str] = None) -> subprocess.CompletedProcess:
    """Run `swtui ctl <args>` from the repo root, or from `cwd`."""
    return subprocess.run(
        [str(SWTUI_BIN), "ctl", *args],
        cwd=cwd or str(REPO_ROOT),
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )


# ---------------------------------------------------------------------------
# Case 1: two instances → two distinct dirs, both alive simultaneously
# ---------------------------------------------------------------------------


def case_two_instances_distinct_dirs() -> None:
    """Spawn A and B as nested context managers. Assert their diag
    dirs differ and both exist while both processes run."""
    with spawn_and_connect("Storybook") as (proc_a, client_a):
        with spawn_and_connect("Storybook") as (proc_b, client_b):
            dir_a = getattr(client_a, "diag_dir", None)
            dir_b = getattr(client_b, "diag_dir", None)
            assert dir_a and dir_b, f"diag_dir missing: a={dir_a!r}, b={dir_b!r}"
            assert dir_a != dir_b, (
                f"two instances resolved to the SAME diag dir {dir_a!r} — "
                "concurrent processes from this checkout are colliding"
            )
            assert Path(dir_a).is_dir(), f"A's dir {dir_a!r} does not exist"
            assert Path(dir_b).is_dir(), f"B's dir {dir_b!r} does not exist"


# ---------------------------------------------------------------------------
# Case 2: default_socket_path(pid=N) is PID-specific
# ---------------------------------------------------------------------------


def case_default_socket_lookup_pid_specific() -> None:
    """default_socket_path(pid=A.pid) must resolve to A's socket file
    (under A's diag dir), and pid=B.pid to B's. Compared via
    os.path.realpath, since /tmp is a link on macOS."""
    import os
    with spawn_and_connect("Storybook") as (proc_a, client_a):
        with spawn_and_connect("Storybook") as (proc_b, client_b):
            dir_a = client_a.diag_dir
            dir_b = client_b.diag_dir

            path_a = os.path.realpath(default_socket_path(pid=proc_a.pid))
            path_b = os.path.realpath(default_socket_path(pid=proc_b.pid))

            real_dir_a = os.path.realpath(dir_a)
            real_dir_b = os.path.realpath(dir_b)

            assert real_dir_a in path_a, (
                f"default_socket_path(pid={proc_a.pid}) resolved (realpath) to {path_a!r}; "
                f"expected a path under A's diag dir {real_dir_a!r}"
            )
            assert real_dir_b in path_b, (
                f"default_socket_path(pid={proc_b.pid}) resolved (realpath) to {path_b!r}; "
                f"expected a path under B's diag dir {real_dir_b!r}"
            )
            assert path_a != path_b, (
                f"PID-specific lookups must produce distinct paths; "
                f"both resolved to {path_a!r}"
            )
            assert real_dir_b not in path_a, (
                f"A's socket lookup leaked into B's dir: {path_a!r} contains {real_dir_b!r}"
            )
            assert real_dir_a not in path_b, (
                f"B's socket lookup leaked into A's dir: {path_b!r} contains {real_dir_a!r}"
            )


# ---------------------------------------------------------------------------
# Case 3: swtui ctl --pid <N> reaches the named instance independently
# ---------------------------------------------------------------------------


def case_swtui_ctl_pid_targeted() -> None:
    """`swtui ctl --pid <N> focus` must reach the named instance's
    socket and round-trip a JSON response. Both instances answer
    independently — neither query routes to the other."""
    with spawn_and_connect("Storybook") as (proc_a, client_a):
        with spawn_and_connect("Storybook") as (proc_b, client_b):
            dir_a = Path(client_a.diag_dir) / "remote"
            dir_b = Path(client_b.diag_dir) / "remote"

            res_a = _swtui_ctl("--dir", str(dir_a), "--pid", str(proc_a.pid), "focus")
            res_b = _swtui_ctl("--dir", str(dir_b), "--pid", str(proc_b.pid), "focus")

            assert res_a.returncode == 0, (
                f"`ctl --pid {proc_a.pid} focus` failed; "
                f"rc={res_a.returncode}, stdout={res_a.stdout!r}, stderr={res_a.stderr!r}"
            )
            assert res_b.returncode == 0, (
                f"`ctl --pid {proc_b.pid} focus` failed; "
                f"rc={res_b.returncode}, stdout={res_b.stdout!r}, stderr={res_b.stderr!r}"
            )

            # Both return well-formed JSON. We don't compare focus
            # contents — the two instances open on the same Storybook
            # page and would have identical state. The contract is
            # both responded independently.
            try:
                json.loads(res_a.stdout.strip().splitlines()[-1])
            except (json.JSONDecodeError, IndexError) as exc:
                raise AssertionError(
                    f"A's focus response is not JSON: {res_a.stdout!r} ({exc})"
                ) from exc
            try:
                json.loads(res_b.stdout.strip().splitlines()[-1])
            except (json.JSONDecodeError, IndexError) as exc:
                raise AssertionError(
                    f"B's focus response is not JSON: {res_b.stdout!r} ({exc})"
                ) from exc


# ---------------------------------------------------------------------------
# Case 4: kill --pid A is surgical — B keeps serving queries
# ---------------------------------------------------------------------------


def case_kill_pid_a_leaves_b_alive() -> None:
    """`swtui ctl kill --pid <A>` writes `quit` to A's socket. B's
    socket file is untouched, and B continues to answer subsequent
    ctl queries. Pins the architectural guarantee: PID-targeted
    mutations don't fan out.

    Asserts only that the kill is surgical (stdout reports
    `status=quit-sent`, B's socket and responsiveness are untouched)."""
    with spawn_and_connect("Storybook") as (proc_a, client_a):
        with spawn_and_connect("Storybook") as (proc_b, client_b):
            dir_a = Path(client_a.diag_dir) / "remote"
            dir_b = Path(client_b.diag_dir) / "remote"
            sock_b = dir_b / f"{proc_b.pid}.sock"

            # Snapshot B's socket inode so we can detect any tampering.
            inode_b_before = sock_b.stat().st_ino

            kill_res = _swtui_ctl(
                "--dir", str(dir_a),
                "kill", "--pid", str(proc_a.pid),
            )
            assert kill_res.returncode == 0, (
                f"kill --pid A.pid={proc_a.pid} must succeed; "
                f"rc={kill_res.returncode}, stdout={kill_res.stdout!r}, stderr={kill_res.stderr!r}"
            )
            assert "status=quit-sent" in kill_res.stdout, (
                f"kill must report quit-sent for A; got {kill_res.stdout!r}"
            )

            # B's socket file must be untouched (same inode) AND B must
            # still answer ctl queries.
            assert sock_b.exists(), (
                f"B's socket {sock_b} disappeared after killing A — "
                "kill --pid is fanning out to other instances"
            )
            assert sock_b.stat().st_ino == inode_b_before, (
                f"B's socket inode changed after killing A — file replaced"
            )

            focus_b = _swtui_ctl("--dir", str(dir_b), "--pid", str(proc_b.pid), "focus")
            assert focus_b.returncode == 0, (
                f"B no longer answers ctl queries after A was killed; "
                f"rc={focus_b.returncode}, stderr={focus_b.stderr!r}. "
                "kill --pid is reaching B somehow."
            )


# ---------------------------------------------------------------------------
# Case 5: a ctl call that names no app — each app is addressed by its own id
# ---------------------------------------------------------------------------


def case_bare_ctl_with_two_apps_names_both() -> None:
    """With two apps running from this checkout, `swtui ctl` without
    `--pid` refuses and lists both. It used to pick the most recently
    started one, so an app the harness launched took over the
    developer's session — and left nothing to reach once it exited."""
    with spawn_and_connect("Storybook") as (proc_a, _):
        with spawn_and_connect("Storybook") as (proc_b, _):
            res = _swtui_ctl("ping")
            assert res.returncode == 2, (
                f"a bare ctl call with two apps running must refuse; rc={res.returncode}, "
                f"stdout={res.stdout!r}, stderr={res.stderr!r}")
            for pid in (proc_a.pid, proc_b.pid):
                assert f"--pid {pid}" in res.stderr, f"pid {pid} is not offered: {res.stderr!r}"
            assert "Storybook" in res.stderr, f"the apps are not named: {res.stderr!r}"


def case_bare_ctl_with_one_app_reaches_it() -> None:
    """With one app running from a checkout, `swtui ctl` without `--pid`
    reaches it. A fresh directory stands for the checkout, so apps a
    developer has running from this one do not count."""
    with tempfile.TemporaryDirectory(prefix="terminalui-checkout-") as checkout:
        with spawn_and_connect("Storybook", cwd=checkout):
            res = _swtui_ctl("ping", cwd=checkout)
            assert res.returncode == 0, (
                f"a bare ctl call with one app running must reach it; rc={res.returncode}, "
                f"stdout={res.stdout!r}, stderr={res.stderr!r}")


def case_sigterm_quits_through_the_apps_own_teardown() -> None:
    """SIGTERM — how the harness ends every app, and what a closed terminal
    tab's SIGHUP amounts to — asks the app to quit. It leaves through its
    normal teardown, so its per-process dir and socket are gone, and then
    dies of the signal, so the parent still sees -15. Killed inside the
    handler, it left both behind every time."""
    import os
    import signal

    with spawn_and_connect("Storybook") as (proc, client):
        diag_dir = Path(client.diag_dir)
        assert diag_dir.is_dir(), f"the running app has no data dir at {diag_dir}"
        client.expected_exit_signal = signal.SIGTERM
        os.kill(proc.pid, signal.SIGTERM)
        status = client.wait_for_exit(10.0)
        assert status == -signal.SIGTERM, f"exit status {status}, not -SIGTERM"
        assert not diag_dir.exists(), f"the app left its data dir: {diag_dir}"


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


CASES = [
    ("concurrent.two_instances_distinct_dirs",         case_two_instances_distinct_dirs),
    ("concurrent.default_socket_lookup_pid_specific",  case_default_socket_lookup_pid_specific),
    ("concurrent.swtui_ctl_pid_targeted",              case_swtui_ctl_pid_targeted),
    ("concurrent.kill_pid_a_leaves_b_alive",           case_kill_pid_a_leaves_b_alive),
    ("concurrent.bare_ctl_with_two_apps_names_both",   case_bare_ctl_with_two_apps_names_both),
    ("concurrent.bare_ctl_with_one_app_reaches_it",    case_bare_ctl_with_one_app_reaches_it),
    ("concurrent.sigterm_quits_through_the_apps_own_teardown",
     case_sigterm_quits_through_the_apps_own_teardown),
]


def main() -> int:
    if not SWTUI_BIN.exists():
        print(f"[SKIP] {SWTUI_BIN} not found — run `swift build` first")
        return 0

    return run_cases(CASES)


if __name__ == "__main__":
    sys.exit(main())
