# AGENTS.md

Instructions for any coding agent (Claude, Codex, Cursor, hermes-agent,
OpenClaw, future-model) checking out **cheshirecode/sandbox**. Written from
real bugs that bit during this repo's own construction; not aspirational
norms.

## What this repo is

`cheshirecode/sandbox` is an **ephemeral Docker dev container** that gives a
fresh shell with the user's *personal* GitHub identity (`cheshirecode`)
auto-piped from the host — never the user's work identity. Designed to host
work on other `cheshirecode/*` repos without leaking work credentials,
without polluting the host OS with `apt install`s, and without manual login
to Claude Code / Codex inside the container.

One repo, one container, one shell. Not a multi-tenant platform. Not a
production runtime.

## The non-negotiable invariants

Every change must preserve these. Tests enforce them; the entrypoint
refuses to start if they're violated.

1. **No work identity in the container, ever.** Entrypoint refuses to start
   if `$GITHUB_TOKEN`, `$GH_ENTERPRISE_TOKEN`, or any var matching
   `$SANDBOX_REFUSE_PATTERNS` is set. Test #1/#2 in `tests/run.sh`.

2. **Credentials transit via tmpfs `/run/secrets/*`, never via `-e`,
   `--build-arg`, or `docker inspect`-visible state.** Entrypoint reads
   then `shred -u`s. Test #4b/#4e.

3. **HTTPS-only git remotes inside the container.** SSH-agent forwarding
   is **never** enabled — it would tunnel the user's work SSH key. Test #5.

4. **`gpgsign=false` inside container.** Signing on the host, not inside the
   sandbox. Test #7.

5. **`gh auth setup-git` runs in entrypoint** so `git push https://github.com/...`
   doesn't prompt for username. Dogfood-discovered (see "Hazards" §
   credential-handling).

6. **Container runs `--user dev`, not root.** Production runtime flag —
   every test that exercises the container MUST also pass `--user dev`,
   otherwise it misses a whole class of permission bugs (see Hazards §
   `--user dev` blind-spot).

## Quick-start for a coding agent

If you're a fresh agent assigned to do work involving `cheshirecode/*`
repos, the canonical flow is:

```bash
# 0. Cd into this repo
cd ~/Documents/oss/sandbox    # or wherever the user clones it

# 1. Bring the container up (auto-pipes Anthropic + Codex creds from host)
bin/sandbox.sh up --no-attach

# 2. Run any cheshirecode/* repo's tests in one command
bin/sandbox.sh test-repo <repo-name>       # = cheshirecode/<name>
bin/sandbox.sh test-repo <owner>/<repo>    # explicit owner

# 3. For interactive shell work (npm install, edit, commit, push):
bin/sandbox.sh exec bash -l

# 4. When done
bin/sandbox.sh down                        # stops + removes container; volumes persist

# Reproducibility proof (also runs in CI):
bin/sandbox.sh nuke --all && bin/setup-from-scratch.sh
```

For multi-repo dogfooding (proven up to n=5+ repos in parallel), use sub-agents
partitioned by repo name. **But see Hazards § sub-agent-host-leak first.**

## Conventions a coding agent must follow in this repo

### D3 — Commit-trailer evidence

Every fix-shaped commit message ends with an `Evidence:` block citing the
actual command output that proves the fix. Example:

```
Evidence (D3 trailer):
  $ ./tests/run.sh functional → 18 PASS / 0 FAIL (was 17; added #4j)
  $ docker exec ... sudo apt install -y nodejs npm → works
  $ bin/sandbox.sh test-repo frontend-ai-template → exit 0 (43/43 tests)
```

Past councils proved this convention is the cheapest auditing tool in
the stack — it makes "did this fix actually work?" greppable in `git log`.

### Karpathy voting bar (every new candidate item passes ALL 5)

When proposing a feature/refactor/fix, ask the 5 questions:

| Criterion | Pass test |
|---|---|
| TRACES | Item directly addresses a user statement or filed issue |
| SOLVES-EXTANT-PAIN | A real observed problem, not speculation |
| N-THRESHOLD-MET | For abstractions: ≥3 concrete instances of the pattern |
| COST-PROPORTIONATE | Implementation cost matches the asserted user value |
| NON-INFRA-PADDING | User-visible, not tooling-for-future-tooling |

If any fails: REJECT with cited criterion, or QUALIFY with a concrete
trigger that would unblock it later. Full skill at
`~/.claude/skills/council/SKILL.md`.

### Dogfood-as-definition-of-done

A change is not done until it's been run against a real cheshirecode/* repo
end-to-end inside the sandbox. Structural tests catch shape; dogfood catches
behavior. Every fix this session that landed had a dogfood pass.

## Learned hazards (real bugs that bit; don't re-introduce)

These are surfaced in chronological order. Each was a real production bug
that shipped despite ~18 structural tests passing.

1. **bash 3.2 incompatibility (`mapfile`)** — macOS default `/bin/bash` is
   v3.2. Use inline read loops, not bash-4 builtins. CI must include a
   `/bin/bash` matrix row.

2. **`set -u` + empty array** — `printf '%s\n' "${args[@]}"` aborts when
   `args` is empty under `set -u`. Inline the producer or guard with
   `${args[@]+"${args[@]}"}`.

3. **docker-cp + `--user dev` chmod conflict** — `docker cp` lands files as
   root; subsequent `docker exec --user dev chmod` fails. Use stdin pipe
   instead: `printf '%s' "$x" | docker exec -i ... sh -c 'cat > /path'`.

4. **`tmpfs-mode=0700` + `--user dev` unwritable** — root-mode tmpfs + dev
   writer = ENOENT. Use default tmpfs mode (1777, sticky world-rwx). Don't
   add `tmpfs-mode` without a threat model.

5. **Stale `.gitconfig.lock` aborts entrypoint** — bind-mounted `$HOME`
   persists crash artifacts. Entrypoint must `rm -f $HOME/.gitconfig.lock`
   before `git config --global` calls. Test #4j.

6. **`gh auth login --with-token` rejects classic PATs missing `read:org`**
   — login-time scope check too strict. Write `~/.config/gh/hosts.yml`
   directly via `gh api user` probe (which works on minimal scopes).

7. **`--security-opt=no-new-privileges` blocks `sudo apt`** — never add
   security flags without a named threat model. Removed; if re-added,
   must come with a documented attacker model.

8. **Entrypoint didn't wire git credential helper** — `gh` auth ≠ `git
   push` auth. Run `gh auth setup-git` in entrypoint.

9. **Named-volume mount points root-owned** — Dockerfile must `mkdir -p`
   the mount targets (`/workspace/home/.claude`, `.codex`, etc.) as
   `dev`-owned BEFORE the volume initializes from the image dir.
   Otherwise the empty volume materializes root-owned. Test #4i.

10. **Node 18 in apt vs Node 22+ in modern vitest** — `apt install nodejs`
    on Ubuntu 24.04 gives Node 18; vitest 4 needs Node 22+ APIs
    (`node:util.styleText`). Bake NodeSource Node 20 LTS into image.

11. **shellcheck SC1087 `$var[ ,]`** — bash sees array-index ambiguity.
    Brace: `${var}[ ,]`. CI catches it; local pre-commit must too.

12. **Sub-agent host-leak when committing** — a sub-agent told to "commit
    + push" can run `git commit` **on the host** (picking up the user's
    work git config) instead of via `docker exec` into the sandbox.
    The sandbox's identity isolation only applies INSIDE the container;
    it cannot constrain what sub-agents do on the host. Real leak observed
    this session: a sub-agent committed to a `cheshirecode/*` repo with
    a `@ideogram.ai` work email. **Resolution:** the affected repo was
    nuked from GitHub by the maintainer — the leaked commit no longer
    exists. **Forward mitigation:** every commit-mutating sub-agent
    prompt must explicitly say `docker exec cheshirecode-sandbox bash -c
    "cd ...; git -c user.name=cheshirecode -c user.email=<id>+cheshirecode@users.noreply.github.com
    commit -m '...'"` — never `git commit` directly in the agent's bash
    tool. Author-audit every push (`gh api repos/<owner>/<repo>/commits
    --jq '.[].commit.author.email'`) before assuming the sandbox's
    identity isolation held end-to-end.

## Subcommand reference

```
bin/sandbox.sh up                build (if needed) + run + drop into shell
bin/sandbox.sh up --no-attach    same but return after entrypoint runs
bin/sandbox.sh exec <cmd>        run cmd in the running container
bin/sandbox.sh down              stop container; volumes preserved
bin/sandbox.sh rebuild           force rebuild image
bin/sandbox.sh doctor            host preflight + show detected layout
bin/sandbox.sh verify-llm-auth   in-container: do piped LLM creds work?
bin/sandbox.sh test-repo <name>  clone + install + test a cheshirecode/* repo
bin/sandbox.sh nuke [--all]      remove container + image + volumes
                                 (--all also removes .sandbox-home/, learnings-inbox/)
```

## When the sandbox is the wrong tool

Use the sandbox for:
- Working on `cheshirecode/*` repos (the design center)
- Running Claude Code / Codex against personal-OSS code without work-creds risk
- Exercising dependency installs that would pollute the host

**Do NOT use the sandbox for:**
- Anything requiring the user's work identity (ideogram/*, work repos)
- Long-running services (containers are designed ephemeral)
- Cursor IDE-driven work — Cursor's auth is keychain-only and currently
  bound to the user's work account; documented out of scope
- Workflows that need the in-container dev server reachable from the
  host browser (no port publishing in v1)

## Pointers

- `DESIGN.md` — original design council output (Anthropic auto-pipe v1)
- `README.md` — user-facing quickstart
- `tests/run.sh` — every named hazard above has a regression test
- `bin/setup-from-scratch.sh` — reproducibility-loop entry point
- `bin/sandbox.sh test-repo` — the n=3-evidenced dogfood shortcut

Council skill (orchestrates voting for any non-trivial proposal):
`~/.claude/skills/council/SKILL.md` (canonical) or
`~/Documents/oss/dotfiles/skills/council/SKILL.md` (vendored).
