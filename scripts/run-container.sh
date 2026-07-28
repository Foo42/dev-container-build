#!/usr/bin/env bash
# scripts/run-container.sh
set -euo pipefail

# Captured before the `cd` below, so a bare `run-container.sh` (e.g. via a
# host alias/function) defaults to whatever directory the caller was in
# when they ran it — not this repo's own directory.
INVOCATION_DIR="$PWD"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${IMAGE_NAME:-devcontainer-base}:${IMAGE_TAG:-latest}"
WORKSPACE_HOST_PATH="${WORKSPACE_HOST_PATH:-$INVOCATION_DIR}"
WORKSPACE_CONTAINER_PATH="${WORKSPACE_CONTAINER_PATH:-/home/dev/workspace}"
CONTAINER_NAME="${CONTAINER_NAME:-devcontainer}"

MANIFEST=$(docker run --rm --entrypoint cat "$IMAGE" /etc/wrapped-tools.json)

MOUNT_ARGS=(-v "$WORKSPACE_HOST_PATH:$WORKSPACE_CONTAINER_PATH")

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
docker exec "$CONTAINER_NAME" sudo chgrp -R workspace "$WORKSPACE_CONTAINER_PATH"
docker exec "$CONTAINER_NAME" sudo chmod -R g+rwX "$WORKSPACE_CONTAINER_PATH"
docker exec "$CONTAINER_NAME" sudo chmod -R g+s "$WORKSPACE_CONTAINER_PATH"
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
