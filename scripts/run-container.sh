#!/usr/bin/env bash
# scripts/run-container.sh
set -euo pipefail

# Captured before the `cd` below, so a bare `run-container.sh` (e.g. via a
# host alias/function) defaults to whatever directory the caller was in
# when they ran it — not this repo's own directory.
INVOCATION_DIR="$PWD"

# --session <name>: opts into rebuild-safe resumability for Claude Code's
# own conversation history specifically. Maps to a named Docker volume
# (claude-session-<name>) mounted at /home/claude/.claude/projects, nested
# inside (and shadowing just that subdirectory of) the always-on
# claude-config volume set up below — credentials/settings persist
# regardless of this flag; this is only about whether *conversation
# history* also persists, and under which name. Reuse the same --session
# name (with the same workspace path, since Claude Code keys history by a
# slug of cwd) to resume a prior conversation in a new or rebuilt
# container; use a different name per project to keep histories separate;
# omit it to start every container with fresh conversation history.
# --ref <path>[:<name>] (repeatable): mounts an additional host directory
# read-only at /reference/<name> inside the container, for material you
# want dev/claude to be able to read but never accidentally edit. <name>
# defaults to the path's basename; give distinct paths distinct names if
# their basenames collide. Relative paths are resolved against the
# directory the script was invoked from (like WORKSPACE_HOST_PATH's
# current-directory default), not this repo's own directory.
SESSION_NAME=""
REF_ARGS=()
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
    --ref)
      REF_ARGS+=("${2:?--ref requires a value}")
      shift 2
      ;;
    --ref=*)
      REF_ARGS+=("${1#--ref=}")
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

# Always-on, not opt-in: persists the whole /home/claude/.claude — Claude
# Code's own login credentials, settings, plugins, etc. — in a single
# global volume (one Anthropic login, shared across all projects/sessions;
# override CLAUDE_CONFIG_VOLUME if you deliberately want a second, separate
# identity). There's no legitimate "start fresh" use case for re-logging-in
# on purpose, unlike conversation history below, which stays opt-in.
CLAUDE_CONFIG_VOLUME="${CLAUDE_CONFIG_VOLUME:-claude-config}"
docker volume create "$CLAUDE_CONFIG_VOLUME" >/dev/null
MOUNT_ARGS+=(-v "${CLAUDE_CONFIG_VOLUME}:/home/claude/.claude")

if [ -n "$SESSION_NAME" ]; then
  CLAUDE_SESSION_VOLUME="claude-session-${SESSION_NAME}"
  docker volume create "$CLAUDE_SESSION_VOLUME" >/dev/null
  MOUNT_ARGS+=(-v "${CLAUDE_SESSION_VOLUME}:${CLAUDE_SESSION_PATH}")
fi

REF_NAMES=()
for ref_arg in "${REF_ARGS[@]+"${REF_ARGS[@]}"}"; do
  if [[ "$ref_arg" == *:* ]]; then
    REF_HOST_PATH="${ref_arg%:*}"
    REF_NAME="${ref_arg##*:}"
  else
    REF_HOST_PATH="$ref_arg"
    REF_NAME="$(basename "$ref_arg")"
  fi

  case "$REF_HOST_PATH" in
    /*) : ;;
    *) REF_HOST_PATH="$INVOCATION_DIR/$REF_HOST_PATH" ;;
  esac

  if [ ! -e "$REF_HOST_PATH" ]; then
    echo "error: --ref path does not exist: $REF_HOST_PATH" >&2
    exit 1
  fi
  case "$REF_NAME" in
    ""|*/*|.|..)
      echo "error: --ref name '$REF_NAME' is invalid (empty, contains '/', or is '.'/'..')" >&2
      exit 1
      ;;
  esac
  for existing in "${REF_NAMES[@]+"${REF_NAMES[@]}"}"; do
    if [ "$existing" = "$REF_NAME" ]; then
      echo "error: duplicate --ref name '$REF_NAME' — use --ref <path>:<name> to disambiguate" >&2
      exit 1
    fi
  done
  REF_NAMES+=("$REF_NAME")

  MOUNT_ARGS+=(-v "${REF_HOST_PATH}:/reference/${REF_NAME}:ro")
done

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

# Ensure claude's ~/.claude (always volume-backed now) and its nested
# session-history directory (volume-backed only if --session was passed)
# both exist and are owned by claude — harmless either way, and means a
# freshly attached container always gets a clean, writable ~/.claude rather
# than Claude Code having to create it from scratch under a stricter
# default. Unlike the workspace bind mount below, these are named volumes
# (or the container's own filesystem), so chown here is reliable — it
# doesn't hit the Docker Desktop for Mac limitation noted further down.
docker exec "$CONTAINER_NAME" sudo mkdir -p "$CLAUDE_SESSION_PATH"
docker exec "$CONTAINER_NAME" sudo chown claude:claude /home/claude/.claude "$CLAUDE_SESSION_PATH"

# /reference/<name> mounts (from --ref) live outside both dev's and
# claude's home directories specifically to sidestep the 0700-home
# traversal issue handled below for the workspace — a single root-owned,
# world-traversable/readable directory at the container's top level, not a
# bind mount itself, so this chmod is reliable regardless of the Docker
# Desktop bind-mount limitations noted below. Each --ref subdirectory
# keeps its own :ro mount flag, so nothing under /reference is writable by
# dev or claude regardless of this directory's own permissions.
docker exec "$CONTAINER_NAME" sudo mkdir -p /reference
docker exec "$CONTAINER_NAME" sudo chmod o+rx /reference

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
