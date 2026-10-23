#!/usr/bin/env bash
# Run the PTY-driven visual harness against a Linux build, in Docker.
#
# The swift:6.2 image ships no Python interpreter, which is the only reason the
# harness could not run here — PTY allocation itself works fine under Docker.
# Installing python3 is therefore the whole story; there is no structural
# blocker and no need for a custom image.
#
# The container builds into .build-linux/, NOT .build/. Sharing one build
# directory across platforms puts Linux ELF binaries where the host expects
# Mach-O ones, and the next macOS harness run dies with "Exec format error" on
# every case. A separate scratch path also sidesteps the ModuleCache collision
# ("module 'SwiftShims' is defined in both <the same path twice>") that a
# shared .build/ produces.
#
# Usage:
#   tools/scripts/linux_harness.sh                    # walk (default)
#   tools/scripts/linux_harness.sh storybook_smoke.py # any script under tools/scripts/

set -euo pipefail

SCRIPT="${1:-storybook_walk.py}"
IMAGE="swift:6.2"  # Package.swift requires 6.2; swift:6.0 rejects the manifest.
SCRATCH=".build-linux"

exec docker run --rm -v "$(pwd)":/app -w /app "$IMAGE" bash -c "
    set -e
    # One command each: \`set -e\` lets a failure inside an && list pass, so a
    # mirror that did not answer left the run to die later on a python3 that
    # was never installed.
    apt-get update -qq >/dev/null || { echo 'apt-get update failed: no package mirror' >&2; exit 1; }
    apt-get install -y -qq python3 >/dev/null || { echo 'could not install python3' >&2; exit 1; }
    # Build everything: repeated --product flags do not accumulate (the last
    # one wins), which silently leaves the harness without its app binary.
    swift build --scratch-path $SCRATCH
    python3 tools/scripts/$SCRIPT $SCRATCH/debug
"
