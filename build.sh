#!/usr/bin/env bash
# Syncs the local tmux config into the build context, then builds the image.
# The nvim config is cloned directly from GitHub by the Dockerfile, so it
# doesn't need a local copy here.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE_NAME="${IMAGE_NAME:-devcontainer-base}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "==> Syncing tmux config into build context"
cp "${HOME}/.tmux.conf" tmux.conf

echo "==> Building ${IMAGE_NAME}:${IMAGE_TAG}"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" .

echo "==> Done: ${IMAGE_NAME}:${IMAGE_TAG}"
