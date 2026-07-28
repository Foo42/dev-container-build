#!/usr/bin/env bash
# scripts/run-container.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${IMAGE_NAME:-devcontainer-base}:${IMAGE_TAG:-latest}"
WORKSPACE_HOST_PATH="${WORKSPACE_HOST_PATH:-$HOME/code}"
WORKSPACE_CONTAINER_PATH="${WORKSPACE_CONTAINER_PATH:-/home/dev/workspace}"
CONTAINER_NAME="${CONTAINER_NAME:-devcontainer}"

MANIFEST=$(docker run --rm --entrypoint cat "$IMAGE" /etc/wrapped-tools.json)

MOUNT_ARGS=(-v "$WORKSPACE_HOST_PATH:$WORKSPACE_CONTAINER_PATH")

while IFS=$'\t' read -r tool credential_path; do
  ./scripts/rotate-credential.sh "$tool"
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
docker exec "$CONTAINER_NAME" sudo chmod -R g+s "$WORKSPACE_CONTAINER_PATH"

echo "container '$CONTAINER_NAME' is up. Attach with:"
echo "  docker exec -it $CONTAINER_NAME sudo -u dev -i"
docker exec -it "$CONTAINER_NAME" sudo -u dev -i
