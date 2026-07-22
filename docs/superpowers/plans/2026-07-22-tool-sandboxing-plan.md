# Tool Sandboxing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Claude Code as a restricted `claude` user in the devcontainer that can only reach sensitive CLIs (starting with `gh`) through a Python policy check we author, never directly and never with access to that tool's credentials.

**Architecture:** A three-tier identity model (`dev` interactive/full-sudo, `claude` restricted, one service user per wrapped tool holding that tool's credentials) connected by a thin shell interceptor on `claude`'s `$PATH` that `exec`s into a narrowly-scoped `sudo` call, landing on a Python guard script (running as the service user) that matches the requested argv against an allow-list and, if permitted, `execv`s the real binary. Credentials are provisioned at `docker run` time via named Docker volumes (one per tool, refreshed from the host on every launch), never baked into the image, never bind-mounted, and never passed as container-wide env vars — bind-mount-based provisioning was tried first and found broken on this machine (see Task 1).

**Tech Stack:** Debian (`trixie-slim`), Bash, Python 3 (stdlib only, using `match` statements), `sudo`, Docker (`docker run` + named volumes, no Compose), `pytest` for the guard logic's unit tests.

## Global Constraints

- Guard/interceptor files are owned by `dev`, never writable by `claude` — only their designated service user (via `sudo`) or `dev` (via full sudo) can invoke or change them.
- `sudo` for `claude` grants exactly one command per tool: the tool's own guard script, `RunAs` exactly that tool's service user. No broader grant, ever.
- Credentials for a wrapped tool live only under a directory owned `0700` by that tool's service user; they are never passed as `docker run -e` environment variables.
- A freshly wrapped tool with no curated policy in `guards/<tool>.py` defaults to denying everything.
- Every layer (interceptor → sudo → guard → real binary) must preserve stdio so piping and exit codes work exactly as if Claude called the tool directly.
- Full design context and rationale: `docs/superpowers/specs/2026-07-21-tool-sandboxing-design.md` — read it before starting if anything below is ambiguous.

---

### Task 1: Verify Docker Desktop's UID passthrough — COMPLETE

**This task is done.** Both diagnostics were written and run directly (the
bind-mount one needs an interactive `sudo` password prompt, which isn't
available to an automated subagent — it was run by hand in a real
terminal). Findings, already committed in `7952c7a`:

- `scripts/verify-uid-passthrough.sh` (bind mount): **failed**. A file
  `chown`'d `2000:2000` on the host read back as `uid=0 gid=0` inside the
  container, and a non-matching UID could still read it. Bind-mount-based
  credential provisioning was dropped as a result.
- `scripts/verify-named-volume-uid.sh` (named volume): **passed**. `chown
  2000:2000` + `chmod 600` performed inside one throwaway container read
  back correctly (`uid=2000 gid=2000 mode=600`) from a second, independent
  container sharing the same volume, and a non-matching UID got a real
  permission-denied. Tasks 8–10 below use named volumes for credential
  provisioning as a result of this finding, not the original bind-mount
  design.

No further action needed for this task — proceed to Task 2.

---

### Task 2: Add `claude` user, `workspace` group, and global sudoers defaults

**Files:**
- Modify: `Dockerfile`

**Interfaces:**
- Produces: `claude` user (member of `workspace`), `workspace` group (containing `dev` and `claude`), global sudoers defaults that later tasks rely on: `secure_path` prioritizing `/opt/interceptors`, `umask=0002` + `umask_override` for group-writable file creation, `!requiretty` for `claude`.

- [ ] **Step 1: Add the changes to the Dockerfile**

Insert this immediately after the existing `dev` user block (after the `chmod 0440 /etc/sudoers.d/dev` line, before `USER dev`):

```dockerfile
# Restricted user that runs Claude Code itself. No broad sudo — only
# per-tool grants added by wrap-tool.sh (see later RUN steps), each scoped
# to exactly one guard script.
RUN useradd --create-home --shell /bin/bash claude

# Shared group so dev and claude can both read/write the same project
# files (bind-mounted from the host at `docker run` time). Deliberately
# NOT used for /opt/guards, /opt/interceptors, or any tool's credential
# directory — those stay dev/service-user-owned so claude's workspace
# membership grants it no extra access there.
RUN groupadd workspace \
    && usermod -aG workspace dev \
    && usermod -aG workspace claude

# secure_path: ensures /opt/interceptors is checked before the real
# binaries whenever sudo constructs a command's PATH (this is what makes
# claude-run's `sudo -u claude claude` and any future sudo call land on the
# interceptors first).
# umask + umask_override: sudo applies its own default umask (0022) to
# whatever it execs regardless of the caller's shell umask, unless told
# otherwise here — 0002 is required for the workspace group-write scheme
# in this plan to actually take effect for anything claude creates via
# claude-run.
# !requiretty (claude only): Claude Code's Bash tool calls may not have a
# controlling tty; sudo must not refuse on that basis.
RUN { \
      echo 'Defaults secure_path="/opt/interceptors:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'; \
      echo 'Defaults umask=0002'; \
      echo 'Defaults umask_override'; \
      echo 'Defaults:claude !requiretty'; \
    } > /etc/sudoers.d/claude-defaults \
    && chmod 0440 /etc/sudoers.d/claude-defaults \
    && visudo -cf /etc/sudoers.d/claude-defaults
```

- [ ] **Step 2: Build the image and verify**

Run: `./build.sh`

Expected: build succeeds. Then:

Run: `docker run --rm devcontainer-base:latest bash -c "id claude && getent group workspace && sudo -l -U claude"`

Expected: `id claude` shows a `workspace` group membership; `getent group workspace` lists both `dev` and `claude`; `sudo -l -U claude` runs without error (may report "User claude is not allowed to run sudo" at this point, since no per-tool grant exists yet — that's expected until Task 6).

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "Add restricted claude user, shared workspace group, and sudo defaults"
```

---

### Task 3: Shared guard library (`guards/_common.py`)

**Files:**
- Create: `guards/_common.py`
- Test: `tests/test_common.py`

**Interfaces:**
- Produces: `decide_and_log(argv: list[str], decide: Callable[[list[str]], bool], log_path: str, tool_name: str) -> bool` (pure, testable) and `run(decide, real_executable: str, log_path: str, tool_name: str) -> None` (calls `decide_and_log`, then either exits 1 with a stderr message or `os.execv`s — not unit tested directly, since it replaces the process).
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_common.py
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "guards"))
from _common import decide_and_log


def test_logs_allowed_decision(tmp_path):
    log_path = tmp_path / "tool.log"
    result = decide_and_log(["pr", "view"], lambda argv: True, str(log_path), "gh")
    assert result is True
    entry = json.loads(log_path.read_text().splitlines()[0])
    assert entry["tool"] == "gh"
    assert entry["argv"] == ["pr", "view"]
    assert entry["allowed"] is True


def test_logs_denied_decision(tmp_path):
    log_path = tmp_path / "tool.log"
    result = decide_and_log(["repo", "delete"], lambda argv: False, str(log_path), "gh")
    assert result is False
    entry = json.loads(log_path.read_text().splitlines()[0])
    assert entry["allowed"] is False


def test_appends_rather_than_overwrites(tmp_path):
    log_path = tmp_path / "tool.log"
    decide_and_log(["a"], lambda argv: True, str(log_path), "gh")
    decide_and_log(["b"], lambda argv: False, str(log_path), "gh")
    assert len(log_path.read_text().splitlines()) == 2
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pip install --user pytest 2>/dev/null; python3 -m pytest tests/test_common.py -v`

Expected: FAIL with `ModuleNotFoundError: No module named '_common'` (file doesn't exist yet).

- [ ] **Step 3: Write the implementation**

```python
# guards/_common.py
import json
import os
import sys
import time


def decide_and_log(argv, decide, log_path, tool_name):
    allowed = decide(argv)
    with open(log_path, "a") as f:
        f.write(json.dumps({
            "ts": time.time(),
            "tool": tool_name,
            "argv": argv,
            "allowed": allowed,
        }) + "\n")
    return allowed


def run(decide, real_executable, log_path, tool_name):
    argv = sys.argv[1:]
    allowed = decide_and_log(argv, decide, log_path, tool_name)
    if not allowed:
        print(f"blocked by guard policy: {tool_name} {' '.join(argv)}", file=sys.stderr)
        sys.exit(1)
    os.execv(real_executable, [real_executable] + argv)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_common.py -v`

Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add guards/_common.py tests/test_common.py
git commit -m "Add shared guard library with pure, testable decision logging"
```

---

### Task 4: `gh` guard policy (`guards/gh.py`)

**Files:**
- Create: `guards/gh.py`
- Test: `tests/test_gh_guard.py`

**Interfaces:**
- Consumes: `_common.run` (Task 3).
- Produces: `decide(argv: list[str]) -> bool`, importable without side effects (the `run(...)` call only fires under `if __name__ == "__main__"`, and the `gh_config` import — which doesn't exist in the repo, only generated at build time by Task 5 — is deferred into that same block so this file can be imported directly in tests without needing a real build).

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_gh_guard.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "guards"))
import gh


def test_allows_pr_view():
    assert gh.decide(["pr", "view", "42"]) is True


def test_allows_pr_list():
    assert gh.decide(["pr", "list"]) is True


def test_allows_pr_diff():
    assert gh.decide(["pr", "diff", "42"]) is True


def test_allows_issue_view_and_list():
    assert gh.decide(["issue", "view", "7"]) is True
    assert gh.decide(["issue", "list"]) is True


def test_allows_repo_view():
    assert gh.decide(["repo", "view"]) is True


def test_denies_repo_delete():
    assert gh.decide(["repo", "delete", "some/repo"]) is False


def test_denies_secret_set():
    assert gh.decide(["secret", "set", "TOKEN"]) is False


def test_denies_pr_merge():
    assert gh.decide(["pr", "merge", "42"]) is False


def test_denies_empty_argv():
    assert gh.decide([]) is False
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_gh_guard.py -v`

Expected: FAIL with `ModuleNotFoundError: No module named 'gh'`.

- [ ] **Step 3: Write the implementation**

```python
# guards/gh.py
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from _common import run


def decide(argv: list[str]) -> bool:
    match argv:
        case ["pr", "view", *_] | ["pr", "list", *_] | ["pr", "diff", *_]:
            return True
        case ["issue", "view", *_] | ["issue", "list", *_]:
            return True
        case ["repo", "view", *_]:
            return True
        case _:
            return False  # deny by default — widen deliberately, case by case


if __name__ == "__main__":
    from gh_config import TOOL_NAME, REAL_EXECUTABLE, LOG_PATH
    run(decide, REAL_EXECUTABLE, LOG_PATH, TOOL_NAME)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_gh_guard.py -v`

Expected: 9 passed.

- [ ] **Step 5: Commit**

```bash
git add guards/gh.py tests/test_gh_guard.py
git commit -m "Add curated gh guard policy: allow pr/issue/repo view-ish commands"
```

---

### Task 5: `wrap-tool.sh` — build-time wrapping helper

**Files:**
- Create: `scripts/wrap-tool.sh`
- Test: `scripts/test-wrap-tool.sh`

**Interfaces:**
- Consumes: `guards/_common.py` and (optionally) `guards/<tool>.py` (Tasks 3–4), expected to be present under `/opt/guard-src/` inside whatever image/container it runs in.
- Produces: `/opt/guards/<tool>.py`, `/opt/guards/_common.py`, `/opt/guards/<tool>_config.py`, `/opt/interceptors/<tool>`, `/etc/sudoers.d/<tool>-guard`, a service user, and an entry in `/etc/wrapped-tools.json`. Called as `wrap-tool.sh <tool-name> <real-executable-path> <credential-path>`.

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Write a containerized test for it**

This runs `wrap-tool.sh` inside a throwaway `debian:trixie-slim` container (not the real devcontainer image, which doesn't exist yet with this wired in until Task 6) and asserts on the files it produces.

```bash
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
```

- [ ] **Step 3: Run the test**

Run: `chmod +x scripts/wrap-tool.sh scripts/test-wrap-tool.sh && ./scripts/test-wrap-tool.sh`

Expected: last line of output is `ALL_CHECKS_PASSED`.

- [ ] **Step 4: Commit**

```bash
git add scripts/wrap-tool.sh scripts/test-wrap-tool.sh
git commit -m "Add wrap-tool.sh build-time helper and its containerized test"
```

---

### Task 6: Install `gh` CLI and wire `wrap-tool.sh` into the Dockerfile

**Files:**
- Modify: `Dockerfile`

**Interfaces:**
- Consumes: `scripts/wrap-tool.sh` (Task 5), `guards/_common.py` + `guards/gh.py` (Tasks 3–4).
- Produces: a built image with `gh` fully wrapped — `claude` can run `gh` (via the interceptor) but not read its credentials directly.

- [ ] **Step 1: Add `gh` CLI installation and the `wrap-tool.sh` invocation to the Dockerfile**

Insert after the `claude`/`workspace`/sudoers block from Task 2, still before `USER dev`:

```dockerfile
# GitHub CLI, gated behind the guard/interceptor scheme below — claude
# never gets to run this binary directly with credentials attached.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/wrap-tool.sh /usr/local/sbin/wrap-tool.sh
COPY guards/ /opt/guard-src/
RUN chmod +x /usr/local/sbin/wrap-tool.sh \
    && wrap-tool.sh gh /usr/bin/gh /home/gh/.config/gh
```

- [ ] **Step 2: Build and verify the wiring**

Run: `./build.sh`

Expected: build succeeds (no `visudo` failures, no `useradd` conflicts).

Run:
```
docker run --rm devcontainer-base:latest bash -c '
  getent passwd gh
  stat -c "%U:%G %a" /home/gh/.config/gh
  stat -c "%U:%G %a" /opt/interceptors/gh
  cat /etc/wrapped-tools.json
'
```

Expected: `gh` user exists; `/home/gh/.config/gh` is `gh:gh 700`; `/opt/interceptors/gh` is `dev:dev 755`; the manifest contains `"gh": {"uid": 2000, "credential_path": "/home/gh/.config/gh"}`.

- [ ] **Step 3: Verify `claude` cannot read gh's credential directory, but can reach the interceptor**

Run:
```
docker run --rm devcontainer-base:latest bash -c '
  sudo -u claude ls /home/gh/.config/gh 2>&1 || true
  sudo -u claude sudo -u gh /opt/guards/gh.py --version
'
```

Expected: the first command prints a permission-denied error (`claude` cannot list `gh`'s credential directory); the second succeeds and prints `gh`'s version (since `--version` isn't matched by any `case` in `decide` yet it *will* currently be denied — that's correct: expect `blocked by guard policy: gh --version` and a non-zero exit, confirming the guard's default-deny is actually wired up end to end).

- [ ] **Step 4: Commit**

```bash
git add Dockerfile
git commit -m "Install gh CLI and wrap it with the guard/interceptor scheme"
```

---

### Task 7: `claude-run` launcher

**Files:**
- Create: `scripts/claude-run`
- Modify: `Dockerfile`

**Interfaces:**
- Produces: `/usr/local/bin/claude-run` inside the image, the command `dev` types instead of `claude` directly.

- [ ] **Step 1: Write the launcher**

```sh
#!/bin/sh
# scripts/claude-run
# Run this instead of `claude` directly — it starts Claude Code as the
# restricted `claude` user rather than as `dev`. See
# docs/superpowers/specs/2026-07-21-tool-sandboxing-design.md.
exec sudo -u claude claude "$@"
```

- [ ] **Step 2: Install it in the Dockerfile**

Add after the `wrap-tool.sh gh ...` line from Task 6:

```dockerfile
COPY scripts/claude-run /usr/local/bin/claude-run
RUN chmod 0755 /usr/local/bin/claude-run
```

- [ ] **Step 3: Build and verify**

Run: `./build.sh`

Run:
```
docker run --rm devcontainer-base:latest bash -c '
  sudo -u dev bash -c "touch /tmp/probe-file && claude-run --version" 2>&1 || true
  stat -c "%U:%G %a" /tmp/probe-file
'
```

Expected: `claude-run --version` runs as `claude` (fails or succeeds depending on whether Claude Code needs a config directory that doesn't exist yet in this throwaway run — either way it should not fail with a permissions/sudoers error). `/tmp/probe-file`, created as `dev` under the `umask 0002` default from Task 2, should show mode `664` (group-writable), confirming the sudoers `umask`/`umask_override` defaults are taking effect generally (this checks the umask default works for `dev`'s own shell; Task 10's smoke test checks it specifically through `claude-run`).

- [ ] **Step 4: Commit**

```bash
git add scripts/claude-run Dockerfile
git commit -m "Add claude-run launcher for starting Claude Code as the restricted user"
```

---

### Task 8: `rotate-credential.sh` — push a host credential into its named volume

**Files:**
- Create: `scripts/rotate-credential.sh`

**Interfaces:**
- Consumes: `/etc/wrapped-tools.json` (produced inside the image by Task 6's `wrap-tool.sh` call), for a tool's `uid` and `credential_path`.
- Produces: a Docker named volume `<tool>-creds`, containing a fresh copy of the tool's host credential, owned `<uid>:<uid>` inside the volume. Callable standalone (`scripts/rotate-credential.sh gh`), and by `run-container.sh` (Task 9) on every launch.

Named volumes are used instead of bind mounts here because bind-mount ownership does not survive on this machine (Task 1's finding) — named volumes were verified to work correctly instead.

- [ ] **Step 1: Write the script**

```bash
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
read -r UID_ CREDENTIAL_PATH < <(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
info = data['$TOOL']
print(info['uid'], info['credential_path'])
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
  "

echo "rotated $TOOL credential into volume $VOLUME"
```

The write-to-a-temp-name-then-`mv` pattern (rather than copying straight
onto the final filenames) makes each file replacement atomic, so a `gh`
invocation reading concurrently during a rotation sees either the fully-old
or fully-new file, never a partial one.

- [ ] **Step 2: Test it against a real `gh` credential**

Requires Task 6's image to already be built (it is, from earlier in this
plan). Run:
```
chmod +x scripts/rotate-credential.sh
./scripts/rotate-credential.sh gh
docker run --rm -v gh-creds:/data debian:trixie-slim bash -c '
  stat -c "uid=%u gid=%g mode=%a" /data/hosts.yml
  stat -c "uid=%u gid=%g mode=%a" /data/config.yml
'
```

Expected: both files show `uid=2000 gid=2000 mode=600` (2000 being the `gh`
service user's UID from Task 6's manifest), confirming the copy, chown, and
atomic rename all worked.

- [ ] **Step 3: Commit**

```bash
git add scripts/rotate-credential.sh
git commit -m "Add rotate-credential.sh: push a host credential into its named volume"
```

---

### Task 9: `run-container.sh` — host-side launch

**Files:**
- Create: `scripts/run-container.sh`

**Interfaces:**
- Consumes: `/etc/wrapped-tools.json` (Task 6), `scripts/rotate-credential.sh` (Task 8).
- Produces: a running, detached container with each wrapped tool's credential volume mounted read-only and the workspace directory bind-mounted and group-shared; `docker exec -it <name> sudo -u dev -i` to attach a shell (dev can start tmux inside and open more panes with further `docker exec`s, or just use tmux's own pane-splitting within one exec'd shell).

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Smoke-test the mounting logic against the real image**

Run:
```
chmod +x scripts/run-container.sh
mkdir -p /tmp/fake-code
WORKSPACE_HOST_PATH=/tmp/fake-code ./scripts/run-container.sh
```
(exit the attached shell with `exit` once it drops you in)

Expected: `rotate-credential.sh gh` runs as part of startup with no errors; the script prints the "container is up" message and attaches a `dev` shell. Then, from a second terminal:
```
docker exec devcontainer bash -c '
  stat -c "%U:%G %a" /home/gh/.config/gh/hosts.yml
  cat /home/gh/.config/gh/hosts.yml > /dev/null && echo "read as root: ok"
  stat -c "%U:%G %a" /home/dev/workspace
'
docker exec devcontainer bash -c 'echo test > /home/gh/.config/gh/should-fail' && echo "UNEXPECTED: write succeeded" || echo "expected: read-only mount refused the write"
docker rm -f devcontainer
```
Expected: `hosts.yml` shows `gh:gh` ownership; `/home/dev/workspace` shows the `workspace` group with the setgid bit set (mode contains a leading `2`, e.g. `2775`); the write attempt is refused because the volume is mounted `:ro`.

- [ ] **Step 3: Commit**

```bash
git add scripts/run-container.sh
git commit -m "Add run-container.sh: credential volume provisioning and workspace group setup at launch"
```

---

### Task 10: End-to-end smoke test

**Files:**
- None created — this is a manual verification pass exercising Tasks 1–9 together. Record any fixes needed back into the relevant task's files.

**Interfaces:**
- None — this task validates the whole chain described in the spec's "Request flow" section.

- [ ] **Step 1: Start the container with a real `gh` credential and confirm the guard allows a listed command**

Run (from the host):
```
WORKSPACE_HOST_PATH=/tmp/fake-code ./scripts/run-container.sh
```
Inside the attached `dev` shell:
```
claude-run --version
```
Then, in a second `docker exec devcontainer bash` shell (as `dev`, to simulate what `claude` would do — or genuinely `sudo -u claude bash` if `claude-run`'s own session is occupied):
```
sudo -u claude gh pr list
```
Expected: this resolves to `/opt/interceptors/gh` (confirm with `sudo -u claude which gh` first, expect `/opt/interceptors/gh`), the guard allows it (`pr list` is in the allow-list from Task 4), and it runs the real `gh` binary as the `gh` service user — with a real token this should return actual PR data (or a clean "not a git repo" / API error if run outside a repo, which is still proof it reached the real `gh` binary with credentials, not a permissions error).

- [ ] **Step 2: Confirm a non-allow-listed command is denied**

Run: `sudo -u claude gh repo delete some/repo`

Expected: stderr shows `blocked by guard policy: gh repo delete some/repo`, exit code is non-zero, and `/var/log/guards/gh.log` (readable as `dev`, since `dev` has full sudo) has a new line with `"allowed": false` for that argv — confirm with:
```
sudo cat /var/log/guards/gh.log | tail -2
```

- [ ] **Step 3: Confirm `claude` cannot bypass the guard**

Run each of these as `claude` (`sudo -u claude bash -c '...'`) and confirm all fail:
```
cat /home/gh/.config/gh/hosts.yml          # expect: permission denied
sudo /usr/bin/gh pr list                   # expect: sudoers denies this — only /opt/guards/gh.py is grantable
sudo -u gh /usr/bin/gh pr list             # expect: sudoers denies this too, same reason
/usr/bin/gh pr list                        # expect: runs (nothing stops execution), but fails/empty since claude has no readable gh credentials — confirms the spec's "why the real binary doesn't need locking down" reasoning holds in practice, not just in theory
```

- [ ] **Step 4: Confirm workspace file sharing works both directions**

As `claude` (via `claude-run`'s session or `sudo -u claude bash`):
```
touch /home/dev/workspace/claude-wrote-this
stat -c "%U:%G %a" /home/dev/workspace/claude-wrote-this
```
Expected: mode `664` (group-writable — confirms the `umask=0002`/`umask_override` sudoers defaults from Task 2 actually apply through the `claude-run` → `sudo -u claude` path, not just for `dev`'s own shell as checked in Task 7). Then as `dev`:
```
echo "dev editing claude's file" >> /home/dev/workspace/claude-wrote-this
```
Expected: succeeds without a permissions error.

- [ ] **Step 5: Confirm rotating the credential is picked up without restarting**

Run (host): `./scripts/rotate-credential.sh gh`

Then, back inside the already-running container (no restart): `sudo -u claude gh pr list`

Expected: still works — the running container's `:ro` mount of the `gh-creds` volume reflects the freshly-rotated content immediately, since named volumes share live backing storage rather than snapshotting per mount.

- [ ] **Step 6: Record the outcome**

If every check above passed, no code changes are needed — this task is verification only. If anything failed, fix the relevant task's files (most likely Task 2's sudoers defaults, Task 6's `wrap-tool.sh` invocation, or Task 8/9's credential volume handling) and re-run this task's steps from the top before considering the plan complete.

---

## Future work (not in this plan)

- Wrapping `aws` CLI the same way, once real usage patterns clarify what its `guards/aws.py` allow-list should permit — nothing in Tasks 5, 6, 8, or 9 is `gh`-specific except the `guards/gh.py` policy content and the `case gh:` branch in `rotate-credential.sh`'s credential-source lookup.
