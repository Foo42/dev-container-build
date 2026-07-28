#!/usr/bin/env bash
# Wraps one CLI tool behind a policy-checking guard, run once per tool from
# the Dockerfile. See docs/superpowers/specs/2026-07-21-tool-sandboxing-design.md.
set -euo pipefail

TOOL="$1"
REAL_EXECUTABLE="$2"
CREDENTIAL_PATH="$3"

GUARD_SRC_DIR="${GUARD_SRC_DIR:-/opt/guard-src}"
GUARDS_DIR="${GUARDS_DIR:-/opt/guards}"
INTERCEPTORS_DIR="${INTERCEPTORS_DIR:-/opt/interceptors}"
LOG_DIR="${LOG_DIR:-/var/log/guards}"
MANIFEST="${MANIFEST:-/etc/wrapped-tools.json}"
UID_BASE="${UID_BASE:-2000}"
OWNER="${OWNER:-dev}"

mkdir -p "$GUARDS_DIR" "$INTERCEPTORS_DIR" "$LOG_DIR"

if [ ! -f "$MANIFEST" ]; then
  echo '{}' > "$MANIFEST"
fi

NEXT_UID=$(python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
uids = [v['uid'] for v in data.values()]
print(max(uids) + 1 if uids else $UID_BASE)
")

useradd --system --uid "$NEXT_UID" --no-create-home --shell /usr/sbin/nologin "$TOOL"
mkdir -p "$CREDENTIAL_PATH"
chown -R "$TOOL:$TOOL" "$CREDENTIAL_PATH"
chmod 0700 "$CREDENTIAL_PATH"

cat > "$GUARDS_DIR/${TOOL}_config.py" <<EOF
TOOL_NAME = "$TOOL"
REAL_EXECUTABLE = "$REAL_EXECUTABLE"
LOG_PATH = "$LOG_DIR/$TOOL.log"
EOF

if [ -f "$GUARD_SRC_DIR/${TOOL}.py" ]; then
  cp "$GUARD_SRC_DIR/${TOOL}.py" "$GUARDS_DIR/${TOOL}.py"
else
  cat > "$GUARDS_DIR/${TOOL}.py" <<EOF
#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from _common import run


def decide(argv: list[str]) -> bool:
    match argv:
        case _:
            return False  # deny by default — add allow cases above as needed


if __name__ == "__main__":
    from ${TOOL}_config import TOOL_NAME, REAL_EXECUTABLE, LOG_PATH
    run(decide, REAL_EXECUTABLE, LOG_PATH, TOOL_NAME)
EOF
fi

if [ ! -f "$GUARDS_DIR/_common.py" ]; then
  cp "$GUARD_SRC_DIR/_common.py" "$GUARDS_DIR/_common.py"
fi

chown "$OWNER:$OWNER" "$GUARDS_DIR/${TOOL}.py" "$GUARDS_DIR/${TOOL}_config.py" "$GUARDS_DIR/_common.py"
chmod 0755 "$GUARDS_DIR/${TOOL}.py" "$GUARDS_DIR/${TOOL}_config.py" "$GUARDS_DIR/_common.py"

touch "$LOG_DIR/$TOOL.log"
chown "$TOOL:$TOOL" "$LOG_DIR/$TOOL.log"
chmod 0600 "$LOG_DIR/$TOOL.log"

cat > "$INTERCEPTORS_DIR/$TOOL" <<EOF
#!/bin/sh
exec sudo -u $TOOL $GUARDS_DIR/${TOOL}.py "\$@"
EOF
chown "$OWNER:$OWNER" "$INTERCEPTORS_DIR/$TOOL"
chmod 0755 "$INTERCEPTORS_DIR/$TOOL"

cat > "/etc/sudoers.d/${TOOL}-guard" <<EOF
claude ALL=($TOOL) NOPASSWD: $GUARDS_DIR/${TOOL}.py
EOF
chmod 0440 "/etc/sudoers.d/${TOOL}-guard"
visudo -cf "/etc/sudoers.d/${TOOL}-guard"

python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
data['$TOOL'] = {'uid': $NEXT_UID, 'credential_path': '$CREDENTIAL_PATH'}
with open('$MANIFEST', 'w') as f:
    json.dump(data, f, indent=2)
"

echo "wrapped $TOOL (uid $NEXT_UID)"
