---
name: sandbox-lifecycle
description: "Bring up, exec into, tear down, and nuke a cheshirecode/sandbox dev container. Use when the user says 'start the sandbox', 'tear down the sandbox', 'sandbox up/down/nuke', 'run X in the sandbox', or asks to verify something inside an identity-isolated container. Lives at sandbox-repo/skills/sandbox-lifecycle/SKILL.md; covers OrbStack and Docker Desktop equivalently."
---

# sandbox-lifecycle

Operational reference for driving `cheshirecode/sandbox` from an agent. The
full design rationale, invariants, and hazards live in `AGENTS.md` and
`DESIGN.md` in the same repo — read those before changing the script.
This file is just the lifecycle commands an agent reaches for daily.

## Pre-flight

- Repo checked out at `~/Documents/oss/sandbox` (or wherever the user
  put it; this skill assumes that path).
- Docker daemon reachable. OrbStack and Docker Desktop both work; OrbStack
  is 2-3× faster on macOS. Switch via `docker context use orbstack`.
- Active profile resolved from (in order): `--profile=<name>` flag,
  `$SANDBOX_PROFILE`, or auto-detect from `mounts.env`. Default profile
  is the GitHub login the host is signed into.

Quick check: `bin/sandbox.sh doctor` (host preflight + active layout).

## Setup (bring up)

```bash
cd ~/Documents/oss/sandbox

# Bring container up; entrypoint pipes Anthropic + Codex creds from host.
# `--no-attach` returns control once the container is running and ready —
# always use it from a non-TTY agent context (avoids "cannot attach stdin
# to a TTY-enabled container" errors).
bin/sandbox.sh up --no-attach                       # active profile
bin/sandbox.sh --profile=<name> up --no-attach      # explicit profile
```

Image building happens automatically on first `up` (or after `rebuild`).
Once running, the container name is `<login>-sandbox` (e.g.
`cheshirecode-sandbox`).

## Running commands inside

From an agent (no TTY), prefer `docker exec` directly to avoid the
`-it` flag baked into `bin/sandbox.sh exec`:

```bash
docker exec <login>-sandbox bash -lc '<command>'
```

From a human shell, `bin/sandbox.sh exec <cmd>` is fine.

To test a `cheshirecode/*` repo end-to-end (clone + install + `npm test`):

```bash
bin/sandbox.sh test-repo <repo-name>        # = cheshirecode/<name>
bin/sandbox.sh test-repo <owner>/<repo>     # explicit owner
```

## Teardown

Two flavors, depending on whether you want to keep cached toolchains:

```bash
# Stop + remove container; named volumes survive (toolchains, gh auth,
# claude state, codex state). Cheapest, default reach-for.
bin/sandbox.sh down

# Full teardown of the active profile: container + image + named volumes.
# Use when verifying a fresh-machine bring-up.
bin/sandbox.sh nuke

# Also remove host runtime dirs (.sandbox-home/, learnings-inbox/).
bin/sandbox.sh nuke --all
```

Reproducibility loop:

```bash
bin/sandbox.sh nuke --all && bin/setup-from-scratch.sh
```

## Cleanup (host-side cruft)

`bin/sandbox.sh prune` only touches sandbox-owned state (containers,
named volumes, `*/sandbox:*` images). Safe to run anytime.

```bash
bin/sandbox.sh prune              # dry-run
bin/sandbox.sh prune --apply      # actually remove
bin/sandbox.sh prune --hard       # also surface (not delete) non-sandbox
                                  # dangling images + buildkit instances
```

## Multi-profile

```bash
bin/sandbox.sh list                              # all profiles on host
bin/sandbox.sh inspect [<login>]                 # detail one profile
bin/sandbox.sh profile-new <name> --login=<gh>   # create profile config
bin/sandbox.sh profile-list
bin/sandbox.sh profile-delete <name>
```

Profile configs live at `~/.config/sandbox/profiles/<name>.env`.

## Things that bite

- **TTY:** `bin/sandbox.sh exec` adds `-it`; in agent contexts use
  `docker exec <container> bash -lc '...'` instead. Same for
  `bin/sandbox.sh up` without `--no-attach`.
- **pnpm:** image ships Node v20 + npm. pnpm is not preinstalled. Enable
  per-container via `corepack enable pnpm --install-directory ~/.local/bin`
  and pin to `pnpm@10` (pnpm@latest requires Node ≥22). Persists across
  rebuilds because `~/.local` lives in the toolchains volume… *if* you
  installed it there.
- **Identity mismatch refusal:** `up --profile=<name>` from a shell that
  hasn't loaded `~/Documents/oss/.envrc` (so `gh auth token` returns the
  wrong account) exits 78 with `REFUSING TO START — identity mismatch`.
  Fix: `source ~/Documents/oss/.envrc && bin/sandbox.sh up …` (or
  `direnv exec ~/Documents/oss …`). Do not bypass — this is the guard
  that keeps work tokens out of personal sandboxes.
- **Detached volumes don't migrate:** `orbctl docker migrate` skips
  volumes not attached to a running container. To move named volumes
  between Docker contexts, `tar`-stream them manually
  (see README § OrbStack vs Docker Desktop).
- **OrbStack VM start timeout:** `orb start` sometimes reports
  "timed out waiting for VM to start" but `orb status` shows `Running`
  immediately after. Trust `orb status`.

## Out of scope

This skill is the operational lifecycle only. For:

- Why the sandbox exists / threat model → `DESIGN.md`
- Repo-internal conventions (D3 trailers, Karpathy voting,
  dogfood-as-DoD) → `AGENTS.md`
- Building/extending the entrypoint, Dockerfile, tests → start at
  `AGENTS.md § Learned hazards`
