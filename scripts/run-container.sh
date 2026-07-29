#!/usr/bin/env bash
# scripts/run-container.sh
set -euo pipefail

# Captured before the `cd` below, so a bare `run-container.sh` (e.g. via a
# host alias/function) defaults to whatever directory the caller was in
# when they ran it — not this repo's own directory.
INVOCATION_DIR="$PWD"

# --session <name>: opts into rebuild-safe resumability for Claude Code's
# own conversation history. Maps to a named Docker volume
# (claude-session-<name>) mounted at /home/claude/.claude/projects only —
# not the rest of ~/.claude (settings, plugins, auth/daemon state,
# telemetry stay container-local and ephemeral). Reuse the same --session
# name (with the same workspace path, since Claude Code keys history by a
# slug of cwd) to resume a prior conversation in a new or rebuilt
# container; use a different name per project to keep histories separate.
SESSION_NAME=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session)
      SESSION_NAME="${2:?--session requires a value}"
      shift 2
      ;;
    --session=*)
      SESSION_NAME="${1#--session=}"
      shift
      ;;
    *)
      echo "unrecognized argument: $1" >&2
      exit 1
      ;;
  esac
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${IMAGE_NAME:-devcontainer-base}:${IMAGE_TAG:-latest}"
WORKSPACE_HOST_PATH="${WORKSPACE_HOST_PATH:-$INVOCATION_DIR}"
WORKSPACE_CONTAINER_PATH="${WORKSPACE_CONTAINER_PATH:-/home/dev/workspace}"
CONTAINER_NAME="${CONTAINER_NAME:-devcontainer}"
CLAUDE_SESSION_PATH="/home/claude/.claude/projects"

MANIFEST=$(docker run --rm --entrypoint cat "$IMAGE" /etc/wrapped-tools.json)

MOUNT_ARGS=(-v "$WORKSPACE_HOST_PATH:$WORKSPACE_CONTAINER_PATH")

if [ -n "$SESSION_NAME" ]; then
  CLAUDE_SESSION_VOLUME="claude-session-${SESSION_NAME}"
  docker volume create "$CLAUDE_SESSION_VOLUME" >/dev/null
  MOUNT_ARGS+=(-v "${CLAUDE_SESSION_VOLUME}:${CLAUDE_SESSION_PATH}")
fi

while IFS=$'\t' read -r tool credential_path; do
  if ! ./scripts/rotate-credential.sh "$tool"; then
    echo "warning: failed to rotate credential for '$tool' — skipping its mount" >&2
    continue
  fi
  MOUNT_ARGS+=(-v "${tool}-creds:${credential_path}:ro")
done < <(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for tool, info in data.items():
    print(f\"{tool}\t{info['credential_path']}\")
" "$MANIFEST")

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER_NAME" "${MOUNT_ARGS[@]}" "$IMAGE" sleep infinity

docker exec "$CONTAINER_NAME" sudo mkdir -p "$WORKSPACE_CONTAINER_PATH"

# Ensure claude's session-history directory exists and is owned by claude,
# whether or not --session was passed — harmless either way, and means a
# freshly attached (unmounted) container still gets a clean, writable
# ~/.claude/projects rather than Claude Code having to create it from
# scratch under a stricter default. Unlike the workspace bind mount above,
# this is either the container's own filesystem or a plain named volume
# (not a host bind mount), so chown here is reliable — it doesn't hit the
# Docker Desktop for Mac limitation noted below.
docker exec "$CONTAINER_NAME" sudo mkdir -p "$CLAUDE_SESSION_PATH"
docker exec "$CONTAINER_NAME" sudo chown claude:claude /home/claude/.claude "$CLAUDE_SESSION_PATH"

# No chgrp/chmod-based workspace group setup here: on Docker Desktop for
# Mac's bind-mount bridge, ownership/group metadata changes fail with
# "Permission denied" against pre-existing files even as root inside the
# container (confirmed directly against git's own read-only object files in
# a real repo) — and that same bridge is separately permissive about
# cross-user read/write regardless of ownership, so dev/claude workspace
# sharing already works without this step on this platform. Not relied on;
# not attempted. On a native Linux host, where bind-mount ownership
# semantics are normal, this wasn't a problem to begin with.
# dev's home directory defaults to 0700 (useradd --create-home), which blocks
# traversal into any subdirectory — including the workspace mount above — for
# every other user, claude included, regardless of the subdirectory's own
# permissions. Grant search-only (not read/list) access on the workspace's
# parent so claude can reach the shared workspace without gaining visibility
# into the rest of dev's home directory.
docker exec "$CONTAINER_NAME" sudo chmod o+x "$(dirname "$WORKSPACE_CONTAINER_PATH")"

echo "container '$CONTAINER_NAME' is up. Attach with:"
echo "  docker exec -it $CONTAINER_NAME sudo -u dev -i"
docker exec -it "$CONTAINER_NAME" sudo -u dev -i
