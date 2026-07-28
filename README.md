# devcontainer

A Debian-based development container image: tmux + neovim (kickstart.nvim)
+ Claude Code, with Claude Code sandboxed behind its own restricted user and
a per-tool policy-checking guard system.

## Purpose

This image is meant to let you run Claude Code in "yolo"/dangerous-permissions
mode — where it can execute arbitrary shell commands without asking first —
while keeping a human-controlled boundary around what it can actually do to
sensitive external systems (starting with GitHub, via `gh`).

Claude Code itself is not what enforces this boundary. The boundary is
enforced by Linux users, file permissions, and `sudo`, which Claude Code
cannot talk its way around the way it might a purely prompt-based
restriction. See "Philosophy" below for the full reasoning.

## How to use the image

Build it:

```bash
./build.sh
```

Start a sandboxed container from whatever directory you want to work in —
`run-container.sh` defaults the workspace to your current directory at
invocation time, not the repo's own directory:

```bash
cd ~/code/some-project
/path/to/devcontainer/scripts/run-container.sh
```

This does the following, in order:
1. Reads the image's tool manifest (`/etc/wrapped-tools.json`) to see which
   tools are wrapped and what credentials they need.
2. For each wrapped tool, rotates its current host-side credential into a
   dedicated Docker volume (see "How to rotate keys").
3. Starts the container with those credential volumes mounted read-only,
   plus your current directory bind-mounted as the workspace.
4. Sets up the workspace directory for `dev`/`claude` shared read-write
   access.
5. Attaches an interactive shell as `dev`.

From that `dev` shell, use tmux as normal — split panes for `nvim` and for
Claude Code. **Always start Claude Code via `claude-run`, not `claude`
directly** — this is what actually switches it to the restricted `claude`
user:

```bash
claude-run
```

You can edit the same project with a host-side editor at the same time —
the workspace is a live bind mount, not a copy, so changes from either side
show up immediately on the other. `run-container.sh`'s own sandboxing only
restricts the `claude` user's access to wrapped tools inside the
container; it has no effect on anything you run on the host.

**Recommended: alias it on your host** so you can start the container from
any project directory with one command. In `~/.zshrc`:

```bash
alias start-claude-container=/path/to/devcontainer/scripts/run-container.sh
```

Then `cd` into any project and run `start-claude-container` — the
workspace will be whatever directory you were standing in.

Relevant environment variables for `run-container.sh`:
- `WORKSPACE_HOST_PATH` (default: your current directory when you invoke it) — the host directory bind-mounted as your project workspace. Set this explicitly to override the current-directory default.
- `WORKSPACE_CONTAINER_PATH` (default `/home/dev/workspace`) — where it lands inside the container.
- `CONTAINER_NAME` (default `devcontainer`) — re-running `run-container.sh` with the same name replaces the existing container. If you want multiple sandboxed containers for different projects running at once, give each a distinct `CONTAINER_NAME`.
- `IMAGE_NAME` / `IMAGE_TAG` (default `devcontainer-base` / `latest`) — which image to run.

## How to control tool use

Every wrapped tool (currently just `gh`) is only reachable through a
**guard**: a small Python script at `guards/<tool>.py` that decides, per
invocation, whether to allow it. This is the file you edit to open or close
what Claude Code is allowed to do.

`guards/gh.py` uses a `match` statement over the command's arguments:

```python
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
```

To allow something new, add a `case` that returns `True` for it — as
narrowly as you're comfortable with (e.g. `["pr", "comment", *_]` rather
than a broad `["pr", *_]`). Anything not matched by an allow-case falls
through to the final `case _: return False`, so the default is always deny.

After editing a guard, rebuild the image (`./build.sh`) for the change to
take effect, since guard files are baked into the image at build time (see
"Repo layout" for why they aren't writable at runtime).

**Every decision is logged.** Each guard call appends a JSON line to
`/var/log/guards/<tool>.log` inside the container, recording the timestamp,
the exact argv, and whether it was allowed. As `dev` (who has full sudo):

```bash
sudo cat /var/log/guards/gh.log
```

## How to rotate keys

Credentials for a wrapped tool never live inside the image and are never
passed as container environment variables — they're pushed into a
dedicated, per-tool Docker **named volume** at container start, and can be
refreshed at any time without restarting anything:

```bash
./scripts/rotate-credential.sh gh
```

This reads `gh`'s current credential from the host (`~/.config/gh` by
default, override with `GH_CREDENTIAL_SOURCE`), copies it into the
`gh-creds` named volume, and `chown`s it to the `gh` service user's uid.
Because the sandboxed container mounts this volume live (not a one-time
snapshot), **every already-running container picks up the rotated
credential on its very next `gh` call — no restart required.**

`run-container.sh` already calls this for every tool on every launch, so in
normal use you don't need to run it by hand — it's here for the case where
you rotate a token on the host (e.g. `gh auth login` again) while a
container is already up and want the new credential to take effect
immediately.

## How to add a new tool

1. Write `guards/<tool>.py` in this repo, following the shape of
   `guards/gh.py` (a `decide(argv) -> bool` function using a `match`
   statement, importing `run` from `_common` and calling it only inside
   `if __name__ == "__main__":`). If you skip this step, `wrap-tool.sh`
   will generate a stub that denies everything by default — safe, but
   non-functional until you flesh it out.
2. Add a host-credential-source case for the tool in
   `scripts/rotate-credential.sh`'s `case "$TOOL"` block (mirroring the
   `gh)` case), pointing at wherever that tool's credential lives on your
   host.
3. Add the tool's CLI installation and a `wrap-tool.sh` call to the
   Dockerfile, following the pattern of the existing `gh` block:
   ```dockerfile
   RUN wrap-tool.sh <tool-name> <path-to-real-executable> <credential-path>
   ```
4. Rebuild (`./build.sh`) and start a container — `run-container.sh`
   discovers wrapped tools generically from the image's manifest, so no
   changes are needed there.

If a single tool's credential rotation fails (e.g. step 2 was skipped),
`run-container.sh` logs a warning and skips that tool's mount rather than
refusing to start the whole container.

## Philosophy: users and guards as containment

The goal is to let Claude Code run unsupervised (yolo mode) while keeping a
human-editable, human-controlled boundary around what it can do to real
external systems. That boundary is built entirely out of standard Unix
mechanisms — Linux users, file permissions, and `sudo` — rather than
anything Claude Code itself is asked to respect. The reasoning: an
instruction like "don't run `gh repo delete`" is something an agent could
be confused, jailbroken, or simply wrong about; a `sudo` grant that
mathematically does not exist cannot be talked around.

**Three identity tiers, each with a narrowly-scoped job:**

- **`dev`** — you, the human. Full passwordless sudo. Owns every guard and
  interceptor file. This is the only identity that can edit policy.
- **`claude`** — runs Claude Code. No broad sudo at all. Its only sudo
  rights are one line per wrapped tool, each naming exactly one guard
  script as the command and exactly one service user as the target
  (`claude ALL=(gh) NOPASSWD: /opt/guards/gh.py`) — nothing broader is ever
  granted.
- **One service user per wrapped tool** (e.g. `gh`, uid 2000) — exists
  solely to own that tool's credentials and run its guard script. Nothing
  else runs as this user.

**The chain for a single command**, e.g. `gh pr view 42` typed by Claude
Code:

```
claude runs `gh` → resolves to /opt/interceptors/gh (PATH trick, see below)
  → exec sudo -u gh /opt/guards/gh.py pr view 42
    → sudo elevates to the `gh` user (only this exact script is grantable)
      → guard's decide() checks the argv against the allow-list, logs it
        → if allowed: os.execv's the real gh binary, now running as `gh`
          → `gh` can now read its own credentials and do the API call
```

A few design details make this hold up under adversarial pressure, not just
casual misuse:

- **The interceptor and guard are separate layers on purpose.** Sudoers
  grants `claude` the right to run the *guard script*, never the real
  binary. If it granted the real binary instead, `claude` could just call
  `sudo` directly and skip the policy check entirely — the two-layer split
  is what forces every path through the check.
- **The real `gh` binary itself doesn't need to be locked down.** Even if
  `claude` finds and runs `/usr/bin/gh` directly, it has no credentials to
  read (they live under a directory owned `0700` by the `gh` user), so
  the call is simply unauthenticated and fails. The credential file
  permissions are the actual enforcement boundary; the guard governs which
  *authenticated* actions are allowed once you're past that boundary.
- **PATH, not a symlink trick, routes `claude` to the interceptor.** A
  sudoers `secure_path` directive puts `/opt/interceptors` first whenever
  `sudo` builds a command's PATH — this is what makes `claude-run`'s
  `sudo -u claude claude` land Claude Code's own `$PATH` on the
  interceptors regardless of what PATH the invoking shell had.
- **Every layer preserves stdio.** Interceptor `exec`s into `sudo` (no new
  process); `sudo` forks+execs the guard, inheriting stdin/stdout/stderr;
  the guard's `os.execv` replaces itself with the real binary, keeping the
  same fds throughout. This is why piping (`gh pr list | jq ...`) and exit
  codes behave exactly as if Claude had called the real tool directly.
- **Credentials never touch a bind mount.** Early in this project,
  bind-mounting a host-`chown`'d credential file into the container was
  tried and found broken on Docker Desktop for Mac — ownership wasn't
  preserved, and permission enforcement was bypassed entirely. Named
  Docker volumes don't cross that host↔container translation boundary and
  were verified to enforce ownership correctly, which is why credentials
  are provisioned that way instead (see `docs/superpowers/specs/` for the
  full empirical writeup).
- **`dev` and `claude` can still fully share the workspace.** The
  containment boundary is deliberately *not* intra-workspace file
  permissions — `dev` and `claude` are meant to have full shared read/write
  over the project directory (via a shared `workspace` group), so Claude
  Code can actually edit code. The security boundary lives entirely at the
  guard layer around external tools, not around the filesystem you're
  both working in.

## Repo layout

```
Dockerfile                       # the image: dev/claude/workspace users, gh install + wrap-tool.sh call
build.sh                         # docker build wrapper

guards/
  _common.py                     # shared: decide_and_log() (pure, testable) + run() (logs, then denies or execs)
  gh.py                          # the actual, hand-curated policy for gh — edit this to change what's allowed

scripts/
  wrap-tool.sh                   # build-time: wraps one CLI behind a guard/interceptor (called from the Dockerfile)
  claude-run                     # run this instead of `claude` — switches to the restricted claude user
  rotate-credential.sh           # pushes a tool's host credential into its named Docker volume
  run-container.sh               # host-side launcher: rotates all credentials, starts the container, attaches a shell
  test-wrap-tool.sh              # containerized test for wrap-tool.sh
  verify-uid-passthrough.sh      # diagnostic: bind-mount UID passthrough (found broken on Docker Desktop for Mac)
  verify-named-volume-uid.sh     # diagnostic: named-volume UID passthrough (found working, used instead)

tests/
  test_common.py                 # unit tests for guards/_common.py
  test_gh_guard.py                # unit tests for guards/gh.py's decide()

docs/superpowers/
  specs/2026-07-21-tool-sandboxing-design.md   # full design rationale, including what was tried and found broken
  plans/2026-07-22-tool-sandboxing-plan.md     # the implementation plan this was built from
```

Inside the built image (not in this repo, generated by `wrap-tool.sh` at
build time):

```
/opt/interceptors/<tool>        # thin shell stub on claude's $PATH: exec sudo -u <tool> <guard>
/opt/guards/<tool>.py           # the guard, copied in from this repo (or a deny-everything stub)
/opt/guards/<tool>_config.py    # generated: real executable path, log path, tool name
/var/log/guards/<tool>.log      # JSON-lines decision log, owned by the tool's service user
/etc/sudoers.d/<tool>-guard     # claude ALL=(<tool>) NOPASSWD: /opt/guards/<tool>.py
/etc/wrapped-tools.json         # manifest of every wrapped tool: {"gh": {"uid": 2000, "credential_path": "..."}}
```
