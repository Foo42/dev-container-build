#!/usr/bin/env bash
# scripts/rotate-credential.sh <tool>
# Pushes <tool>'s current host-side credential into its named Docker
# volume, creating the volume if needed. Safe to call standalone at any
# time (e.g. after rotating a token on the host) or as part of container
# startup — every running container with the volume mounted picks up the
# change on its next read, no restart needed.
set -euo pipefail

TOOL="$1"
IMAGE="${IMAGE_NAME:-devcontainer-base}:${IMAGE_TAG:-latest}"

case "$TOOL" in
  gh) HOST_SOURCE="${GH_CREDENTIAL_SOURCE:-$HOME/.config/gh}" ;;
  *)
    echo "no host credential source configured for tool '$TOOL'" >&2
    exit 1
    ;;
esac

MANIFEST=$(docker run --rm --entrypoint cat "$IMAGE" /etc/wrapped-tools.json)
UID_=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
info = data['$TOOL']
print(info['uid'])
" "$MANIFEST")

VOLUME="${TOOL}-creds"
docker volume create "$VOLUME" >/dev/null

docker run --rm \
  -v "$HOST_SOURCE:/host-source:ro" \
  -v "$VOLUME:/volume" \
  debian:trixie-slim bash -c "
    set -euo pipefail
    mkdir -p /volume/.rotate-tmp
    cp -R /host-source/. /volume/.rotate-tmp/
    chown -R $UID_:$UID_ /volume/.rotate-tmp
    find /volume/.rotate-tmp -type f -exec chmod 600 {} +
    find /volume/.rotate-tmp -type d -exec chmod 700 {} +
    for entry in /volume/.rotate-tmp/*; do
      name=\$(basename \"\$entry\")
      mv -f \"\$entry\" \"/volume/\$name\"
    done
    rmdir /volume/.rotate-tmp
    chown $UID_:$UID_ /volume
    chmod 700 /volume
  "

echo "rotated $TOOL credential into volume $VOLUME"
