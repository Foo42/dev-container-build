# Sandboxing Claude Code's tool access

## Problem

Claude Code currently runs (as the `dev` user) with full passwordless `sudo
ALL:ALL` inside the devcontainer. To run Claude Code in "yolo"/dangerous
permission mode safely, we need a way to run it as a restricted identity that
cannot directly execute sensitive CLIs (starting with `gh`, later `aws`, etc.)
or read their credentials, while still letting those tools work when their
use is within a policy we control and can edit ourselves.

## Goals

- Claude Code runs as a new, unprivileged `claude` user — no broad sudo.
- Sensitive tools (`gh` first) are only reachable through a policy check we
  author and can edit, not directly.
- The policy check is a small Python file with a `match` statement over
  argv, so extending/tightening it is quick and readable.
- A fresh, freshly-wrapped tool defaults to **deny everything** until we
  explicitly allow specific subcommands.
- The credentials for a wrapped tool (e.g. `gh`'s auth token) are never
  readable by the `claude` user, only by a dedicated per-tool service user.
- Adding a new wrapped tool is a repeatable, scripted step usable from the
  Dockerfile, not one-off hand configuration.
- Piping (`gh pr list | jq ...`) and exit codes work exactly as if Claude
  called the tool directly.

## Non-goals

- Sandboxing beyond CLI-argv-level policy (e.g. not trying to restrict what
  `git`/network access `dev` itself has, which stays as-is).
- A generic secrets manager. Credential provisioning here is specific to
  "some file(s) under a tool's home directory," which covers `gh` and is
  expected to cover `aws` later.

## Identity model

Three tiers, all in the container image:

- **`dev`** (existing, unchanged) — the interactive human user. Full sudo.
  Owns and can edit every interceptor and guard file.
- **`claude`** (new) — runs Claude Code. No broad sudo. Its only sudo rights
  are one `NOPASSWD` line per wrapped tool, each naming exactly one guard
  script, `RunAs` exactly one service user — nothing broader.
- **`<tool>`** (new, one per wrapped tool, e.g. `gh`) — a system user with a
  **fixed, known UID** (see "Credential provisioning" below), created
  specifically to own that tool's credential files. Nothing runs as this
  user except the tool's own guard script (via `claude`'s narrow sudo) and,
  after the guard allows it, the real binary.

## Request flow

For `gh pr view 42` typed/executed by Claude Code:

1. Claude Code (as `claude`) resolves `gh` on `$PATH` → hits
   `/opt/interceptors/gh`, a two-line shell stub owned by `dev`
   (not writable by `claude`, executable by `claude`).
2. The interceptor does nothing but
   `exec sudo -u gh /opt/guards/gh.py "$@"`.
3. `sudo` elevates to the `gh` user. This is only possible because sudoers
   names this **exact guard script** as the command, `RunAs gh` only — there
   is no sudoers rule that lets `claude` invoke the real `gh` binary, or run
   anything as `gh` other than this one script. `sudo`'s default
   `env_reset` applies, so nothing `claude` set in its own shell/environment
   carries through.
4. `gh.py` (owned by `dev`, running as `gh` because of the sudo call) calls
   its `decide(argv)` function, which is a `match` statement over the
   subcommand. It logs the decision, and if allowed, `os.execv`s the real
   `gh` binary — which can now read `gh`'s credentials, since it's running
   as `gh`.
5. If denied, it prints a message to stderr and exits non-zero. No
   credential is ever touched in this path.

This shape specifically closes the bypass we identified earlier: since sudo
only grants execution of the *guard script* (not the real binary) as the
service user, there is no sudo invocation available to `claude` that skips
the policy check.

Piping and exit codes work transparently because every layer preserves
stdio: the interceptor `exec`s into `sudo` (no new process, same fds);
`sudo` forks+execs the guard, inheriting the parent's stdin/stdout/stderr
(this is exactly what already lets today's `sudo cmd | other` work); and the
guard's `os.execv` replaces itself with the real binary, again keeping the
same fds. The real binary's exit code is what the whole chain ultimately
exits with.

## Directory & file layout

**Inside the container image:**

```
/opt/interceptors/<tool>        # thin shell stub, on claude's $PATH
/opt/guards/<tool>.py           # policy: match-statement filter, owned by dev
/opt/guards/_common.py          # shared helper: logging + exec, owned by dev
/opt/guards/<tool>_config.py    # generated constants (see below)
/var/log/guards/<tool>.log      # decision audit log, pre-created, owned by <tool>
/etc/sudoers.d/<tool>-guard     # claude ALL=(<tool>) NOPASSWD: /opt/guards/<tool>.py
/etc/wrapped-tools.json         # manifest: {"<tool>": {"uid": N, "credential_path": "..."}}
```

**In this git repo:**

```
scripts/wrap-tool.sh             # build-time helper, invoked from the Dockerfile
scripts/run-container.sh         # host-side launcher (calls rotate-credential.sh, then docker run)
scripts/rotate-credential.sh     # pushes a tool's current host credential into its named volume
guards/_common.py                # shared lib, copied verbatim into the image
guards/gh.py                     # curated, evolving gh policy — hand-edited over time
```

A tool wrapped without a matching `guards/<tool>.py` in the repo gets a
generated deny-everything stub in the image instead, meant to be fleshed
out and eventually promoted into the repo as a real file.

## Guard script anatomy

`guards/_common.py` (shared, tool-agnostic):

```python
import sys, os, json, time

def run(decide, real_executable, log_path, tool_name):
    argv = sys.argv[1:]
    allowed = decide(argv)
    with open(log_path, "a") as f:
        f.write(json.dumps({
            "ts": time.time(), "tool": tool_name,
            "argv": argv, "allowed": allowed,
        }) + "\n")
    if not allowed:
        print(f"blocked by guard policy: {tool_name} {' '.join(argv)}", file=sys.stderr)
        sys.exit(1)
    os.execv(real_executable, [real_executable] + argv)
```

Generated `<tool>_config.py` (always regenerated by `wrap-tool.sh`, never
hand-edited, never checked into the repo — this is how a portable,
repo-committed `guards/gh.py` avoids hardcoding container-specific paths):

```python
TOOL_NAME = "gh"
REAL_EXECUTABLE = "/usr/bin/gh"
LOG_PATH = "/var/log/guards/gh.log"
```

`guards/gh.py` (repo-committed, hand-curated, imports its sibling config by
the tool's fixed name — no runtime templating needed, since the tool name
and its config module name are the same by convention):

```python
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from _common import run
from gh_config import TOOL_NAME, REAL_EXECUTABLE, LOG_PATH

def decide(argv: list[str]) -> bool:
    match argv:
        case ["pr", "view", *_] | ["pr", "list", *_] | ["pr", "diff", *_]:
            return True
        case ["issue", "view", *_] | ["issue", "list", *_]:
            return True
        case ["repo", "view", *_]:
            return True
        case _:
            return False  # deny by default

run(decide, REAL_EXECUTABLE, LOG_PATH, TOOL_NAME)
```

A generated stub (no repo file for that tool yet) is the same shape, with
`decide` always returning `False` and a comment showing the pattern above
as a starting example.

## `wrap-tool.sh`

Invoked from the Dockerfile once per tool:

```
wrap-tool.sh <tool-name> <real-executable-path> <credential-path>
# e.g. wrap-tool.sh gh /usr/bin/gh /home/gh/.config/gh
```

Steps:

1. Auto-allocate the next UID: read `/etc/wrapped-tools.json` if it exists,
   take the max assigned UID + 1 (starting at a fixed base, e.g. 2000).
2. `useradd --system --uid <uid> --shell /usr/sbin/nologin <tool>`, create
   the credential path's parent directory owned `<tool>:<tool>` mode
   `0700`.
3. Generate `/opt/guards/<tool>_config.py` with `TOOL_NAME`,
   `REAL_EXECUTABLE`, `LOG_PATH`.
4. Copy `guards/<tool>.py` from the build context into
   `/opt/guards/<tool>.py` if it exists there; otherwise write the
   deny-everything stub. Copy `guards/_common.py` in if not already present.
   All owned by `dev`, mode not writable by `claude`.
5. Pre-create `/var/log/guards/<tool>.log`, owned `<tool>:<tool>`, mode
   `0600` (so the guard, running as `<tool>`, can always append without
   needing to create new files in a shared directory).
6. Write `/opt/interceptors/<tool>`:
   ```sh
   #!/bin/sh
   exec sudo -u <tool> /opt/guards/<tool>.py "$@"
   ```
   Owned `dev`, mode executable by `claude` but not writable by it.
7. Write `/etc/sudoers.d/<tool>-guard`:
   ```
   claude ALL=(<tool>) NOPASSWD: /opt/guards/<tool>.py
   ```
   Also ensure (once, not per-tool) `Defaults:claude !requiretty` is set,
   since Claude Code's Bash tool calls may not have a controlling tty and
   `sudo` must not balk on that.
8. Merge `{"<tool>": {"uid": <uid>, "credential_path": "<credential-path>"}}`
   into `/etc/wrapped-tools.json`.

`claude`'s `$PATH` must list `/opt/interceptors` before any directory
containing the real binaries, set explicitly (not inherited) in its shell
init / the container entrypoint.

Note: no step here restricts execute permission on the real `gh` binary
itself. That's intentional — see "Why the real binary doesn't need locking
down" below.

## Why the real binary doesn't need locking down

Since the wrapped tool's credentials live under a directory owned solely by
the `<tool>` user (mode `0700`), `claude` running the real binary directly
(if it found it on `$PATH` or via absolute path) is inert: it has no
credentials to read, so `gh` would simply fail to authenticate. The
credential file permissions are the actual enforcement boundary; the guard
script governs which *authenticated* actions are allowed. This avoids
needing to relocate or chmod the real binary at all.

## Credential provisioning at runtime (named Docker volumes)

Credentials must never be baked into the image (can't rotate, leak into
layers, shared with anyone holding the image), and must never be passed as
container-wide `docker run -e` environment variables (those are visible to
every process in the container regardless of user — that would hand
`claude` the same access we just locked down).

The original plan for this section was a bind-mounted, host-`chown`'d temp
copy, matched to each service user's fixed UID. That was tested (see
"Docker Desktop for Mac's bind-mount UID passthrough" below) and found
broken: Docker Desktop for Mac's bind-mount bridge does not reliably
preserve `chown`'d ownership from host to container, and does not enforce
per-UID read access on what it does mount. **Named Docker volumes** don't
have this problem — they live entirely inside Docker's Linux VM, so no
host↔container translation boundary is ever crossed for their content.
Confirmed empirically: a file `chown`'d `2000:2000` and `chmod`'d `600`
inside one throwaway container read back as `uid=2000 gid=2000 mode=600`
from a second, independent container sharing the same named volume, and a
different UID got a real permission-denied reading it.

One named volume per wrapped tool (e.g. `gh-creds`). Pushing the current
host credential into it is a standalone, idempotent operation, not a
one-time setup step — a named volume is a snapshot, not a live sync, so it
needs to be re-run whenever the host-side credential rotates. It's cheap
enough (a throwaway container copying one small file) to just re-run
unconditionally on every sandbox start too.

`scripts/rotate-credential.sh <tool>`:

1. Look up `<tool>`'s `uid` and `credential_path` from the image's
   `/etc/wrapped-tools.json` manifest (`docker run --rm --entrypoint cat
   <image> /etc/wrapped-tools.json`).
2. `docker volume create <tool>-creds` if it doesn't already exist.
3. Run a throwaway container that bind-mounts the host credential source
   read-only, and the named volume read-write. Inside that container:
   write the fresh content to a temp path *inside the volume*, `chown` it
   to `<uid>:<uid>` and `chmod` it appropriately, then `mv` it over the
   real target path within the volume. The `mv` is atomic (same
   filesystem), so any process reading the file mid-rotation sees either
   the fully-old or fully-new content, never a partial write.

`run-container.sh` calls `rotate-credential.sh` for every tool in the
manifest before starting the real container (so every launch runs against
the current host credential, never a stale one), then mounts each named
volume **read-only** at its `credential_path`, e.g.
`-v gh-creds:/home/gh/.config/gh:ro`. Read-only is a meaningful extra
safeguard, not just tidiness: even if something running as the `gh` service
user misbehaves, the mount itself refuses writes at the kernel level,
independent of file permission bits. It also means the same credential
volume can safely be mounted into multiple concurrent sandbox containers at
once (e.g. two separate project checkouts sharing one `gh` login) — Docker's
local volume driver has no exclusive-lock semantics, and since nothing but
`rotate-credential.sh` ever writes to it, there's no concurrent-writer
hazard.

Rotating a credential after containers are already running is just
re-running `rotate-credential.sh <tool>` — every running container with
that volume mounted sees the update on its very next read (each `gh`
invocation opens `hosts.yml` fresh; there's no long-lived file handle to go
stale), with no restart needed.

### Worked example: `gh`

Host source: `~/.config/gh/` (`hosts.yml` holding the token, `config.yml`
holding preferences — both already `0600`, owned by the host user, nothing
in the shell environment, confirmed via inspection of this machine).
Container target: named volume `gh-creds`, mounted **read-only** at
`/home/gh/.config/gh/` — the same relative layout `gh` already expects,
just backed by a named volume instead of a bind-mounted host directory.

## Launching Claude Code (`claude-run`)

The container doesn't `exec` into Claude Code as its entrypoint — `dev`
starts the container interactively and launches `nvim`, `claude`, etc. by
hand in separate tmux panes. So the chokepoint for "run Claude Code as the
restricted user" is a small launcher script, `claude-run`, that `dev` uses
instead of typing `claude` directly:

```sh
#!/bin/sh
exec sudo -u claude claude "$@"
```

Owned by `dev`; no special protection needed beyond that, since `dev`
already has unrestricted sudo — this script exists for convenience and
consistency, not as a security boundary.

This is also where the workspace-sharing `umask` (next section) needs to
take effect. One subtlety: `umask` is process state, not an environment
variable, so `sudo`'s `env_reset` doesn't clear it — but `sudo` applies its
**own** configured default umask (historically `0022`) to whatever it
execs, regardless of what the caller's umask was set to. So setting
`umask 002` before the `exec sudo` line in `claude-run` is not sufficient
on its own; sudoers also needs `Defaults:dev umask=0002` (or equivalent)
for this rule, or the `claude` process tree will silently get `0022`
instead. Easy to get wrong silently, so call it out explicitly during
implementation and verify it (`stat` a file Claude creates, confirm group
write bit) rather than assuming it worked.

## Workspace sharing between `dev` and `claude`

`dev` and `claude` will both read/write the same project files (`dev` via
interactive editing, `claude` via Claude Code's own edits) inside a
directory that's **bind-mounted from the host** at container start, not a
directory living purely in the image. That bind-mount fact rules out one of
the options we considered:

- **Rejected: POSIX ACLs.** Docker Desktop for Mac bridges host bind mounts
  into its Linux VM through a translation layer (historically `osxfs`, now
  usually VirtioFS) that handles basic Unix permission bits fine but does
  not reliably support Linux POSIX ACLs — the host side is APFS, which has
  a different ACL model entirely. `setfacl` on a bind-mounted directory is
  likely to fail or silently do nothing, so this isn't a safe foundation
  for the one directory in this design that's actually bind-mounted.
- **Chosen: shared group + setgid + umask.** Create a group (e.g.
  `workspace`) with both `dev` and `claude` as members. The project
  directory (and its subdirectories) get group-owned by `workspace` with
  the **setgid bit** (`chmod g+s`), so new files/subdirectories
  automatically inherit group `workspace` rather than the creating user's
  primary group. Both users need `umask 002` so newly created files are
  group-writable by default — for `claude`, set via the `claude-run`
  launcher + `Defaults:dev umask=0002` sudoers entry above (not via shell
  rc files, which non-interactive/non-login shells — plausibly including
  however Claude Code's Bash tool spawns its shells — can skip entirely).

This group and setgid treatment applies **only** to the project/workspace
directory. `/opt/guards`, `/opt/interceptors`, `/etc/sudoers.d/*`, and every
`<tool>` user's credential directory stay owned by `dev` (or `<tool>`) with
no `workspace` group involvement, so `claude`'s membership in `workspace`
grants it no extra access there — this falls out naturally as long as
`wrap-tool.sh` never touches group ownership on those paths.

## Docker Desktop for Mac's bind-mount UID passthrough: tested and found broken

The original credential scheme depended on `chown`-ing a temp copy to a
tool's fixed UID on the host, then bind-mounting it into the container,
trusting Docker Desktop for Mac's bind-mount bridge to preserve that
numeric ownership. Tested directly on this machine (`scripts/verify-uid-passthrough.sh`,
plus a manual run since it needs an interactive `sudo` password prompt):

- Host: `chown 2000:2000` on a probe file, confirmed via `stat`.
- Container (bind mount of that file): read back as `uid=0 gid=0` — not
  `2000`, and not even the host user's own UID.
- A container-side user with a *different*, non-matching UID could still
  read the file — i.e. the bridge wasn't enforcing ownership-based access
  control at all for this mount, not just mis-reporting it.

This falsified the load-bearing assumption for the original design, so
bind-mount-based credential provisioning was dropped in favor of named
Docker volumes (previous section), which were verified with the same kind
of test — `chown`/`chmod` performed inside one container, read back
correctly from a second, independent container sharing the same named
volume, with a non-matching UID correctly denied — and don't share this
failure mode, since their content never crosses the host↔container
translation boundary that broke the bind-mount case.

This finding is specific to *credential* provisioning. The workspace
directory (next section) still needs its own bind mount, since it must
stay a live, continuously-synced view of the host project files rather
than a point-in-time copy — a named volume can't provide that. Whether
`dev`/`claude` group-write sharing actually works correctly on a real
bind-mounted directory, given what this test found, has **not** yet been
verified and should be tested directly (write as `dev`, read/write as
`claude`, on an actual bind mount) before relying on it in the
implementation plan's workspace-sharing task.

## Alternative considered: Docker Compose secrets

Docker Compose has a built-in `secrets:` mechanism (the "file" provider,
works without Swarm) that can inject a host file into a container at a
given `uid`/`gid`/`mode` without a rebuild — this would have replaced
`run-container.sh`'s manual copy/chown/mount steps with a well-tested Docker
primitive. It was considered and **declined**: it constrains secrets to a
fixed `/run/secrets/<target>` directory (requiring tools to be redirected
via env vars like `GH_CONFIG_DIR` rather than reading their normal config
path) and would mean switching the run workflow from plain `docker run` to
`docker compose up`. We're keeping the hand-rolled `run-container.sh`
instead, trading some maintenance burden for full manual control and no
change to the existing `docker run`-based workflow.

## Future tools

`aws` CLI is the next tool expected to be wrapped this way (credentials
under `~/.aws/`). Nothing in this design is `gh`-specific except the
`guards/gh.py` policy content itself — `wrap-tool.sh`, the manifest, and
`run-container.sh` are all written generically over "tool name → real
executable → credential path."

## Open items for the implementation plan

- Exact `wrap-tool.sh` UID base and `useradd` flags (home directory
  handling for a `--system` user with a credential dir that isn't its
  literal home).
- Where in the Dockerfile `gh` itself gets installed (it isn't currently).
- `run-container.sh`'s handling of a tool with *no* credential_path
  (nothing to mount) vs. multiple credential files/dirs per tool.
- Whether `guards/gh.py`'s initial allowlist (the `pr`/`issue`/`repo`
  view/list/diff commands sketched above) is the right starting set, or
  should start even narrower.
- Verify the workspace bind mount's group-sharing behavior directly (write
  as `dev`, read/write as `claude`) before relying on it — the bind-mount
  UID passthrough test above failed in a way that specifically doesn't
  extend confidence to this still-untested case.
- Confirm `Defaults:dev umask=0002` (or equivalent) is actually needed/
  sufficient by testing a file `claude` creates through `claude-run` ends
  up group-writable, rather than assuming sudo's umask handling works as
  described.
- Where the `workspace` group and its members get declared/created, and
  which host path is bind-mounted as the project directory (not yet
  pinned down).
