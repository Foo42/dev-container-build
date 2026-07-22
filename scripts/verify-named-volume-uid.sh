#!/usr/bin/env bash
# Confirms named Docker volumes preserve and enforce chown'd ownership
# correctly across independent containers, unlike host bind mounts (see
# verify-uid-passthrough.sh). No sudo needed — the chown happens inside a
# container, not on the host.
#
# Run 2026-07-22 on this machine: a file chown'd 2000:2000 and chmod'd 600
# inside one container read back as `uid=2000 gid=2000 mode=600` from a
# second, independent container sharing the same volume, and a
# non-matching UID got a real permission-denied reading it. This is the
# mechanism the credential design (docs/superpowers/specs/2026-07-21-tool-sandboxing-design.md)
# relies on instead of bind-mount UID passthrough.
set -euo pipefail

VOLUME="sdd-probe-vol-$$"
cleanup() { docker volume rm "$VOLUME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker volume create "$VOLUME" >/dev/null

echo "== write + chown inside container A =="
docker run --rm -v "$VOLUME:/data" debian:trixie-slim bash -c '
  echo test-content > /data/probe
  chown 2000:2000 /data/probe
  chmod 600 /data/probe
  stat -c "uid=%u gid=%g mode=%a" /data/probe
'

echo "== read back from a fresh container B (same volume) =="
docker run --rm -v "$VOLUME:/data" debian:trixie-slim \
  stat -c "uid=%u gid=%g mode=%a" /data/probe

echo "== read as a non-matching uid in container C =="
docker run --rm -v "$VOLUME:/data" debian:trixie-slim bash -c '
  useradd -u 3000 -M other
  su -s /bin/sh other -c "cat /data/probe" && echo "UNEXPECTED: other UID could read the file" || echo "expected: permission denied for a different UID"
'
