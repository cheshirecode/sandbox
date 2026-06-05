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

## Zero-config LLM auth

If you already have **Claude Code** logged in on your host (macOS), the
sandbox auto-pipes your Anthropic OAuth credentials into the container
via a tmpfs path at `up` time. Inside the sandbox, `claude` "just works"
without any login step. Credentials persist across `docker rm` in a
per-login named volume; the tmpfs source is shredded after the
entrypoint reads it.

**No keys, env vars, or login flows required** as long as your host has
working `claude auth status`. Conversations started inside the sandbox
live in the `<login>-claude` named volume, isolated from your host's
`~/.claude/projects/` (which holds work conversations and is **never**
crossed into the sandbox).

macOS-only for v1.x (probe order: `~/.claude/.credentials.json` →
macOS keychain). Linux/WSL2 + Codex/Gemini auto-pipe planned for v1.1.

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

## Subcommands

```
bin/sandbox.sh up       build (if needed) + run + drop into shell
bin/sandbox.sh exec X   run X in the running container
bin/sandbox.sh down     stop the container (autosave fires)
bin/sandbox.sh rebuild  force rebuild the image
bin/sandbox.sh doctor   check host preconditions + show detected layout
```

Inbox curation: just `ls -lt $SANDBOX_INBOX_DIR/`. Files are files.
Cleanup: `docker image prune` / `docker volume rm <login>-toolchains <login>-gh`.

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
