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

TOKEN_VALUE=""
case "$TOOL" in
  gh)
    HOST_SOURCE="${GH_CREDENTIAL_SOURCE:-$HOME/.config/gh}"
    # On macOS, gh stores its actual OAuth token in the Keychain, not in
    # hosts.yml/config.yml (those hold only non-secret metadata like
    # git_protocol/user) — confirmed via `gh auth status` reporting
    # "(keyring)". Resolve the real token via gh's own resolver (works
    # regardless of storage backend) rather than reverse-engineering
    # Keychain's internal format. Delivered to the real binary as
    # GH_TOKEN (see guards/gh.py) — gh's own documented, non-interactive
    # auth mechanism — not by trying to reconstruct hosts.yml's schema.
    TOKEN_VALUE=$(gh auth token)
    ;;
  aws) HOST_SOURCE="${AWS_CREDENTIAL_SOURCE:-$HOME/.aws}" ;;
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

TOKEN_STEP=""
if [ -n "$TOKEN_VALUE" ]; then
  TOKEN_STEP="cat > /volume/.rotate-tmp/.gh-token"
fi

# Token piped via stdin (docker run -i), not -e/argv: env vars and command
# args are both visible via `docker inspect`/`ps` for the lifetime of this
# short-lived rotation container; stdin content isn't captured by either.
docker run --rm -i \
  -v "$HOST_SOURCE:/host-source:ro" \
  -v "$VOLUME:/volume" \
  debian:trixie-slim bash -c "
    set -euo pipefail
    mkdir -p /volume/.rotate-tmp
    cp -R /host-source/. /volume/.rotate-tmp/
    $TOKEN_STEP
    chown -R $UID_:$UID_ /volume/.rotate-tmp
    find /volume/.rotate-tmp -type f -exec chmod 600 {} +
    find /volume/.rotate-tmp -type d -exec chmod 700 {} +
    find /volume/.rotate-tmp -mindepth 1 -maxdepth 1 -exec mv -f {} /volume/ \;
    rmdir /volume/.rotate-tmp
    chown $UID_:$UID_ /volume
    chmod 700 /volume
  " <<< "$TOKEN_VALUE"

echo "rotated $TOOL credential into volume $VOLUME"
