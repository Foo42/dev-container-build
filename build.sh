#!/usr/bin/env bash
# Syncs local nvim/tmux configs into the build context, then builds the image.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE_NAME="${IMAGE_NAME:-devcontainer-base}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "==> Syncing configs into build context"
mkdir -p config/kickstart
rsync -a --delete --exclude='.git' --exclude='.venv' --exclude='.aider.tags.cache.v4' \
  "${HOME}/.config/kickstart/" config/kickstart/
cp "${HOME}/.tmux.conf" tmux.conf

echo "==> Building ${IMAGE_NAME}:${IMAGE_TAG}"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" .

echo "==> Done: ${IMAGE_NAME}:${IMAGE_TAG}"
