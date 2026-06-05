# DESIGN: BYO-keys-free sandbox runtime

**Status:** v1 shipped (Anthropic auto-pipe only); Codex/Gemini + markdown export = v1.1
**Slug:** `sandbox-byok-free-runtime`
**Last updated:** 2026-06-05

## Goal

Users invoke `bin/sandbox.sh up` with **zero LLM-auth configuration**. The
sandbox inherits whatever LLM provider auth the host already has (Claude
Code's Anthropic OAuth, Codex's OpenAI token, etc.), pipes it via the
existing tmpfs/`docker exec` mechanism, and lets the user run any LLM CLI
inside the container as if they were on the host. Sandbox-side state
(conversations, prompt cache, installed MCPs) persists across `docker rm`
in a per-login named volume; conversation transcripts also export as
markdown to the host inbox for worklog/Obsidian compatibility.

Verifiable success: a fresh-machine user with Claude Code installed on
host can run `bin/sandbox.sh up && claude` inside the container and get a
working prompt **without supplying any keys, env vars, or configuration**.

## Approaches considered (ToT)

1. **Auto-pipe all detected providers, no opt-in** — PICKED. Cheap run
   cost; small maintenance surface (1-2 providers on this host today;
   add others when they appear). Probe-and-skip keeps it graceful for
   providers the user doesn't have.
2. **Explicit opt-in via `SANDBOX_FORWARD_LLMS=anthropic openai`** —
   Rejected: forces user to learn another knob. The whole point is
   zero-config. Reconsider if maintenance burden grows past ~3 providers.
3. **Bind-mount host `~/.claude/` wholesale** — Rejected. Tunnels work-
   context (host conversations, MCP configs pointing at work systems
   like Linear/Slack) into the sandbox. Defeats the identity-isolation
   invariant.
4. **Container-side OAuth flow** — Rejected. Headless OAuth via device
   code is fragile, and the host already has a working session — using
   it costs zero round-trips.

## User-confirmed decisions

1. **Auto-pipe** with probe-and-skip per provider (confirmed cheap).
2. **Persistent on user machine** for sandbox-side conversation state.
   Local first; remote sync (git-backed worklog or Obsidian Sync) layered
   later. Markdown export to host inbox makes the data Obsidian-readable
   and worklog-vault-compatible by construction.
3. **Users install MCPs as needed.** No baked-in MCP servers in the image.
4. **Full inherited scope.** No attempt to mint a read-only sub-token.

## Boundary model (against existing identity-isolation invariants)

### What gets forwarded ephemerally (piped, shredded after read)

| Provider | Host source | Container destination | Probe |
|---|---|---|---|
| Anthropic (Claude Code) | `~/.claude/.credentials.json` (mode 0600) | `~/.claude/.credentials.json` (mode 0400, in named volume) | `[[ -s ~/.claude/.credentials.json ]]` |
| OpenAI (Codex) | `~/.codex/auth.json` if exists | `~/.codex/auth.json` (named volume) | `[[ -s ~/.codex/auth.json ]]` |
| Gemini | `~/.config/gemini/credentials.json` if exists | same path (named volume) | `[[ -s ~/.config/gemini/credentials.json ]]` |

All piped via host-side `docker exec -i sh -c 'cat > /run/secrets/<provider>_token'`
(the existing GH_TOKEN pattern). Entrypoint reads, writes to the in-
container destination, `shred -u`s the tmpfs file. Token never appears
in `-e` env, `--build-arg`, image layers, or `docker inspect`.

### What persists across `docker rm` (new named volume: `<login>-llm`)

Mounted at `/workspace/home/.config/llm-state/`:

- `claude/projects/` — conversations started *inside* the sandbox.
  Isolated from host's `~/.claude/projects/` (which holds work
  conversations and never crosses the boundary).
- `claude/cache/`, `claude/agents/` — prompt cache, downloaded models.
- `codex/sessions/` — if user uses Codex inside.
- Any other LLM CLI's per-session state.

Sandbox's `~/.claude/`, `~/.codex/`, etc. become **symlinks** into this
volume (set up at entrypoint). Claude Code thinks it has a normal `$HOME`;
the persistence is invisible.

### Markdown export to host (the worklog/Obsidian half)

On periodic autosave + on EXIT trap, **export any new Claude Code
sessions** from `<login>-llm/claude/projects/*.jsonl` into markdown at:

```
$SANDBOX_INBOX_DIR/conversations/<iso-ts>/<convo-slug>.md
```

Format: standard Claude Code session-to-markdown rendering (frontmatter
with model + token-count + timestamps; one `## user` / `## assistant`
section per turn). This makes the conversations:

- Readable in Obsidian (host inbox is already a markdown directory).
- Compatible with the worklog vault layout — a user can `mv` the export
  into `people/<ldap>/active/<slug>.md` if they want it under worklog FSM.
- Git-syncable independently of the named volume (the volume is the
  live cache; the markdown is the archive).

### Ephemeral (lost on `docker rm`)

- Container FS (apt installs, /tmp scratch).
- Tmpfs `/run/secrets/*` (auto, by design).
- Shell history (unless user persists `~/.bash_history` into
  `<login>-toolchains` — current behavior).
- Reasoning traces / tool-call logs *if not yet exported* by autosave.

### Never crossed (host stays untouched)

- Host `~/.claude/projects/` (work conversations + work MCP configs).
- Host `~/.claude/settings.json` hooks (the sandbox has its own minimal
  hooks; never inherits the autosave/compact-kernels hook chain pointed
  at the private worklog repo).
- Host SSH keys (excluded already).
- Host `~/.config/<work-mcp>/` (Linear, Slack, work Gmail).

### Identity-isolation invariants (unchanged)

- `GITHUB_TOKEN` / `GH_ENTERPRISE_TOKEN` still refused at entrypoint.
- `SANDBOX_REFUSE_PATTERNS` still active (user-configurable employer-
  shape filter).
- Anthropic OAuth tokens are **user-personal** (no employer dimension at
  the OAuth provider level), so forwarding them doesn't widen the
  boundary in the way `GITHUB_TOKEN` would.

## Implementation plan (CoT)

- [ ] **1.** Extend `mounts.env` with the new named volume `<login>-llm`
      and mount point `/workspace/home/.config/llm-state`.
      → **verify:** `tools/check-mounts-sync.sh` still passes after the
      devcontainer.json mirror is updated.

- [ ] **2.** Extend `bin/sandbox.sh up` host-side probe: detect Anthropic
      / OpenAI / Gemini credential files; for each present, pipe via
      `docker exec -i sh -c 'cat > /run/secrets/<provider>_token'`.
      → **verify:** running `bin/sandbox.sh up` with Claude Code installed
      on host lands a non-empty `/run/secrets/anthropic_token` (assertable
      via test container before entrypoint runs).

- [ ] **3.** Extend `entrypoint.sh`: read each tmpfs provider token,
      write to canonical in-container location, shred. Symlink
      `~/.claude` → `/workspace/home/.config/llm-state/claude` (and
      analogues) before the LLM CLI looks for its config.
      → **verify:** `claude --version` inside the container finds the
      OAuth state and authenticates; `ls /run/secrets/` is empty.

- [ ] **4.** Add `container-export-conversations.sh`: walk
      `<login>-llm/claude/projects/*.jsonl`, render new turns to
      markdown, write to `$SANDBOX_INBOX_DIR/conversations/<iso-ts>/`.
      Hooked into the existing periodic autosave + EXIT trap.
      → **verify:** start a sandbox, run `claude` with a short prompt,
      exit; an .md file exists in the host inbox under
      `learnings-inbox/<ts>/conversations/`.

- [ ] **5.** Test cases in `tests/run.sh`:
      - `tmpfs anthropic token wiped after entrypoint`
      - `~/.claude symlinks into llm-state volume`
      - `conversations/ export dir populated after autosave`
      - `host work conversations NOT present in sandbox`
      → **verify:** `./tests/run.sh functional` exits 0 with N+4 tests.

- [ ] **6.** Update `README.md`: zero-config quickstart section; explain
      what's persistent / ephemeral / off-limits.
      → **verify:** README's quickstart is `bin/sandbox.sh up && claude`
      — no env-var setup steps required.

- [ ] **7.** Update `DESIGN.md` "Status" to `implemented` and remove
      from the repo (or keep as ADR — caller's call).

## Reflexion gates

- **After step 2:** does the host probe handle the keychain-only case
  for Claude Code (`.credentials.json` may be a cache; the actual token
  lives in macOS keychain)? If `cat ~/.claude/.credentials.json` returns
  the OAuth refresh token, we're fine. If not, the cleanest fallback is
  `claude auth print-token` (if such a command exists) or asking the
  user to refresh once. Step 2 is the early-fail point for the design.

- **After step 4:** if Claude Code's session format changes between
  versions, the markdown exporter breaks. Limit blast radius: exporter
  emits "unable to parse session vN" and continues, never crashes the
  autosave hook.

- **3-strike pivot:** if step 2 (host probe) or step 4 (exporter) each
  fail 3 different ways, switch to **explicit opt-in** (`SANDBOX_FORWARD_LLMS="anthropic"`)
  as a graceful degradation. Don't keep tweaking probes.

## Assumptions to verify early (Karpathy "Think Before Coding")

1. **Claude Code's `~/.claude/.credentials.json` contains a usable
   refresh token by itself** (not just a stub pointing at the keychain).
   → Check: `jq . ~/.claude/.credentials.json` on host; if the file
   contains an `access_token`/`refresh_token` field, we're good. If
   keychain-only, step 2 needs a different host probe (`security
   find-generic-password -s 'Claude Code-credentials' -w`).

2. **The container can use the OAuth token by writing it to
   `~/.claude/.credentials.json`** (i.e., Claude Code doesn't require
   keychain access in the container).
   → Check on first implementation: write a known-valid token into a
   test container's `~/.claude/.credentials.json` and run `claude
   --version` (or similar). If it authenticates, we're fine.

3. **Symlinking `~/.claude` to a volume-backed dir doesn't confuse
   Claude Code's file-watch / atomic-write logic** (some tools `rename(2)`
   over the credentials file on token refresh, which can break across
   bind-mount boundaries).
   → Check: do a token-refresh inside the sandbox and confirm the
   refreshed token persists in the named volume.

4. **Markdown export from `*.jsonl` is reversible enough to be useful**
   — we lose some metadata but the conversation reads cleanly in
   Obsidian / a worklog body.
   → Check: dogfood the export on a real session and read it back.

## Open questions (will iterate after this draft is confirmed)

- Should the named volume be `<login>-llm` (one volume for all
  providers) or split per provider (`<login>-claude`, `<login>-codex`)?
  Single is simpler; per-provider lets users nuke one without affecting
  the others. Leaning single until evidence of multi-provider conflict.
- Should the markdown exporter run *eagerly* (after each turn) or
  *lazily* (only on autosave/exit)? Eager gives finer-grained git
  history; lazy keeps the host filesystem quieter. Leaning lazy.
- What's the cleanup story for the named volume? A `bin/sandbox.sh
  nuke-llm-state` subcommand, or just document `docker volume rm
  <login>-llm`?
