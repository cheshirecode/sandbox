#!/usr/bin/env bash
# sandbox — host-side wrapper around an ephemeral identity-isolated dev container.
# Auto-detects your GitHub login (via `gh api user`) and ties named volumes,
# image tag, and container name to it — so this script works as-is on any fork.
#
# Subcommands: see `bin/sandbox.sh --help`.
#
# Token piping: reads `gh auth token` from the .envrc-loaded host environment
# and writes it into the container's tmpfs /run/secrets/gh_token via
# `docker exec -i sh -c 'cat > …'`. Never via -e / --build-arg / docker cp.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Profile selection: --profile=<name> flag (in argv anywhere) OR
# $SANDBOX_PROFILE env. Profile files live at:
#   ~/.config/sandbox/profiles/<name>.env
# Sourced BEFORE mounts.env so the existing ${VAR:-default} pattern honors
# overrides (SANDBOX_LOGIN, SANDBOX_WORKSPACE, SANDBOX_REFUSE_PATTERNS, etc.).
PROFILE_DIR="${SANDBOX_PROFILE_DIR:-$HOME/.config/sandbox/profiles}"
SANDBOX_PROFILE_NAME="${SANDBOX_PROFILE:-}"
# Scan argv for --profile=<name> (allowed anywhere — applies to all subcmds).
_REMAINING_ARGS=()
for _arg in "$@"; do
  case "$_arg" in
    --profile=*) SANDBOX_PROFILE_NAME="${_arg#--profile=}" ;;
    *)           _REMAINING_ARGS+=("$_arg") ;;
  esac
done
set -- ${_REMAINING_ARGS[@]+"${_REMAINING_ARGS[@]}"}
unset _REMAINING_ARGS _arg

if [[ -n "$SANDBOX_PROFILE_NAME" ]]; then
  PROFILE_FILE="$PROFILE_DIR/${SANDBOX_PROFILE_NAME}.env"
  if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "sandbox: profile '$SANDBOX_PROFILE_NAME' not found at $PROFILE_FILE" >&2
    echo "  list profiles: bin/sandbox.sh profile-list" >&2
    echo "  create:        bin/sandbox.sh profile-new $SANDBOX_PROFILE_NAME" >&2
    exit 78
  fi
  # shellcheck disable=SC1090
  source "$PROFILE_FILE"
fi

# shellcheck source=../mounts.env
source "$REPO_ROOT/mounts.env"

# --- Host preflight --------------------------------------------------------
ensure_runtime_dirs() {
  mkdir -p "$SANDBOX_HOME_DIR" "$SANDBOX_INBOX_DIR"
}

wait_for_entrypoint_ready() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
           21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    if docker exec "$CONTAINER_NAME" test -f /workspace/home/.sandbox/entrypoint-ready >/dev/null 2>&1; then
      return 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
      echo "sandbox: entrypoint exited before ready" >&2
      docker logs "$CONTAINER_NAME" >&2 || true
      return 1
    fi
    sleep 0.25
  done
  echo "sandbox: timed out waiting for entrypoint readiness" >&2
  docker logs "$CONTAINER_NAME" >&2 || true
  return 1
}

detect_docker_host() {
  if command -v orb >/dev/null 2>&1; then
    echo "orbstack"
  elif docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi 'orbstack'; then
    echo "orbstack"
  elif docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi 'docker desktop'; then
    echo "docker-desktop"
  else
    echo "unknown"
  fi
}

require_token() {
  if ! command -v gh >/dev/null; then
    echo "sandbox: gh CLI not installed on host. brew install gh" >&2
    exit 1
  fi
  if ! token=$(gh auth token 2>/dev/null) || [[ -z "$token" ]]; then
    echo "sandbox: no host gh token. Run \`gh auth login\` first." >&2
    exit 1
  fi
  # NEVER echo the token. Caller consumes via $token in the same shell.
  printf '%s' "$token"
}

# Probe host for Anthropic OAuth credentials. Returns JSON blob on stdout
# (the same shape Claude Code expects in ~/.claude/.credentials.json) and
# exit 0 if found; exit 1 silently if not (provider skip is graceful).
# Probe order: on-disk credentials file → macOS keychain. Linux/WSL2 has
# no equivalent path today (v1.x scope: macOS-only Anthropic auto-pipe).
probe_anthropic_credentials() {
  local cred_file="$HOME/.claude/.credentials.json"
  if [[ -s "$cred_file" ]]; then
    cat "$cred_file"
    return 0
  fi
  if [[ "$(uname -s)" == "Darwin" ]] && command -v security >/dev/null; then
    local kc
    kc=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
    if [[ -n "$kc" ]]; then
      printf '%s' "$kc"
      return 0
    fi
  fi
  return 1
}

# Probe host for OpenAI Codex credentials. Same shape as Anthropic — file
# first, macOS keychain fallback. Returns auth.json blob on stdout, exit 0
# if found; exit 1 silently otherwise (graceful skip).
probe_openai_credentials() {
  local cred_file="$HOME/.codex/auth.json"
  if [[ -s "$cred_file" ]]; then
    cat "$cred_file"
    return 0
  fi
  if [[ "$(uname -s)" == "Darwin" ]] && command -v security >/dev/null; then
    local kc
    kc=$(security find-generic-password -s "Codex Safe Storage" -a "Codex Key" -w 2>/dev/null || true)
    if [[ -n "$kc" ]]; then
      printf '%s' "$kc"
      return 0
    fi
  fi
  return 1
}

# Probe host for OpenRouter credentials (used by Hermes Agent & OpenCode).
# Probes host environment OPEN_ROUTER_API_KEY_HERMES / OPENROUTER_API_KEY first,
# then ~/.hermes/.env, then ~/.local/share/opencode/auth.json, then ~/.hermes/config.json.
probe_openrouter_credentials() {
  if [[ -n "${OPEN_ROUTER_API_KEY_HERMES:-}" ]]; then
    printf '%s' "$OPEN_ROUTER_API_KEY_HERMES"
    return 0
  fi
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    printf '%s' "$OPENROUTER_API_KEY"
    return 0
  fi
  local hermes_env="$HOME/.hermes/.env"
  if [[ -s "$hermes_env" ]]; then
    local key
    key=$(grep -E '^OPENROUTER_API_KEY=' "$hermes_env" 2>/dev/null | cut -d= -f2- | tr -d '\r\n' || true)
    if [[ -n "$key" ]]; then
      printf '%s' "$key"
      return 0
    fi
  fi
  local opencode_auth="$HOME/.local/share/opencode/auth.json"
  if [[ -s "$opencode_auth" ]]; then
    local key
    key=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
        k = d.get("openrouter", {}).get("key")
        if k:
            print(k)
except Exception:
    pass
' "$opencode_auth" 2>/dev/null || true)
    if [[ -n "$key" ]]; then
      printf '%s' "$key"
      return 0
    fi
  fi
  return 1
}

# Probe host for Hermes Agent configuration (~/.hermes/config.json or ~/.hermes/config.yaml).
probe_hermes_credentials() {
  local hermes_config="$HOME/.hermes/config.json"
  if [[ -s "$hermes_config" ]]; then
    cat "$hermes_config"
    return 0
  fi
  return 1
}

# Probe host for Nous Portal credentials.
probe_nous_credentials() {
  if [[ -n "${HERMES_API_KEY_FREE:-}" ]]; then
    printf '%s' "$HERMES_API_KEY_FREE"
    return 0
  fi
  if [[ -n "${NOUS_API_KEY:-}" ]]; then
    printf '%s' "$NOUS_API_KEY"
    return 0
  fi
  if [[ -n "${HERMES_API_KEY:-}" ]]; then
    printf '%s' "$HERMES_API_KEY"
    return 0
  fi
  local hermes_env="$HOME/.hermes/.env"
  if [[ -s "$hermes_env" ]]; then
    local key
    key=$(grep -E '^(NOUS_API_KEY|HERMES_API_KEY)=' "$hermes_env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r\n' || true)
    if [[ -n "$key" ]]; then
      printf '%s' "$key"
      return 0
    fi
  fi
  return 1
}

# --- Subcommand: doctor ----------------------------------------------------
cmd_doctor() {
  echo "sandbox: host preflight"
  command -v docker >/dev/null && echo "  OK   docker $(docker --version)" || { echo "  FAIL docker not on PATH"; exit 1; }
  command -v gh     >/dev/null && echo "  OK   gh $(gh --version | head -1)" || echo "  WARN gh not on PATH"
  command -v direnv >/dev/null && echo "  OK   direnv $(direnv --version)"    || echo "  WARN direnv not on PATH (identity swap won't auto-load)"
  echo "  INFO docker runtime: $(detect_docker_host)"
  if [[ "$(detect_docker_host)" == "docker-desktop" ]]; then
    echo "  TIP  brew install orbstack — 2-3× faster on macOS, free for personal use"
  fi
  echo "  INFO github login:   $SANDBOX_LOGIN"
  echo "  INFO image:          $IMAGE_NAME:$IMAGE_TAG"
  echo "  INFO container name: $CONTAINER_NAME"
  echo "  INFO volumes:        $VOL_TOOLCHAINS, $VOL_GH, $VOL_CLAUDE, $VOL_CODEX, $VOL_HERMES"
  ensure_runtime_dirs
  echo "  OK   workspace      $SANDBOX_WORKSPACE"
  echo "  OK   sandbox \$HOME  $SANDBOX_HOME_DIR"
  echo "  OK   inbox          $SANDBOX_INBOX_DIR"
}

# --- Subcommand: rebuild ---------------------------------------------------
cmd_rebuild() {
  local host_uid host_gid
  host_uid="$(id -u)"; host_gid="$(id -g)"
  docker build \
    --build-arg "HOST_UID=$host_uid" \
    --build-arg "HOST_GID=$host_gid" \
    -t "$IMAGE_NAME:$IMAGE_TAG" \
    "$REPO_ROOT"
}

# --- Subcommand: up --------------------------------------------------------
cmd_up() {
  # --no-attach: bring container up + pipe credentials, but don't open the
  # interactive shell. Returns 0 when container is running and ready.
  # Used by setup-from-scratch.sh and tests that need a scriptable bring-up.
  local no_attach=0
  for arg in "$@"; do
    [[ "$arg" == "--no-attach" ]] && no_attach=1
  done

  ensure_runtime_dirs
  mkdir -p "$SANDBOX_HOME_DIR/.sandbox"
  rm -f "$SANDBOX_HOME_DIR/.sandbox/entrypoint-ready"

  # Image exists?
  if ! docker image inspect "$IMAGE_NAME:$IMAGE_TAG" >/dev/null 2>&1; then
    echo "sandbox: image $IMAGE_NAME:$IMAGE_TAG missing — building"
    cmd_rebuild
  fi

  # Container running already? Just exec into it.
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    if [[ $no_attach -eq 1 ]]; then
      echo "sandbox: container already running, ready for \`bin/sandbox.sh exec\` or \`bin/sandbox.sh run-headless\` (no shell attached)"
      return
    fi
    echo "sandbox: container running — execing into it"
    docker exec -it "$CONTAINER_NAME" bash -l
    return
  fi

  # Container stopped? Remove the husk so we start clean.
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker rm "$CONTAINER_NAME" >/dev/null
  fi

  # Pull a fresh gh token from the host keychain (via .envrc-loaded gh).
  local host_token
  host_token="$(require_token)"

  # Hazard #13: identity-mismatch precondition. If the caller exported
  # $WORKLOG_LDAP (or $SANDBOX_LOGIN) declaring "this sandbox must run as
  # account X", verify the token we're about to pipe ACTUALLY resolves to
  # X. Without this check, running `bin/sandbox.sh up` from a shell that
  # didn't direnv-load ~/Documents/oss/.envrc picks up the host's default
  # gh login (likely a work account) and bakes the wrong identity into the
  # container — repeating hazard #12 (work-identity leak) from inside.
  # Fallback chain: explicit env override → explicit env override →
  # implicit profile declaration. The last fallback only kicks in when a
  # profile was explicitly selected ($SANDBOX_PROFILE_NAME non-empty) —
  # otherwise SANDBOX_LOGIN was auto-detected from `gh api user` on the
  # host and using it as the expected creates a tautology that always
  # passes (defeating the guard). With a profile selected, SANDBOX_LOGIN
  # is a deliberate declaration ("this profile runs as <login>"), so we
  # can enforce it automatically without the operator remembering to set
  # WORKLOG_LDAP. This is what catches the migration-era regression where
  # `bin/sandbox.sh --profile=cheshirecode up` from a non-direnv shell
  # silently baked the host's work identity into the container.
  local expected_login=""
  if [[ -n "${WORKLOG_LDAP:-}" ]]; then
    expected_login="$WORKLOG_LDAP"
  elif [[ -n "${SANDBOX_LOGIN_EXPECTED:-}" ]]; then
    expected_login="$SANDBOX_LOGIN_EXPECTED"
  elif [[ -n "${SANDBOX_PROFILE_NAME:-}" && -n "${SANDBOX_LOGIN:-}" ]]; then
    expected_login="$SANDBOX_LOGIN"
  fi
  if [[ -n "$expected_login" ]]; then
    local actual_login
    actual_login="$(GH_TOKEN="$host_token" gh api user --jq .login 2>/dev/null || echo '<probe-failed>')"
    if [[ "$actual_login" != "$expected_login" ]]; then
      echo "sandbox: REFUSING TO START — identity mismatch" >&2
      echo "  expected (env): $expected_login" >&2
      echo "  host gh token resolves to: $actual_login" >&2
      echo "" >&2
      echo "  This means \`gh auth token\` on host returned a token for a different" >&2
      echo "  account than the one this sandbox is scoped to. Common cause: the" >&2
      echo "  shell that ran \`bin/sandbox.sh up\` didn't load ~/Documents/oss/.envrc," >&2
      echo "  so direnv didn't swap GH_TOKEN to the cheshirecode-scoped value." >&2
      echo "" >&2
      echo "  Fix:    source ~/Documents/oss/.envrc && bin/sandbox.sh up [--no-attach]" >&2
      echo "          (or: direnv exec ~/Documents/oss bin/sandbox.sh up ...)" >&2
      echo "  Bypass: unset whichever is set: WORKLOG_LDAP, SANDBOX_LOGIN_EXPECTED," >&2
      echo "          or run without --profile=/SANDBOX_PROFILE (only if you" >&2
      echo "          genuinely want a different identity)." >&2
      unset host_token
      exit 78  # EX_CONFIG
    fi
  fi

  # Build env-var allowlist args inline (bash-3.2-safe; mapfile is bash 4+).
  local env_args=()
  for var in "${SANDBOX_ENV_ALLOWLIST[@]}"; do
    if [[ -n "${!var:-}" ]]; then
      env_args+=(--env "$var=${!var}")
    fi
  done

  # Run detached, then pipe tokens via stdin (no host temp file, no
  # docker-cp-runs-as-root-then-dev-chmod-fails race).
  # shellcheck disable=SC2068 # intentional array expansion
  docker run -d \
    --name "$CONTAINER_NAME" \
    ${SANDBOX_MOUNTS[@]} \
    ${SANDBOX_RUNFLAGS[@]} \
    --env SANDBOX_WAIT_FOR_SECRETS=1 \
    ${env_args[@]+"${env_args[@]}"} \
    "$IMAGE_NAME:$IMAGE_TAG" \
    sleep infinity >/dev/null

  # GH token via stdin (same pattern as Anthropic + Codex below).
  printf '%s' "$host_token" | docker exec -i "$CONTAINER_NAME" sh -c \
    'cat > /run/secrets/gh_token && chmod 0400 /run/secrets/gh_token'
  unset host_token

  # Optional: auto-pipe Anthropic OAuth credentials if the host has them.
  # Graceful skip if absent — sandbox still works without Claude Code auth.
  # Stdin pipe (no host temp file) avoids the docker-cp-to-tmpfs race
  # exposed earlier in tests/run.sh.
  if anthropic_json="$(probe_anthropic_credentials)"; then
    printf '%s' "$anthropic_json" | docker exec -i "$CONTAINER_NAME" sh -c \
      'cat > /run/secrets/anthropic_token && chmod 0400 /run/secrets/anthropic_token'
    unset anthropic_json
    echo "sandbox: piped Anthropic OAuth credentials (Claude Code will inherit your session)"
  else
    echo "sandbox: no Anthropic credentials on host — Claude Code will need manual login if used"
  fi

  # Same pattern for OpenAI Codex (gracefully skipped if host has no codex login).
  if openai_json="$(probe_openai_credentials)"; then
    printf '%s' "$openai_json" | docker exec -i "$CONTAINER_NAME" sh -c \
      'cat > /run/secrets/openai_token && chmod 0400 /run/secrets/openai_token'
    unset openai_json
    echo "sandbox: piped OpenAI Codex credentials (codex CLI will inherit your session)"
  else
    echo "sandbox: no Codex credentials on host — codex CLI will need manual login if used"
  fi

  # Auto-pipe OpenRouter credentials for Hermes Agent & OpenCode
  if openrouter_key="$(probe_openrouter_credentials)"; then
    printf '%s' "$openrouter_key" | docker exec -i "$CONTAINER_NAME" sh -c \
      'cat > /run/secrets/openrouter_token && chmod 0400 /run/secrets/openrouter_token'
    unset openrouter_key
    echo "sandbox: piped OpenRouter credentials (Hermes Agent will inherit your API session)"
  fi

  # Auto-pipe existing Hermes Agent configuration if present
  if hermes_json="$(probe_hermes_credentials)"; then
    printf '%s' "$hermes_json" | docker exec -i "$CONTAINER_NAME" sh -c \
      'cat > /run/secrets/hermes_token && chmod 0400 /run/secrets/hermes_token'
    unset hermes_json
    echo "sandbox: piped Hermes Agent configuration (~/.hermes/config.json)"
  fi

  # Auto-pipe Nous Portal credentials if present
  if nous_key="$(probe_nous_credentials)"; then
    printf '%s' "$nous_key" | docker exec -i "$CONTAINER_NAME" sh -c \
      'cat > /run/secrets/nous_token && chmod 0400 /run/secrets/nous_token'
    unset nous_key
    echo "sandbox: piped Nous Portal credentials"
  fi

  if [[ $no_attach -eq 1 ]]; then
    wait_for_entrypoint_ready
    echo "sandbox: container running, ready for \`bin/sandbox.sh exec\` or \`bin/sandbox.sh run-headless\` (no shell attached)"
    return
  fi

  wait_for_entrypoint_ready
  docker exec -it "$CONTAINER_NAME" bash -l
}

# --- Subcommand: exec ------------------------------------------------------
cmd_exec() {
  docker exec -it "$CONTAINER_NAME" "$@"
}

# --- Subcommand: run-headless ---------------------------------------------
# Non-interactive command runner for daemon/agent callers. Unlike `exec`,
# this never allocates a TTY and always leaves inspectable host-side artifacts.
cmd_run_headless() {
  if [[ $# -eq 0 ]]; then
    echo "usage: bin/sandbox.sh run-headless <cmd> [args...]" >&2
    return 2
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "sandbox run-headless: container not running. Run \`bin/sandbox.sh up --no-attach\` first." >&2
    return 2
  fi

  ensure_runtime_dirs

  local run_id run_dir start_iso end_iso rc
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  run_dir="$SANDBOX_INBOX_DIR/headless-runs/$run_id"
  mkdir -p "$run_dir"
  chmod 0700 "$run_dir" 2>/dev/null || true

  start_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%q ' "$@" > "$run_dir/command.txt"
  printf '\n' >> "$run_dir/command.txt"
  {
    printf 'run_id=%s\n' "$run_id"
    printf 'start=%s\n' "$start_iso"
    printf 'profile=%s\n' "${SANDBOX_PROFILE_NAME:-}"
    printf 'login=%s\n' "$SANDBOX_LOGIN"
    printf 'container=%s\n' "$CONTAINER_NAME"
    printf 'workspace=%s\n' "$SANDBOX_WORKSPACE"
    printf 'sandbox_home=%s\n' "$SANDBOX_HOME_DIR"
  } > "$run_dir/meta.env"

  set +e
  docker exec "$CONTAINER_NAME" "$@" >"$run_dir/stdout.log" 2>"$run_dir/stderr.log"
  rc=$?
  set -e

  end_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "$rc" > "$run_dir/exit_code"
  {
    printf 'end=%s\n' "$end_iso"
    printf 'exit_code=%s\n' "$rc"
  } >> "$run_dir/meta.env"

  echo "sandbox run-headless: exit=$rc artifacts=$run_dir"
  return "$rc"
}

# --- Subcommand: down ------------------------------------------------------
cmd_down() {
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "sandbox: stopping (autosave will fire — up to 60s grace)"
    docker stop --time=60 "$CONTAINER_NAME" >/dev/null
  fi
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "sandbox: stopped. Named volumes ($VOL_TOOLCHAINS, $VOL_GH, $VOL_CLAUDE, $VOL_CODEX, $VOL_HERMES) preserved."
}

# --- Subcommand: hermes ---------------------------------------------------
# Quick launcher for Hermes Agent interactive TUI inside the sandbox.
# Auto-starts the container in background if not already running.
cmd_hermes() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "sandbox hermes: starting sandbox container"
    cmd_up --no-attach
  fi
  docker exec -it "$CONTAINER_NAME" hermes "$@"
}

# --- Subcommand: gateway --------------------------------------------------
# Quick launcher for Hermes Agent messaging gateway (Telegram, Discord, Slack, etc.)
cmd_gateway() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "sandbox gateway: starting sandbox container"
    cmd_up --no-attach
  fi
  docker exec -it "$CONTAINER_NAME" hermes gateway "$@"
}

# --- Subcommand: verify-llm-auth ------------------------------------------
# Real-token, host-side functional check. Runs INSIDE the live container and
# asks each LLM CLI whether its piped credential actually authenticates.
#
# Exit non-zero only if ALL detected providers fail. Per-provider missing is
# treated as "not exercised, not failed" — the provider may not be installed
# inside the container yet.
cmd_verify_llm_auth() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "sandbox: container not running. Run \`bin/sandbox.sh up\` first." >&2
    return 2
  fi
  local any_verified=0 any_failed=0

  echo "sandbox verify-llm-auth: checking in-container auth for installed providers"

  # Hermes Agent
  if docker exec "$CONTAINER_NAME" command -v hermes >/dev/null 2>&1; then
    if docker exec "$CONTAINER_NAME" test -f /workspace/home/.hermes/config.json \
        || docker exec "$CONTAINER_NAME" test -f /workspace/home/.hermes/.env; then
      echo "  OK   hermes — Hermes Agent configured with credentials in ~/.hermes/"
      any_verified=1
    else
      echo "  WARN hermes — hermes CLI present, but ~/.hermes/config.json not yet initialized"
    fi
  else
    echo "  SKIP hermes — hermes CLI not installed in container"
  fi

  # Claude Code
  if docker exec "$CONTAINER_NAME" command -v claude >/dev/null 2>&1; then
    if docker exec "$CONTAINER_NAME" claude --version >/dev/null 2>&1 \
        && docker exec "$CONTAINER_NAME" bash -lc 'claude auth status 2>&1 | grep -qiE "(authenticated|logged in|active)"'; then
      echo "  OK   anthropic — claude auth verified inside container"
      any_verified=1
    else
      echo "  FAIL anthropic — claude installed but auth status did not confirm"
      any_failed=1
    fi
  else
    echo "  SKIP anthropic — claude CLI not installed in container"
  fi

  # Codex
  if docker exec "$CONTAINER_NAME" command -v codex >/dev/null 2>&1; then
    if docker exec "$CONTAINER_NAME" bash -lc 'codex login status 2>&1 | grep -qiE "(logged in|authenticated|active)"'; then
      echo "  OK   openai-codex — codex login verified inside container"
      any_verified=1
    else
      echo "  FAIL openai-codex — codex installed but auth status did not confirm"
      any_failed=1
    fi
  else
    echo "  SKIP openai-codex — codex CLI not installed in container"
  fi

  if [[ $any_verified -eq 0 && $any_failed -eq 0 ]]; then
    echo "sandbox: no LLM CLIs installed in container — nothing to verify"
    return 0
  fi
  if [[ $any_failed -ne 0 ]]; then
    echo "sandbox: ONE OR MORE providers FAILED verification (above)" >&2
    return 1
  fi
  echo "sandbox: all installed LLM CLIs verified"
}

# --- Subcommand: test-repo ------------------------------------------------
# Clone a $SANDBOX_LOGIN/* repo + install + run its tests inside the running
# sandbox. Exit code = exit code of `npm test`. No output parsing — modern
# runners (vitest/jest/tape/mocha/pytest/cargo test) all exit non-zero on
# failure.
#
# Usage:
#   bin/sandbox.sh test-repo <repo-name>          # $SANDBOX_LOGIN/<repo>
#   bin/sandbox.sh test-repo <owner>/<repo>       # explicit owner
cmd_test_repo() {
  local arg="${1:-}"
  [[ -z "$arg" ]] && { echo "sandbox test-repo: missing <repo-name>" >&2; return 2; }

  # Normalize: if no `/`, prepend the active profile's login.
  local full_repo
  if [[ "$arg" == */* ]]; then full_repo="$arg"; else full_repo="$SANDBOX_LOGIN/$arg"; fi
  local repo_name="${full_repo##*/}"
  local target="/workspace/oss/$repo_name"

  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "sandbox test-repo: container not running. Run \`bin/sandbox.sh up\` first." >&2
    return 2
  fi

  echo "sandbox test-repo: $full_repo → $target"
  docker exec "$CONTAINER_NAME" bash -lc "
    set -e
    rm -rf '$target' 2>/dev/null || true
    cd /workspace/oss
    gh repo clone '$full_repo' 2>&1 | tail -2
    cd '$target'
    [[ -f package.json ]]   && npm install 2>&1 | tail -1
    [[ -f Cargo.toml ]]     && cargo fetch 2>&1 | tail -1 || true
    [[ -f requirements.txt ]] && pip3 install -q -r requirements.txt 2>&1 | tail -1 || true
    npm test
  "
}

# --- Subcommand: nuke -----------------------------------------------------
# Tear EVERYTHING down. For reproducibility testing — clears all persistent
# state so the next `bin/sandbox.sh up` is a true fresh-machine simulation.
# By default keeps the host runtime dirs (.sandbox-home, learnings-inbox);
# pass --all to delete those too.
cmd_nuke() {
  local nuke_runtime=0
  for arg in "$@"; do
    case "$arg" in
      --all) nuke_runtime=1 ;;
      *) echo "sandbox nuke: unknown flag $arg" >&2; return 2 ;;
    esac
  done

  echo "sandbox nuke: removing container, image, named volumes"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker image rm "$IMAGE_NAME:$IMAGE_TAG" >/dev/null 2>&1 || true
  for v in "$VOL_TOOLCHAINS" "$VOL_GH" "$VOL_CLAUDE" "$VOL_CODEX" "$VOL_HERMES"; do
    docker volume rm "$v" >/dev/null 2>&1 && echo "  removed volume $v" || true
  done

  if [[ $nuke_runtime -eq 1 ]]; then
    echo "sandbox nuke: --all → also removing host runtime dirs"
    rm -rf "$SANDBOX_HOME_DIR" "$SANDBOX_INBOX_DIR"
  fi

  echo "sandbox nuke: state cleared. Next \`bin/sandbox.sh up\` is a fresh start."
}

# --- Subcommand: list -----------------------------------------------------
# Show every sandbox-shaped resource on this host across ALL profiles.
# A "sandbox profile" is identified by the convention <login>-{toolchains,
# gh,claude,codex} named volume set + <login>-sandbox container name +
# <login>/sandbox:v* image. Detects orphans (volumes without a container,
# images without a referencing container) and surfaces them per profile.
cmd_list() {
  # Discover candidate logins by scanning volume names for the toolchains
  # suffix — that's the most-likely-present volume in any working profile.
  local logins
  logins=$(docker volume ls --format '{{.Name}}' 2>/dev/null \
    | awk -F'-toolchains' '/-toolchains$/ {print $1}' | sort -u)
  if [[ -z "$logins" ]]; then
    echo "sandbox list: no sandbox profiles detected on this host."
    return 0
  fi
  printf '%-22s %-12s %-10s %-10s %-10s %-10s\n' PROFILE CONTAINER VOL_GH VOL_CLAUDE VOL_CODEX VOL_HERMES
  printf '%-22s %-12s %-10s %-10s %-10s %-10s\n' ------- --------- ------ ---------- --------- ----------
  while IFS= read -r login; do
    [[ -z "$login" ]] && continue
    local cn="$login-sandbox"
    local cstate
    cstate=$(docker ps -a --filter "name=^${cn}$" --format '{{.Status}}' 2>/dev/null | head -1)
    [[ -z "$cstate" ]] && cstate="(none)"
    local vgh vclaude vcodex vhermes
    vgh=$(docker volume ls --format '{{.Name}}' | grep -qx "$login-gh" && echo "ok" || echo "-")
    vclaude=$(docker volume ls --format '{{.Name}}' | grep -qx "$login-claude" && echo "ok" || echo "-")
    vcodex=$(docker volume ls --format '{{.Name}}' | grep -qx "$login-codex" && echo "ok" || echo "-")
    vhermes=$(docker volume ls --format '{{.Name}}' | grep -qx "$login-hermes" && echo "ok" || echo "-")
    printf '%-22s %-12s %-10s %-10s %-10s %-10s\n' "$login" "${cstate:0:11}" "$vgh" "$vclaude" "$vcodex" "$vhermes"
  done <<< "$logins"
  echo
  echo "Profiles detected by their <login>-toolchains volume."
  echo "Active profile (from mounts.env): $SANDBOX_LOGIN"
}

# --- Subcommand: prune ----------------------------------------------------
# Sweep stale sandbox resources. Dry-run by default; --apply to remove.
# Identifies:
#   1. Containers named <login>-sandbox in Exited/Created state (any age).
#   2. Volumes <login>-{toolchains,gh,claude,codex} not used by any container.
#   3. Images <login>/sandbox:v* not used by any container.
# With --hard: also list dangling images and stopped non-sandbox containers
# (caller must explicitly confirm — these are non-sandbox resources).
cmd_prune() {
  local apply=0 hard=0
  for arg in "$@"; do
    case "$arg" in
      --apply) apply=1 ;;
      --hard)  hard=1 ;;
      *) echo "sandbox prune: unknown flag $arg" >&2; return 2 ;;
    esac
  done

  local mode="DRY-RUN"
  (( apply )) && mode="APPLY"
  echo "sandbox prune [$mode]:"

  # 1. Non-running sandbox containers
  local stale_ctrs
  stale_ctrs=$(docker ps -a --format '{{.Names}}\t{{.Status}}' \
    | awk -F'\t' '$1 ~ /-sandbox$/ && $2 !~ /^Up/ {print $1}')
  if [[ -n "$stale_ctrs" ]]; then
    echo "  stopped sandbox containers:"
    while IFS= read -r c; do
      echo "    - $c"
      (( apply )) && docker rm "$c" >/dev/null 2>&1 && echo "      removed"
    done <<< "$stale_ctrs"
  fi

  # 2. Orphan sandbox volumes (no container references them)
  local stale_vols
  stale_vols=$(docker volume ls --format '{{.Name}}' \
    | grep -E -- '-(toolchains|gh|claude|codex|hermes)$' || true)
  if [[ -n "$stale_vols" ]]; then
    while IFS= read -r v; do
      [[ -z "$v" ]] && continue
      local users
      users=$(docker ps -a --filter "volume=$v" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
      if [[ -z "$users" ]]; then
        echo "  orphan volume: $v"
        (( apply )) && docker volume rm "$v" >/dev/null 2>&1 && echo "    removed"
      fi
    done <<< "$stale_vols"
  fi

  # 3. Unused sandbox images
  local sandbox_imgs
  sandbox_imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '/sandbox:' || true)
  if [[ -n "$sandbox_imgs" ]]; then
    while IFS= read -r img; do
      [[ -z "$img" ]] && continue
      local users
      users=$(docker ps -a --filter "ancestor=$img" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
      if [[ -z "$users" ]]; then
        echo "  unused image: $img"
        (( apply )) && docker image rm "$img" >/dev/null 2>&1 && echo "    removed"
      fi
    done <<< "$sandbox_imgs"
  fi

  # 4. --hard: surface (but never auto-remove) non-sandbox docker hoard.
  if (( hard )); then
    echo
    echo "  --hard surface (non-sandbox; manual decision):"
    local other_stopped
    other_stopped=$(docker ps -a --format '{{.Names}}\t{{.Status}}' \
      | awk -F'\t' '$1 !~ /-sandbox$/ && $2 ~ /^(Exited|Created)/ {print "    "$1" ("$2")"}')
    if [[ -n "$other_stopped" ]]; then
      echo "  non-sandbox stopped containers (count: $(echo "$other_stopped" | wc -l | tr -d ' ')):"
      echo "$other_stopped" | head -10
      echo "    Remove with: docker container prune -f"
    fi
    local dangling
    dangling=$(docker images -f 'dangling=true' --format '{{.ID}}' | wc -l | tr -d ' ')
    if (( dangling > 0 )); then
      echo "  dangling images: $dangling. Remove with: docker image prune -f"
    fi
    local bx
    bx=$(docker ps --format '{{.Names}}' | grep -E '^buildx_buildkit' | wc -l | tr -d ' ')
    if (( bx > 0 )); then
      echo "  buildkit instances running: $bx (used by docker buildx; leave unless rebuilding)"
    fi
  fi

  if (( ! apply )); then
    echo
    echo "Dry-run only. Re-run with --apply to remove."
    echo "Add --hard to surface (not remove) non-sandbox hoard."
  fi
}

# --- Subcommand: inspect --------------------------------------------------
# Detailed state of a single profile (default = active SANDBOX_LOGIN).
cmd_inspect() {
  local login="${1:-$SANDBOX_LOGIN}"
  local cn="$login-sandbox"
  local img="$login/sandbox:v1"
  echo "sandbox inspect [$login]:"
  echo "  container: $cn"
  docker ps -a --filter "name=^${cn}$" --format '    state: {{.Status}}\n    image: {{.Image}}\n    id:    {{.ID}}' || echo "    (none)"
  echo "  image:     $img"
  docker images --filter "reference=$img" --format '    size:  {{.Size}}\n    id:    {{.ID}}\n    created: {{.CreatedSince}}' || echo "    (none)"
  echo "  volumes:"
  for v in "$login-toolchains" "$login-gh" "$login-claude" "$login-codex" "$login-hermes"; do
    if docker volume ls --format '{{.Name}}' | grep -qx "$v"; then
      local size
      size=$(docker run --rm -v "$v:/v" alpine du -sh /v 2>/dev/null | awk '{print $1}' || echo '?')
      printf '    %-30s size=%s\n' "$v" "$size"
    else
      printf '    %-30s (absent)\n' "$v"
    fi
  done
  echo "  mount paths (from mounts.env):"
  echo "    SANDBOX_WORKSPACE=$SANDBOX_WORKSPACE"
  echo "    SANDBOX_HOME_DIR=$SANDBOX_HOME_DIR"
  echo "    SANDBOX_INBOX_DIR=$SANDBOX_INBOX_DIR"
}

# --- Subcommand: profile-new ----------------------------------------------
# Scaffold a profile config file at $PROFILE_DIR/<name>.env. Interactive
# defaults pulled from current env if not passed by flag.
cmd_profile_new() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "usage: profile-new <name> [--login=<gh-login>] [--workspace=<path>]" >&2; return 2; }
  shift || true

  local login="" workspace="" refuse_patterns=""
  for arg in "$@"; do
    case "$arg" in
      --login=*)            login="${arg#--login=}" ;;
      --workspace=*)        workspace="${arg#--workspace=}" ;;
      --refuse-patterns=*)  refuse_patterns="${arg#--refuse-patterns=}" ;;
      *) echo "sandbox profile-new: unknown flag $arg" >&2; return 2 ;;
    esac
  done

  mkdir -p "$PROFILE_DIR"
  local out="$PROFILE_DIR/${name}.env"
  if [[ -f "$out" ]]; then
    echo "sandbox profile-new: $out already exists. Edit by hand or delete first." >&2
    return 1
  fi

  {
    printf '# Sandbox profile: %s\n' "$name"
    printf '# Sourced before mounts.env by bin/sandbox.sh when --profile=%s is set.\n' "$name"
    printf '# Anything set here overrides the auto-detected mounts.env defaults.\n\n'
    if [[ -n "$login" ]]; then
      printf 'export SANDBOX_LOGIN=%s\n' "$login"
    else
      printf '# export SANDBOX_LOGIN=<gh-login>      # leave commented to auto-detect from `gh api user`\n'
    fi
    if [[ -n "$workspace" ]]; then
      printf 'export SANDBOX_WORKSPACE=%s\n' "$workspace"
    else
      printf '# export SANDBOX_WORKSPACE=<host-dir>  # default = parent dir of this sandbox repo\n'
    fi
    if [[ -n "$refuse_patterns" ]]; then
      printf 'export SANDBOX_REFUSE_PATTERNS=%s\n' "$refuse_patterns"
    else
      printf '# export SANDBOX_REFUSE_PATTERNS="MYCORP|VENDOR_INTERNAL"  # extra env-var-name patterns the entrypoint refuses\n'
    fi
  } > "$out"
  chmod 0600 "$out"
  echo "sandbox profile-new: wrote $out"
  echo "  use: bin/sandbox.sh up --profile=$name"
}

# --- Subcommand: profile-list ---------------------------------------------
cmd_profile_list() {
  if [[ ! -d "$PROFILE_DIR" ]]; then
    echo "sandbox profile-list: no profile dir at $PROFILE_DIR"
    return 0
  fi
  local count=0
  printf '%-20s %-20s %s\n' NAME LOGIN WORKSPACE
  printf '%-20s %-20s %s\n' ---- ----- ---------
  shopt -s nullglob
  for f in "$PROFILE_DIR"/*.env; do
    local name login workspace
    name="$(basename "$f" .env)"
    login="$(awk -F= '/^export SANDBOX_LOGIN=/ {print $2; exit}' "$f")"
    workspace="$(awk -F= '/^export SANDBOX_WORKSPACE=/ {print $2; exit}' "$f")"
    printf '%-20s %-20s %s\n' "$name" "${login:-<auto>}" "${workspace:-<auto>}"
    count=$((count+1))
  done
  shopt -u nullglob
  echo
  echo "Profile dir: $PROFILE_DIR ($count profile$([[ $count != 1 ]] && echo s))"
  echo "Active (--profile / \$SANDBOX_PROFILE): ${SANDBOX_PROFILE_NAME:-<none — using mounts.env auto-detect>}"
}

# --- Subcommand: profile-delete -------------------------------------------
# Remove the profile config file ONLY — does not touch docker resources.
# Use bin/sandbox.sh nuke --profile=<name> first if you also want the
# container/volumes/image gone.
cmd_profile_delete() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "usage: profile-delete <name>" >&2; return 2; }
  local f="$PROFILE_DIR/${name}.env"
  if [[ ! -f "$f" ]]; then
    echo "sandbox profile-delete: $f does not exist." >&2
    return 1
  fi
  rm -f "$f"
  echo "sandbox profile-delete: removed $f"
  # Warn if docker resources still exist under this login
  local login
  login="$(grep -E '^export SANDBOX_LOGIN=' "$f" 2>/dev/null | awk -F= '{print $2}' || echo "$name")"
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${login}-sandbox"; then
    echo "  NOTE: docker resources for login=$login still exist." >&2
    echo "        Remove with: bin/sandbox.sh nuke --profile=$name   (or:  bin/sandbox.sh prune --apply)" >&2
  fi
}

# --- Dispatch --------------------------------------------------------------
usage() {
  cat <<EOF
sandbox — host-side wrapper around an ephemeral identity-isolated dev container.

Active profile (--profile / \$SANDBOX_PROFILE / mounts.env auto-detect):
  login=$SANDBOX_LOGIN  workspace=$SANDBOX_WORKSPACE

Lifecycle (per-profile; add --profile=<name> to switch):
  bin/sandbox.sh up [--profile=<name>]      build + run + shell
  bin/sandbox.sh hermes [args...]           launch Hermes Agent interactive TUI
  bin/sandbox.sh gateway [args...]          launch Hermes Agent messaging gateway
  bin/sandbox.sh exec <cmd> [--profile=...]  run cmd in running container
  bin/sandbox.sh run-headless <cmd> [...]    non-TTY run with logs/artifacts
  bin/sandbox.sh down [--profile=...]        stop container
  bin/sandbox.sh rebuild [--profile=...]     force rebuild
  bin/sandbox.sh test-repo <name>            clone+install+test in container
  bin/sandbox.sh verify-llm-auth             in-container LLM auth check

Profile CRUD (config files at \$HOME/.config/sandbox/profiles/<name>.env):
  bin/sandbox.sh profile-new <name> [--login=<gh-login>] [--workspace=<dir>]
                                             create a profile config file
  bin/sandbox.sh profile-list                list known profiles
  bin/sandbox.sh profile-delete <name>       remove the profile config file
                                             (use \`prune\` or \`nuke\` for docker state)

Inspection / management (any profile on this host):
  bin/sandbox.sh list             list all sandbox profiles on host
  bin/sandbox.sh inspect [<login>] detail one profile (default: active)
  bin/sandbox.sh doctor           host preconditions + active profile layout

Cleanup:
  bin/sandbox.sh prune            dry-run: stopped containers + orphan
                                  volumes + unused sandbox images
  bin/sandbox.sh prune --apply    actually remove the above
  bin/sandbox.sh prune --hard     also surface (read-only) non-sandbox
                                  hoard — stopped containers, dangling
                                  images, buildkit instances
  bin/sandbox.sh nuke [--all]     full teardown of ACTIVE profile
                                  (--all also removes host runtime dirs)
EOF
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)              cmd_up "$@" ;;
  hermes)          cmd_hermes "$@" ;;
  gateway)         cmd_gateway "$@" ;;
  exec)            cmd_exec "$@" ;;
  run-headless)    cmd_run_headless "$@" ;;
  down)            cmd_down ;;
  list)            cmd_list ;;
  inspect)         cmd_inspect "$@" ;;
  prune)           cmd_prune "$@" ;;
  profile-new)     cmd_profile_new "$@" ;;
  profile-list)    cmd_profile_list ;;
  profile-delete)  cmd_profile_delete "$@" ;;
  rebuild)         cmd_rebuild ;;
  doctor)          cmd_doctor ;;
  verify-llm-auth) cmd_verify_llm_auth ;;
  test-repo)       cmd_test_repo "$@" ;;
  nuke)            cmd_nuke "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "sandbox: unknown subcommand '$cmd'" >&2; usage; exit 2 ;;
esac
