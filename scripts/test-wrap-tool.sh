#!/usr/bin/env bash
# scripts/test-wrap-tool.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker run --rm \
  -v "$(pwd)/scripts/wrap-tool.sh:/wrap-tool.sh:ro" \
  -v "$(pwd)/guards:/opt/guard-src:ro" \
  debian:trixie-slim bash -c '
    set -euo pipefail
    apt-get update -qq >/dev/null
    apt-get install -y -qq sudo python3 >/dev/null
    useradd -m dev
    useradd -m claude
    bash /wrap-tool.sh gh /bin/ls /home/gh/.config/gh

    test -f /opt/guards/gh.py
    test -f /opt/guards/_common.py
    test -f /opt/guards/gh_config.py
    test -f /opt/interceptors/gh
    test -f /etc/sudoers.d/gh-guard
    test -f /var/log/guards/gh.log

    [ "$(stat -c %U:%G /opt/interceptors/gh)" = "dev:dev" ]
    [ "$(stat -c %a /opt/interceptors/gh)" = "755" ]
    [ "$(stat -c %U:%G /home/gh/.config/gh)" = "gh:gh" ]
    [ "$(stat -c %a /home/gh/.config/gh)" = "700" ]
    [ "$(stat -c %U:%G /var/log/guards/gh.log)" = "gh:gh" ]

    getent passwd gh >/dev/null
    grep -q "claude ALL=(gh) NOPASSWD" /etc/sudoers.d/gh-guard
    python3 -c "import json; d = json.load(open(\"/etc/wrapped-tools.json\")); assert d[\"gh\"][\"credential_path\"] == \"/home/gh/.config/gh\", d"

    echo ALL_CHECKS_PASSED
  '
