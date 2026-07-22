#!/usr/bin/env bash
# Confirms Docker Desktop's bind-mount bridge preserves an arbitrary numeric
# UID from host to container. Requires an interactive terminal (sudo needs to
# prompt for a password) — run it directly in a real terminal, not through
# an automated/background process.
#
# Run 2026-07-22 on this machine: the container side read back as
# `uid=0 gid=0`, not `2000`, and a non-matching UID could still read the
# file — the bind-mount bridge does not preserve or enforce chown'd
# ownership here. See docs/superpowers/specs/2026-07-21-tool-sandboxing-design.md
# ("Docker Desktop for Mac's bind-mount UID passthrough: tested and found
# broken") for what this means for the credential design (named Docker
# volumes instead — see scripts/verify-named-volume-uid.sh, which passed).
# Re-run this after any Docker Desktop upgrade in case the behavior changes.
set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "test-content" > "$TMPDIR/probe"
sudo chown 2000:2000 "$TMPDIR/probe"

echo "== host side =="
stat -f "uid=%u gid=%g mode=%Mp%Lp" "$TMPDIR/probe" 2>/dev/null || stat -c "uid=%u gid=%g mode=%a" "$TMPDIR/probe"

echo "== container side =="
docker run --rm -v "$TMPDIR/probe:/probe:ro" debian:trixie-slim \
  stat -c "uid=%u gid=%g mode=%a" /probe

echo "== container side, read as a non-matching user =="
docker run --rm -v "$TMPDIR/probe:/probe:ro" debian:trixie-slim \
  bash -c 'useradd -u 3000 -M other 2>/dev/null; su -s /bin/sh other -c "cat /probe"' \
  && echo "UNEXPECTED: other UID could read the file" \
  || echo "expected: permission denied for a different UID"
