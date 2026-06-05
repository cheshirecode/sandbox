#!/usr/bin/env bash
# Fresh-machine setup script. Idempotent — safe to re-run.
#
# This is the single entry point a new machine (yours, a fork's owner's,
# or a CI runner) follows to go from "git clone" to "working sandbox."
# Pairs with bin/nuke-state via `sandbox.sh nuke --all`: nuke then re-run
# this script to prove the setup is reproducible from scratch.
#
# Stages:
#   1. Host prereq verification (docker, git; warn on missing optionals).
#   2. Identity probe — confirms which login the sandbox will tie to.
#   3. LLM CLI auth surface report — what credentials the sandbox can pipe.
#   4. Build (if image missing or --rebuild passed).
#   5. Smoke test — `up && exec true && down` to confirm the pipeline works.
#   6. Optional: `verify-llm-auth` for end-to-end credential verification.
#
# Usage:
#   bin/setup-from-scratch.sh                    # full setup
#   bin/setup-from-scratch.sh --rebuild          # force image rebuild
#   bin/setup-from-scratch.sh --verify-creds     # also run verify-llm-auth
#   bin/setup-from-scratch.sh --skip-smoke       # skip the up/exec/down smoke

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=../mounts.env
source mounts.env

DO_REBUILD=0
DO_VERIFY_CREDS=0
SKIP_SMOKE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)      DO_REBUILD=1 ;;
    --verify-creds) DO_VERIFY_CREDS=1 ;;
    --skip-smoke)   SKIP_SMOKE=1 ;;
    -h|--help)      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "setup-from-scratch: unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

step() { printf "\n=== %s ===\n" "$1"; }
ok()   { printf "  OK   %s\n" "$1"; }
warn() { printf "  WARN %s\n" "$1"; }
fail() { printf "  FAIL %s\n" "$1" >&2; exit 1; }

# --- 1. Host prereqs ------------------------------------------------------
step "1/6  Host prereqs"
for tool in docker git; do
  command -v "$tool" >/dev/null && ok "$tool ($($tool --version 2>&1 | head -1))" || fail "$tool not on PATH"
done
docker info >/dev/null 2>&1 && ok "docker daemon reachable" || fail "docker daemon not reachable — start Docker Desktop / OrbStack"
for opt in gh direnv claude codex cursor-agent; do
  command -v "$opt" >/dev/null && ok "$opt present" || warn "$opt missing (optional — affects which providers can auto-pipe)"
done

# --- 2. Identity probe ----------------------------------------------------
step "2/6  Identity (sandbox will tie to this login)"
ok "SANDBOX_LOGIN = $SANDBOX_LOGIN"
ok "SANDBOX_WORKSPACE = $SANDBOX_WORKSPACE"
ok "image will be $IMAGE_NAME:$IMAGE_TAG"
ok "container will be $CONTAINER_NAME"
ok "named volumes will be $VOL_TOOLCHAINS, $VOL_GH, $VOL_CLAUDE, $VOL_CODEX"

# --- 3. LLM CLI auth surface ----------------------------------------------
step "3/6  LLM CLI credential probe (read-only; values not displayed)"
if [[ -s "$HOME/.claude/.credentials.json" ]] \
   || ([[ "$(uname -s)" == "Darwin" ]] \
       && security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1); then
  ok "Anthropic (Claude Code) credentials detected — will auto-pipe"
else
  warn "Anthropic credentials NOT detected — Claude Code in sandbox needs manual login"
fi
if [[ -s "$HOME/.codex/auth.json" ]] \
   || ([[ "$(uname -s)" == "Darwin" ]] \
       && security find-generic-password -s "Codex Safe Storage" -a "Codex Key" >/dev/null 2>&1); then
  ok "OpenAI Codex credentials detected — will auto-pipe"
else
  warn "Codex credentials NOT detected — codex CLI in sandbox needs manual login"
fi

# --- 4. Image build (if needed) -------------------------------------------
step "4/6  Image"
if [[ $DO_REBUILD -eq 1 ]] || ! docker image inspect "$IMAGE_NAME:$IMAGE_TAG" >/dev/null 2>&1; then
  ok "building $IMAGE_NAME:$IMAGE_TAG"
  bin/sandbox.sh rebuild
else
  ok "image $IMAGE_NAME:$IMAGE_TAG present (use --rebuild to force)"
fi

# --- 5. Smoke test --------------------------------------------------------
if [[ $SKIP_SMOKE -eq 1 ]]; then
  step "5/6  Smoke test SKIPPED (--skip-smoke)"
else
  step "5/6  Smoke test (up --no-attach → exec true → down)"
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    ok "container already running"
  else
    bin/sandbox.sh up --no-attach >/dev/null
    ok "container started (non-attached)"
  fi
  if docker exec "$CONTAINER_NAME" true; then
    ok "container exec works"
  else
    fail "container not exec-able after up"
  fi
  bin/sandbox.sh down >/dev/null
  ok "down complete"
fi

# --- 6. Optional: verify in-container auth --------------------------------
if [[ $DO_VERIFY_CREDS -eq 1 ]]; then
  step "6/6  verify-llm-auth (real-token in-container check)"
  bin/sandbox.sh up --no-attach >/dev/null
  bin/sandbox.sh verify-llm-auth || warn "one or more providers failed verification (see above)"
  bin/sandbox.sh down >/dev/null
else
  step "6/6  verify-llm-auth skipped (pass --verify-creds to enable)"
fi

step "setup-from-scratch: done"
echo "Next: \`bin/sandbox.sh up\` for an interactive session."
echo "To prove this is reproducible from scratch: \`bin/sandbox.sh nuke --all && bin/setup-from-scratch.sh\`."
