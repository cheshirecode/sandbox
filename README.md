# sandbox

Ephemeral Docker dev sandbox for personal-OSS work, with **structural identity
isolation** from your work-machine credentials.

The sandbox auto-detects your GitHub login via `gh api user` and ties every
volume, image tag, and container name to it — so this repo works for any
fork without editing config.

Designed by a Karpathy-style multi-agent council. Decision trail lives in
the commit history (search for "council Stage 6" in `git log`).

## Why

- You have two GitHub identities (work + personal). You want a structural
  wall between them, not a `direnv exec` discipline alone.
- You want to `apt install <thing>` while exploring a repo without
  polluting your host OS.
- You want learnings from each session to flow back into committable
  artifacts (dotfiles install scripts, manifest entries, skills) via the
  snapshot-diff autosave hook.

## Zero-config LLM auth & Hermes Agent

The sandbox auto-pipes host LLM credentials into the container via tmpfs:
- **Hermes Agent (Nous Research)**: Pre-installed via `uv`. Inherits OpenRouter credentials from host (`~/.local/share/opencode/auth.json` or `OPENROUTER_API_KEY`) or existing `~/.hermes/config.json`. Persistent memory, skills, cron schedules, and sessions survive `docker rm` in the `<login>-hermes` named volume.
- **Claude Code**: Inherits Anthropic OAuth credentials. Sessions persist in `<login>-claude`.
- **OpenAI Codex**: Inherits Codex credentials. Sessions persist in `<login>-codex`.

**No keys, env vars, or login flows required** as long as your host has working credentials. Run Hermes Agent instantly with:
```bash
bin/sandbox.sh hermes
```
or start the messaging gateway with `bin/sandbox.sh gateway`.

## First-time setup (fresh machine walkthrough)

```bash
# 1. Host prereqs (macOS shown; Linux is `apt`/`dnf`/`brew`).
brew install gh docker direnv orbstack
gh auth login                          # personal GitHub account
                                       # (work-account login goes elsewhere)

# 2. Choose a workspace directory. The sandbox repo will sit INSIDE it;
#    the workspace is what gets bind-mounted into the container as /workspace/oss.
mkdir -p ~/oss && cd ~/oss

# 3. Clone the sandbox. Its location determines the workspace (the parent dir).
git clone https://github.com/<your-login>/sandbox.git
cd sandbox

# 4. Verify the auto-detection picked your identity:
bin/sandbox.sh doctor

# Expected output:
#   INFO github login:   <your-login>
#   INFO image:          <your-login>/sandbox:v1
#   INFO container name: <your-login>-sandbox
#   INFO volumes:        <your-login>-toolchains, <your-login>-gh
#   OK   workspace      /Users/<you>/oss
#   OK   sandbox $HOME  /Users/<you>/oss/.sandbox-home
#   OK   inbox          /Users/<you>/oss/learnings-inbox

# 5. First run — builds the image, drops you into a shell.
bin/sandbox.sh up

# Inside the container you have:
#   - The host workspace (cloned repos, edit-in-place) at /workspace/oss
#   - Persistent $HOME at /workspace/home (bind, host-inspectable)
#   - Toolchain caches at /workspace/home/.cache/toolchains (named volume)
#   - gh auth state at /workspace/home/.config/gh (named volume)
#   - HTTPS-only git remotes (SSH keys don't tunnel in)
#   - gpgsign off, refused-env guard for work-identity-shaped env vars
```

## Layout (auto-derived)

```
host                                       container             type      purpose
$SANDBOX_WORKSPACE/                    →   /workspace/oss        bind      OSS source-of-truth
$SANDBOX_WORKSPACE/.sandbox-home/      →   /workspace/home       bind      $HOME (gitignored runtime)
$SANDBOX_WORKSPACE/learnings-inbox/    →   /workspace/inbox      bind      autosave dumps (gitignored)
<login>-toolchains volume              →   /workspace/home/.{nvm,rustup,cargo}     toolchain caches (GB-scale)
<login>-gh volume                      →   /workspace/home/.config/gh              gh oauth state
<login>-hermes volume                  →   /workspace/home/.hermes                 Hermes memories, skills, cron, sessions
<login>-claude volume                  →   /workspace/home/.claude                 Claude Code sessions & state
<login>-codex volume                   →   /workspace/home/.codex                  Codex sessions & state
```

`SANDBOX_WORKSPACE` defaults to the directory CONTAINING this repo. Override
via `SANDBOX_WORKSPACE=/some/path bin/sandbox.sh up`.

Two named volumes survive `docker rm` (toolchains stay; gh auth persists).
Everything else is on host bind mounts and inspectable from your editor.

## Identity isolation

- HTTPS-only remotes inside the container. No SSH agent forwarding — that
  would tunnel your work SSH key into the sandbox.
- `GH_TOKEN` piped via tmpfs `/run/secrets/`, never `-e`, never build args.
  Re-injected on every `sandbox.sh up`; shredded after the entrypoint reads it.
- Entrypoint REFUSES to start if `GITHUB_TOKEN` (work-identity-shaped) or
  any `*IDEOGRAM*` / `*ANTHROPIC_INTERNAL*` env var is present. Override
  via `SANDBOX_REFUSE_PATTERNS=""` (don't).
- Git identity AUTO-DERIVED from `gh api user` against the piped token —
  whoever owns the token gets credited; no hardcoded names.
- gpg signing disabled inside the sandbox.

## Workflow extraction

Snapshot-diff, not interception. On entry: `dpkg --get-selections`,
`pip freeze`, `npm ls -g`, `env`, `ls $HOME/bin/`. On exit (TERM/INT/EXIT
trap): diff and dump to `$SANDBOX_INBOX_DIR/<iso-timestamp>/`. SIGKILL
loses ≤5min thanks to a periodic background autosave.

Secret-shape filter: env diffs strip values matching AWS (`AKIA*`),
Google (`AIza*`), OpenAI (`sk-*`), GitHub (`ghp_*`, `github_pat_*`) so
key shapes never land in inbox files.

You never get an auto-commit. Use your editor:
```
ls -lt $SANDBOX_INBOX_DIR/
$EDITOR $SANDBOX_INBOX_DIR/<latest>/
```
Cherry-pick what's worth promoting into the relevant dotfiles file by hand.

## Tied to which login?

- `gh api user` against the host's `gh auth token` (your personal account).
- Override: `SANDBOX_LOGIN=somename bin/sandbox.sh up`.

Inside the container, `gh api user` against the piped token confirms the
same login — both sides agree. If you forked this repo, the volumes
auto-namespace to your login on first `up`.

## Workspace-local repos

Two bind mounts (see `mounts.env`):

| Host | Container | Use |
|------|-----------|-----|
| `$SANDBOX_WORKSPACE` (default: parent of this repo, e.g. `~/Documents/oss`) | `/workspace/oss` | Personal-OSS repos (`_worklog`, `dotfiles`, …) |
| `$SANDBOX_PROJECTS_DIR` (default: sibling `~/Documents/projects`) | `/workspace/projects` | Ideogram-internal repos (`factory-brief`, `ui`, …) |

Edit and commit on the host with the matching tree identity (`oss/.envrc` vs
`projects/.envrc`). Use the sandbox only to verify (e.g. `npm test`):

```bash
docker exec cheshirecode-sandbox bash -lc 'cd /workspace/projects/factory-brief && npm test'
```

Recreate the container after mount changes: `bin/sandbox.sh down && bin/sandbox.sh up --no-attach`.

Use `source ~/Documents/oss/.envrc` before `up` so the piped gh token is
`cheshirecode`, not a work account.

## Subcommands

```
bin/sandbox.sh up               build (if needed) + run + drop into shell
bin/sandbox.sh hermes [args...] launch Hermes Agent interactive TUI
bin/sandbox.sh gateway [args...]launch Hermes Agent messaging gateway
bin/sandbox.sh exec <cmd>       run <cmd> in the running container
bin/sandbox.sh run-headless <cmd> [args...]
                                non-TTY run with stdout/stderr/exit/meta artifacts
bin/sandbox.sh status           list all sandbox profiles on host
bin/sandbox.sh list             list all sandbox profiles on host
bin/sandbox.sh test-repo <name> clone + install + npm test (cheshirecode/*)
bin/sandbox.sh down             stop the container (autosave fires)
bin/sandbox.sh rebuild          force rebuild the image
bin/sandbox.sh doctor           check host preconditions + show layout
bin/sandbox.sh verify-llm-auth  in-container check: piped LLM creds work?
bin/sandbox.sh nuke [--all]     remove container + image + named volumes
                                (--all also removes runtime dirs)
```

For daemon or agent callers, prefer `run-headless` over `exec`:

```bash
bin/sandbox.sh up --no-attach
bin/sandbox.sh run-headless bash -lc 'pwd; git status --short'
```

Each invocation writes a host-inspectable artifact directory under
`learnings-inbox/headless-runs/<run-id>/` containing `command.txt`,
`stdout.log`, `stderr.log`, `exit_code`, and `meta.env`. This is the
intended wrapper for worklog-manager dry-runs: inspect full artifacts locally,
then post only redacted summaries back to GitHub Issues.

Inbox curation: just `ls -lt $SANDBOX_INBOX_DIR/`. Files are files.

## Node versions and work repos

The image bakes a default Node major so common JS repo checks do not start
with `sudo apt-get install nodejs npm`. Default is Node 20 for stability, but
some repos now pin `engines: node>=22` or `node>=24`. For those, rebuild the
sandbox image with the repo's required major:

```bash
SANDBOX_NODE_MAJOR=24 bin/sandbox.sh rebuild
bin/sandbox.sh up --no-attach
```

Keep the identity boundary separate from the runtime boundary. Work repos
under `/workspace/projects` are mounted for verify-only runs with the personal
OSS sandbox identity still active. Edit and commit those repos on the host
with the matching parent-tree identity; use the sandbox for dependency/test
execution, or use the repo's own Docker setup when it is the stronger
environment contract.

## Reproducibility (clear + repeat from scratch)

The whole setup is scriptable and idempotent. To verify on your own machine,
or to onboard a fresh box (yours, a fork-owner's, or a CI runner):

```bash
# Fresh setup or first install
bin/setup-from-scratch.sh

# To force-rebuild image:
bin/setup-from-scratch.sh --rebuild

# To also verify your real LLM creds authenticate inside the container:
bin/setup-from-scratch.sh --verify-creds

# Nuke everything and prove the setup script reproduces it:
bin/sandbox.sh nuke --all
bin/setup-from-scratch.sh

# CI runs this same path on every push (job: fresh-machine-emulation),
# proving the "works on a vanilla Linux machine" promise.
```

The setup script's stages are visible at the top of `bin/setup-from-scratch.sh`
— each prints a `=== N/6 ===` header so you can watch the pipeline.

## Multiple instances from one repo (worktree + direnv pattern)

You can manage several concurrent or switchable sandboxes from this
single repo by leaning on `git worktree` + `direnv`. **No code changes**
— the existing `SANDBOX_LOGIN` env override already namespaces the
container, image, and named volumes.

```bash
# Add a worktree per instance. Each worktree is its own working dir.
git worktree add ../sandbox-foo
git worktree add ../sandbox-bar

# Per worktree, set a distinct SANDBOX_LOGIN via direnv:
cd ../sandbox-foo && echo 'export SANDBOX_LOGIN=cheshirecode-foo' > .envrc && direnv allow
cd ../sandbox-bar && echo 'export SANDBOX_LOGIN=cheshirecode-bar' > .envrc && direnv allow

# Now each worktree spins up an isolated sandbox:
cd ../sandbox-foo && bin/sandbox.sh up   # container: cheshirecode-foo-sandbox
cd ../sandbox-bar && bin/sandbox.sh up   # container: cheshirecode-bar-sandbox
```

Each instance gets its own container, image tag, and named volumes
(`<login>-toolchains`, `<login>-gh`, `<login>-claude`, `<login>-codex`).
Workspace bind-mount is the worktree's parent dir, so projects don't
collide.

To see what's running across all instances: `bin/sandbox.sh status` (alias
for `list`). To list raw Docker volumes: `docker volume ls`. `bin/sandbox.sh nuke` operates on the
**current** `$SANDBOX_LOGIN` only, so one worktree's nuke doesn't
touch the others.

## Installing LLM CLIs inside the sandbox

The auto-pipe lands Anthropic + Codex credentials at the canonical
paths inside the container, but the **CLIs themselves are not in the
image** (image stays small; install-as-needed per the user-choice
principle). After your first `bin/sandbox.sh up`, install them once:

```bash
# Inside the sandbox shell:
node --version && npm --version
npm install -g @anthropic-ai/claude-code @openai/codex
claude auth status      # should show your host's logged-in account
codex login status      # same
```

The `<login>-toolchains` named volume persists the npm cache, so
re-installs after `nuke` (without `--all`) are fast.

To verify the auto-piped credentials actually authenticate the CLIs:

```bash
# From host:
bin/sandbox.sh verify-llm-auth
```

## On Cursor support

Cursor is **not** in the sandbox's BYO-keys-free auto-pipe today.
`cursor-agent` typically logs in against an employer-tied account (the
sandbox's identity-isolation explicitly refuses work credentials). If
your `cursor-agent status` shows a personal-OSS account, this can be
revisited. Otherwise: continue to use Cursor on the host, not inside
the sandbox.

## Not in v1

- **devcontainer Features registry** — would inflate image / build time.
  Revisit when the v1 footprint stabilizes.
- **`--cap-drop=ALL`** — needs `install.sh` to be apt-free at entrypoint
  first. Hardening backlog.
- **Token expiry auto-refuse** — `gh auth token` has no TTL API for
  classic PATs. We warn (not refuse) when the response header is present.
- **Auto-rebuild on Dockerfile hash change** — manual `sandbox.sh rebuild`
  is enough for one user. Reconsider with evidence.
- **Skill-dir RO bind-mount** as a generic "drop tools into the sandbox"
  mechanism — `~/.claude/skills/` style. YAGNI until a real caller.

## OrbStack vs Docker Desktop

`bin/sandbox.sh` works on either. OrbStack is 2-3× faster on macOS (VirtioFS
+ lighter VM) and free for personal use:

```
brew install orbstack
```

`bin/sandbox.sh doctor` prints a tip if it detects Docker Desktop.

**Migration verified (2026-06-07):** sandbox lifecycle works end-to-end on
OrbStack with no script changes — `up --no-attach`, `exec`, `test-repo`,
`down`, and `nuke` behave identically. Named volumes (`<login>-toolchains`,
`-gh`, `-claude`, `-codex`) survive a `tar`-stream copy between Docker
contexts (`docker --context=desktop-linux run ... tar -cf -` →
`docker --context=orbstack run ... tar -xf -`); the migrator's built-in
`orbctl docker migrate` only copies volumes attached to running containers,
so detached named volumes need this manual step.

## Testing

```
./tests/run.sh static      # shellcheck + mounts↔devcontainer sync + JSON parse
./tests/run.sh build       # docker build + image-size budget
./tests/run.sh functional  # 9 image-based behavior tests (identity isolation,
                           # token wipe, HTTPS rewrite, secret-shape filter, etc.)
./tests/run.sh all
```

Tests use literal `fake-token-...` ASCII strings to exercise the entrypoint's
read-and-shred path. No real credentials transit the test boundary.

## License

[Unlicense](./LICENSE).
