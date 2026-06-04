#!/usr/bin/env bash
# Snapshot-diff dumper. Mirrors _worklog/bin/autosave.sh philosophy:
# fail-safe capture, review later, never block exit, never auto-commit.
#
# Mode arg:
#   periodic  — quiet, runs every 5min from entrypoint background loop
#   final     — runs once at container exit (TERM/INT/EXIT trap)
#
# Output: /workspace/inbox/<iso-timestamp>/<mode>/ containing diff files.

set -uo pipefail

MODE="${1:-final}"
SNAP_ENTRY="/workspace/home/.sandbox/snapshot-entry"
INBOX="/workspace/inbox"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$INBOX/$TS/$MODE"

# Inbox might be a fresh bind mount with the wrong perms — fix once if needed.
mkdir -p "$OUT" 2>/dev/null || { sudo mkdir -p "$OUT" && sudo chown -R "$(id -u):$(id -g)" "$INBOX/$TS"; }

snapshot_now() {
  dpkg --get-selections 2>/dev/null | sort
}
diff_or_skip() {
  local before="$1" current="$2" out="$3"
  [[ -s "$before" ]] || return 0
  diff -u "$before" "$current" 2>/dev/null > "$out" || true
  [[ -s "$out" ]] || rm -f "$out"
}

# dpkg delta
current_dpkg="$(mktemp)"
snapshot_now > "$current_dpkg"
diff_or_skip "$SNAP_ENTRY/dpkg.txt" "$current_dpkg" "$OUT/dpkg.diff"
rm -f "$current_dpkg"

# pip delta
current_pip="$(mktemp)"
pip3 freeze 2>/dev/null | sort > "$current_pip"
diff_or_skip "$SNAP_ENTRY/pip.txt" "$current_pip" "$OUT/pip.diff"
rm -f "$current_pip"

# npm -g delta
current_npm="$(mktemp)"
{ command -v npm >/dev/null && npm ls -g --depth=0 2>/dev/null || true; } > "$current_npm"
diff_or_skip "$SNAP_ENTRY/npm.txt" "$current_npm" "$OUT/npm.diff"
rm -f "$current_npm"

# ~/bin delta
current_bin="$(mktemp)"
ls -la "$HOME/bin/" 2>/dev/null > "$current_bin" || true
diff_or_skip "$SNAP_ENTRY/bin.txt" "$current_bin" "$OUT/bin.diff"
rm -f "$current_bin"

# Env delta (filtered — never dump tokens).
# Council item #8: explicit deny-list for secret-shaped env vars. Both
# substring patterns (token/secret/password/auth/key) AND known secret-value
# shapes (AKIA*, AIza*, sk-*, ghp_*, github_pat_*) get stripped.
current_env="$(mktemp)"
env \
  | grep -viE '(token|secret|password|key=|auth|credential|api_key|apikey)' \
  | grep -vE '=AKIA[0-9A-Z]{16}' \
  | grep -vE '=AIza[0-9A-Za-z_-]{35}' \
  | grep -vE '=sk-[A-Za-z0-9_-]{20,}' \
  | grep -vE '=ghp_[A-Za-z0-9]{20,}' \
  | grep -vE '=github_pat_[A-Za-z0-9_]{20,}' \
  | sort > "$current_env"
diff_or_skip "$SNAP_ENTRY/env.txt" "$current_env" "$OUT/env.diff"
rm -f "$current_env"

# Shell history tail (last 200 lines)
[[ -f "$HOME/.bash_history" ]] && tail -200 "$HOME/.bash_history" > "$OUT/history.txt"

# Notes accumulated via `note <text>` shell alias (defined in entrypoint, if any)
[[ -f "$HOME/.sandbox/notes.md" ]] && cp "$HOME/.sandbox/notes.md" "$OUT/notes.md"

# CWD at autosave time (helps reconstruct what user was working on)
pwd > "$OUT/cwd.txt" 2>/dev/null || true

# If nothing was captured, remove the empty dir so the inbox doesn't fill with noise.
if [[ -z "$(ls -A "$OUT" 2>/dev/null)" ]]; then
  rmdir "$OUT" 2>/dev/null || true
  rmdir "$INBOX/$TS" 2>/dev/null || true
fi

# Quiet for periodic, verbose for final.
if [[ "$MODE" == "final" ]]; then
  if [[ -d "$OUT" ]]; then
    echo "container-autosave: dumped to $OUT" >&2
  else
    echo "container-autosave: no deltas this session." >&2
  fi
fi
exit 0
