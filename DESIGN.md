# DESIGN: BYO-keys-free sandbox runtime

**Status:** v1 shipped (Anthropic auto-pipe only); Codex/Gemini + markdown export = v1.1
**Slug:** `sandbox-byok-free-runtime`
**Last updated:** 2026-06-05

> Archived planning sections (ToT alternatives, Reflexion gates,
> assumption checks, implementation plan checklist, open questions) lived
> here pre-v1; they're now in git history. This file keeps only the
> decisions and the boundary model.

## Goal

`bin/sandbox.sh up` with **zero LLM-auth configuration**. The sandbox
inherits the host's LLM provider auth (Anthropic OAuth, OpenAI Codex
token, etc.), pipes it via the existing tmpfs / `docker exec` mechanism,
and lets the user run any LLM CLI inside the container as if on the
host. Sandbox-side state (conversations, prompt cache, MCPs) persists
across `docker rm` in a per-login named volume; transcripts also export
as markdown to the host inbox.

Verifiable success: a fresh-machine user with Claude Code installed on
host can run `bin/sandbox.sh up && claude` inside the container and get
a working prompt **without supplying any keys, env vars, or config**.

## Decisions

1. **Auto-pipe** with probe-and-skip per provider. Cheap and graceful;
   reconsider explicit opt-in if maintenance crosses ~3 providers.
2. **Persistent sandbox-side LLM state** in a per-login named volume.
   Local first; remote sync (git/Obsidian Sync) deferred. Markdown
   export to host inbox makes the archive Obsidian-readable by
   construction.
3. **Users install MCPs as needed.** No baked-in MCP servers.
4. **Full inherited scope.** No attempt to mint a read-only sub-token.

Rejected: wholesale bind-mount of host `~/.claude/` (tunnels work
context — Linear/Slack MCP configs, host conversations); container-side
OAuth flow (headless device-code is fragile, host already has the
session).

## Boundary model

### Forwarded ephemerally (piped, shredded after read)

| Provider | Host source | Container destination | Probe |
|---|---|---|---|
| Anthropic (Claude Code) | `~/.claude/.credentials.json` (0600) | `~/.claude/.credentials.json` (0400, in named volume) | `[[ -s ~/.claude/.credentials.json ]]` |
| OpenAI (Codex) | `~/.codex/auth.json` if exists | `~/.codex/auth.json` (named volume) | `[[ -s ~/.codex/auth.json ]]` |
| Gemini | `~/.config/gemini/credentials.json` if exists | same path (named volume) | `[[ -s ~/.config/gemini/credentials.json ]]` |

All piped via `docker exec -i sh -c 'cat > /run/secrets/<provider>_token'`
(the established GH_TOKEN pattern). Entrypoint reads → writes to the
in-container destination → `shred -u`s the tmpfs file. Token never
appears in `-e` env, `--build-arg`, image layers, or `docker inspect`.

### Persistent across `docker rm` (named volume `<login>-llm`)

Mounted at `/workspace/home/.config/llm-state/`:

- `claude/projects/` — conversations started *inside* the sandbox.
  Isolated from host `~/.claude/projects/` (work conversations never
  cross the boundary).
- `claude/cache/`, `claude/agents/` — prompt cache, downloaded models.
- Per-provider mirrors for Codex / Gemini.

### Markdown export to host inbox

On periodic autosave + EXIT trap, export new Claude Code sessions from
`<login>-llm/claude/projects/*.jsonl` to:

```
$SANDBOX_INBOX_DIR/conversations/<iso-ts>/<convo-slug>.md
```

Standard session-to-markdown rendering (frontmatter + one `## user` /
`## assistant` section per turn). Readable in Obsidian; a user can `mv`
an export into `people/<ldap>/active/<slug>.md` to bring it under
worklog FSM. Git-syncable independently of the named volume.

### Ephemeral (lost on `docker rm`)

- Container FS (apt installs, /tmp).
- Tmpfs `/run/secrets/*` (auto, by design).
- Shell history (unless user persists `~/.bash_history` into
  `<login>-toolchains`).
- Reasoning traces / tool-call logs *not yet exported* by autosave.

### Never crossed

- Host `~/.claude/projects/` (work conversations + work MCP configs).
- Host `~/.claude/settings.json` hooks (sandbox has its own minimal
  hooks; never inherits the host autosave/compact-kernels chain).
- Host SSH keys.
- Host `~/.config/<work-mcp>/` (Linear, Slack, work Gmail).

### Identity-isolation invariants (unchanged)

- `GITHUB_TOKEN` / `GH_ENTERPRISE_TOKEN` refused at entrypoint.
- `SANDBOX_REFUSE_PATTERNS` active (user-configurable employer-shape
  filter).
- Anthropic OAuth tokens are user-personal (no employer dimension at
  the OAuth provider level), so forwarding them doesn't widen the
  boundary the way `GITHUB_TOKEN` would.
