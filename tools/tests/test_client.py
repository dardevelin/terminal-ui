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
from terminalui.client import INPUT_TIMEOUT, Client  # noqa: E402


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


CASES = [
    ("a changed read timeout reaches the open socket", a_changed_read_timeout_reaches_the_open_socket),
    ("a timeout set before connecting is the one it connects with",
     a_timeout_set_before_connecting_is_the_one_it_connects_with),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
