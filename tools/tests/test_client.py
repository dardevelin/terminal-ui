#!/usr/bin/env python3
"""The control client gives a sanitizer build the time its replies take.

A reply is served between frames, and a Thread Sanitizer build's frames on
CI's three-core runner took longer than the two seconds a reply was allowed:
a case failed with a socket timeout on an app that was only slow. The
runner raises a sanitized app's read timeout to the input timeout; the
client must apply a changed timeout to a socket it already holds.

Run::

    python3 tools/tests/test_client.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import os
import socket
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.cases import run_cases  # noqa: E402
from terminalui.client import (INPUT_TIMEOUT, Client, diag_dir_of, find_diag_dir, fnv1a,  # noqa: E402
                               reap_dead_data_dirs)


def a_changed_read_timeout_reaches_the_open_socket() -> None:
    directory = tempfile.mkdtemp(prefix="terminalui-client-test-")
    path = os.path.join(directory, "server.sock")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(path)
        server.listen(1)
        client = Client(path=path)
        client.connect()
        assert client._sock is not None and client._sock.gettimeout() == 2.0, client._sock
        client.read_timeout = INPUT_TIMEOUT
        assert client.read_timeout == INPUT_TIMEOUT
        assert client._sock.gettimeout() == INPUT_TIMEOUT, client._sock.gettimeout()
        client.close()
    finally:
        server.close()
        os.unlink(path)
        os.rmdir(directory)


def a_timeout_set_before_connecting_is_the_one_it_connects_with() -> None:
    client = Client(path="/nonexistent/server.sock")
    client.read_timeout = INPUT_TIMEOUT
    assert client.read_timeout == INPUT_TIMEOUT


def fnv1a_is_the_hash_the_framework_names_a_checkout_by() -> None:
    # The published 32-bit FNV-1a vectors (Fowler, Noll, Vo; Noll's test
    # suite): DiagPaths hashes the app's working directory the same way.
    for text, expected in [("", "811c9dc5"), ("a", "e40c292c"), ("foobar", "bf9cf968")]:
        assert fnv1a(text) == expected, (text, fnv1a(text))


def an_app_is_found_by_its_own_directory_not_another_checkouts() -> None:
    # A dead app from another checkout that had the same pid left its
    # directory, socket and all: a glob on the pid found it, and the client
    # waited on its socket for as long as it had.
    root = tempfile.mkdtemp(prefix="terminalui-client-test-")
    project = tempfile.mkdtemp(prefix="terminalui-client-project-")
    pid = 4242
    try:
        stale = Path(root) / f"terminalui-00000000-{pid}"
        (stale / "remote").mkdir(parents=True)
        (stale / "remote" / f"{pid}.sock").touch()
        own = Path(diag_dir_of(pid, project, tmp_root=root))
        assert own.name == f"terminalui-{fnv1a(os.path.realpath(project))}-{pid}", own
        assert find_diag_dir(pid, cwd=project, tmp_root=root) is None, "the app has not made its own yet"
        own.mkdir()
        assert find_diag_dir(pid, cwd=project, tmp_root=root) == str(own)
    finally:
        import shutil
        shutil.rmtree(root)
        os.rmdir(project)


def only_a_dead_apps_data_dir_is_reaped() -> None:
    # An app killed before its teardown, or a harness killed mid-case,
    # leaves its data dir in /tmp: hundreds piled up. A dir whose process
    # is gone is nobody's; one whose process runs is left, and so is
    # anything not named as a data dir.
    import shutil
    import subprocess
    root = tempfile.mkdtemp(prefix="terminalui-reap-test-")
    try:
        finished = subprocess.Popen(["true"])
        finished.wait()
        dead = Path(root) / f"terminalui-1a2b3c4d-{finished.pid}"
        live = Path(root) / f"terminalui-1a2b3c4d-{os.getpid()}"
        other = Path(root) / "terminalui_walk"
        for directory in (dead, live, other):
            (directory / "remote").mkdir(parents=True)
        assert reap_dead_data_dirs(tmp_root=root) == 1
        assert not dead.exists(), "the dead app's dir is removed"
        assert live.exists(), "a running process keeps its dir"
        assert other.exists(), "only data dirs are touched"
    finally:
        shutil.rmtree(root)


CASES = [
    ("a changed read timeout reaches the open socket", a_changed_read_timeout_reaches_the_open_socket),
    ("a timeout set before connecting is the one it connects with",
     a_timeout_set_before_connecting_is_the_one_it_connects_with),
    ("fnv1a is the hash the framework names a checkout by", fnv1a_is_the_hash_the_framework_names_a_checkout_by),
    ("an app is found by its own directory, not another checkout's",
     an_app_is_found_by_its_own_directory_not_another_checkouts),
    ("only a dead app's data dir is reaped", only_a_dead_apps_data_dir_is_reaped),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
