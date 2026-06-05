#!/usr/bin/env bash
# Sandbox entrypoint. Walks the design-council acceptance criteria:
#
#  1. Refuse to start on leak-prone host env vars (work-identity-shaped).
#  2. Read GH_TOKEN from tmpfs /run/secrets/gh_token (piped in by host); never
#     accept it via -e or build args. Wipe the file after gh auth login.
#  3. Derive git identity from `gh api user` (auto-tied to the piped token's
#     GitHub account); override via GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL env.
#  4. Warn-not-refuse if token expiry is parseable and <24h away.
#  5. Snapshot dpkg/pip/env/bin/$HOME state for autosave diff on exit.
#  6. Periodic autosave every 5min (background) so SIGKILL loses ≤5min.
#  7. Trap TERM/INT/EXIT → run autosave once more on shutdown.

set -euo pipefail

# --- 1. Refuse on leak-prone env -------------------------------------------
# Always refuse the GitHub-canonical work-identity env vars.
for var in GITHUB_TOKEN GH_ENTERPRISE_TOKEN; do
  if [[ -n "${!var:-}" ]]; then
    echo "sandbox-entrypoint: refusing to start — host env var '$var' is set." >&2
    echo "  This env-var shape implies a non-personal identity. Sandbox isolates by design." >&2
    exit 64
  fi
done
# Additional caller-defined patterns (regex over env var NAMES).
# Set SANDBOX_REFUSE_PATTERNS in your personal .envrc to block employer-specific
# env-var shapes (e.g., 'MYCORP|VENDOR_INTERNAL'). Default: empty (no extra patterns).
if [[ -n "${SANDBOX_REFUSE_PATTERNS:-}" ]]; then
  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    echo "sandbox-entrypoint: refusing to start — env var '$var' matches SANDBOX_REFUSE_PATTERNS." >&2
    exit 64
  done < <(compgen -v 2>/dev/null | grep -E "$SANDBOX_REFUSE_PATTERNS" || true)
fi

# --- 2. GH_TOKEN via tmpfs --------------------------------------------------
# /run/secrets/gh_token is a tmpfs path (declared in mounts.env). The host's
# bin/sandbox.sh pipes `gh auth token` into it before starting this container.
# We never read GH_TOKEN from $env — that would leak via `docker inspect`.
TOKEN_FILE="/run/secrets/gh_token"
if [[ -s "$TOKEN_FILE" ]]; then
  # gh auth login --with-token reads from stdin, persists oauth state to
  # ~/.config/gh (mounted as the per-user named volume "${LOGIN}-gh").
  gh auth login --with-token < "$TOKEN_FILE" --hostname github.com 2>/dev/null || {
    echo "sandbox-entrypoint: gh auth login failed (token rejected or expired)" >&2
  }
  # Wipe after use — token lives in the named volume's hosts.yml from here on.
  shred -u "$TOKEN_FILE" 2>/dev/null || rm -f "$TOKEN_FILE"
elif gh auth status >/dev/null 2>&1; then
  echo "sandbox-entrypoint: reusing cached gh auth (no fresh token piped in)."
else
  echo "sandbox-entrypoint: WARN — no token piped, no cached auth. gh + push will fail." >&2
fi

# --- 2b. Anthropic OAuth via tmpfs (optional auto-pipe) -------------------
# /run/secrets/anthropic_token is the on-disk JSON Claude Code expects at
# ~/.claude/.credentials.json. The named volume <login>-claude is mounted at
# ~/.claude so the credentials persist across docker rm.
# Graceful skip if not piped — Claude Code can still be installed + logged-
# in manually inside the sandbox.
ANTHROPIC_TOKEN_FILE="/run/secrets/anthropic_token"
if [[ -s "$ANTHROPIC_TOKEN_FILE" ]]; then
  mkdir -p "$HOME/.claude"
  cp "$ANTHROPIC_TOKEN_FILE" "$HOME/.claude/.credentials.json"
  chmod 0600 "$HOME/.claude/.credentials.json"
  shred -u "$ANTHROPIC_TOKEN_FILE" 2>/dev/null || rm -f "$ANTHROPIC_TOKEN_FILE"
  echo "sandbox-entrypoint: installed Anthropic credentials at ~/.claude/.credentials.json"
fi

# --- 3. Git identity derived from the piped token's account ---------------
# Precedence: GIT_AUTHOR_NAME/EMAIL env override → gh api user (the token's
# actual GitHub account, so a fork "just works") → fallback strings.
LOGIN=""; LOGIN_ID=""
if gh auth status >/dev/null 2>&1; then
  LOGIN=$(gh api user --jq .login 2>/dev/null || true)
  LOGIN_ID=$(gh api user --jq .id 2>/dev/null || true)
fi
NAME="${GIT_AUTHOR_NAME:-${LOGIN:-user}}"
if [[ -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
  EMAIL="$GIT_AUTHOR_EMAIL"
elif [[ -n "$LOGIN" && -n "$LOGIN_ID" ]]; then
  # GitHub's privacy-friendly noreply format: <id>+<login>@users.noreply.github.com
  EMAIL="${LOGIN_ID}+${LOGIN}@users.noreply.github.com"
else
  EMAIL="${NAME}@users.noreply.github.com"
fi
git config --global user.name  "$NAME"
git config --global user.email "$EMAIL"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global tag.gpgSign false
# HTTPS-only — refuse SSH remotes that could tunnel host SSH keys.
# `insteadOf` is multi-value: `--add` appends, plain `set` overwrites the
# prior value (the bug caught by tests/run.sh #5 — only the last write
# survived, so `git@github.com:` URLs weren't being rewritten).
git config --global --replace-all url."https://github.com/".insteadOf "git@github.com:"
git config --global --add         url."https://github.com/".insteadOf "ssh://git@github.com/"

# --- 4. Warn if token expiry parseable and <24h -----------------------------
# `gh auth token` has no TTL API. The closest signal is the
# `github-authentication-token-expiration` response header, only sent for
# fine-grained PATs and gh-issued OAuth tokens.
if gh auth status >/dev/null 2>&1; then
  expiry=$(gh api -i user 2>/dev/null \
            | awk -F': ' 'tolower($1)=="github-authentication-token-expiration"{print $2}' \
            | tr -d '\r' || true)
  if [[ -n "$expiry" ]]; then
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || true)
    now=$(date +%s)
    if [[ -n "$expiry_epoch" && $((expiry_epoch - now)) -lt 86400 ]]; then
      echo "sandbox-entrypoint: WARN — gh token expires within 24h ($expiry)" >&2
    fi
  fi
fi

# --- 5. Snapshot state for autosave diff -----------------------------------
SNAP_DIR="/workspace/home/.sandbox/snapshot-entry"
mkdir -p "$SNAP_DIR"
dpkg --get-selections 2>/dev/null | sort > "$SNAP_DIR/dpkg.txt" || true
pip3 freeze 2>/dev/null | sort > "$SNAP_DIR/pip.txt" || true
{ command -v npm >/dev/null && npm ls -g --depth=0 2>/dev/null || true; } > "$SNAP_DIR/npm.txt"
ls -la "$HOME/bin/" 2>/dev/null > "$SNAP_DIR/bin.txt" || true
env | sort > "$SNAP_DIR/env.txt"

# --- 6. Periodic autosave background (5min cadence) ------------------------
( while sleep 300; do
    /usr/local/bin/container-autosave periodic 2>/dev/null || true
  done ) &
PERIODIC_PID=$!

# --- 7. Final autosave on exit ---------------------------------------------
final_autosave() {
  trap '' TERM INT EXIT
  kill "$PERIODIC_PID" 2>/dev/null || true
  /usr/local/bin/container-autosave final 2>/dev/null || true
}
trap final_autosave TERM INT EXIT

# Drop into the user's shell (or whatever CMD specified).
exec "$@"
