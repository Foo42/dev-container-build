#!/usr/bin/env bash
# Builds the devcontainer base image. Both the nvim and tmux configs are
# cloned directly from GitHub by the Dockerfile, so there's nothing to sync
# locally first.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE_NAME="${IMAGE_NAME:-devcontainer-base}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "==> Building ${IMAGE_NAME}:${IMAGE_TAG}"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" .

echo "==> Done: ${IMAGE_NAME}:${IMAGE_TAG}"
