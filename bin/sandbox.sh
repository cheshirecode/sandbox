#!/usr/bin/env bash
# sandbox — host-side wrapper around an ephemeral identity-isolated dev container.
# Auto-detects your GitHub login (via `gh api user`) and ties named volumes,
# image tag, and container name to it — so this script works as-is on any fork.
#
# Subcommands:
#   up         build (if needed) + run + drop into shell
#   exec       run a command in the running container (or start one)
#   down       stop the container (autosave fires)
#   rebuild    force rebuild the image
#   doctor     check host preconditions (docker, orbstack, .envrc)
#
# Inbox curation: just `ls -lt $SANDBOX_INBOX_DIR/` (the path is printed by
# `sandbox.sh doctor`). Use your editor + rm. No bespoke `extract` subcommand.
# Cleanup: `docker image prune` already exists; no bespoke `prune` subcommand.
#
# Detects OrbStack vs Docker Desktop and prefers OrbStack when present.
# Token piping: reads `gh auth token` from the .envrc-loaded host environment
# and writes it into the container's tmpfs /run/secrets/gh_token via docker
# cp from a host-side tmp file that's `shred -u`'d immediately after.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../mounts.env
source "$REPO_ROOT/mounts.env"

# --- Host preflight --------------------------------------------------------
ensure_runtime_dirs() {
  mkdir -p "$SANDBOX_HOME_DIR" "$SANDBOX_INBOX_DIR"
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
  echo "  INFO volumes:        $VOL_TOOLCHAINS, $VOL_GH, $VOL_CLAUDE, $VOL_CODEX"
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

  # Image exists?
  if ! docker image inspect "$IMAGE_NAME:$IMAGE_TAG" >/dev/null 2>&1; then
    echo "sandbox: image $IMAGE_NAME:$IMAGE_TAG missing — building"
    cmd_rebuild
  fi

  # Container running already? Just exec into it.
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
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
  local expected_login=""
  if [[ -n "${WORKLOG_LDAP:-}" ]]; then
    expected_login="$WORKLOG_LDAP"
  elif [[ -n "${SANDBOX_LOGIN_EXPECTED:-}" ]]; then
    expected_login="$SANDBOX_LOGIN_EXPECTED"
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
      echo "  Bypass: unset WORKLOG_LDAP (only if you genuinely want a different identity)" >&2
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

  if [[ $no_attach -eq 1 ]]; then
    # Run entrypoint detached so the credentials are installed + git config
    # set + autosave started, then return — leaving the container alive
    # (sleep infinity) for `bin/sandbox.sh exec` to attach to later.
    docker exec -d "$CONTAINER_NAME" bash -lc '/usr/local/bin/sandbox-entrypoint sleep infinity > /tmp/entrypoint.out 2>&1'
    # Wait briefly for entrypoint to run its setup phase (snapshots, git config).
    sleep 3
    echo "sandbox: container running, ready for \`bin/sandbox.sh exec\` (no shell attached)"
    return
  fi

  # Replace the sleep with the real entrypoint, attached.
  docker exec -it "$CONTAINER_NAME" /usr/local/bin/sandbox-entrypoint bash -l
}

# --- Subcommand: exec ------------------------------------------------------
cmd_exec() {
  docker exec -it "$CONTAINER_NAME" "$@"
}

# --- Subcommand: down ------------------------------------------------------
cmd_down() {
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "sandbox: stopping (autosave will fire — up to 60s grace)"
    docker stop --time=60 "$CONTAINER_NAME" >/dev/null
  fi
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "sandbox: stopped. Named volumes ($VOL_TOOLCHAINS, $VOL_GH, $VOL_CLAUDE, $VOL_CODEX) preserved."
}

# --- Subcommand: verify-llm-auth ------------------------------------------
# Real-token, host-side functional check. Runs INSIDE the live container and
# asks each LLM CLI whether its piped credential actually authenticates.
# Closes assumption #2 from DESIGN.md ("the container can use the OAuth token
# by writing it to ~/.<provider>/<credentials>").
#
# Exit non-zero only if ALL detected providers fail. Per-provider non-error
# but missing is treated as "not exercised, not failed" since the provider
# may simply not be installed inside the container yet.
cmd_verify_llm_auth() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "sandbox: container not running. Run \`bin/sandbox.sh up\` first." >&2
    return 2
  fi
  local any_verified=0 any_failed=0

  echo "sandbox verify-llm-auth: checking in-container auth for installed providers"

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
# n=3-evidenced shortcut: clone a cheshirecode/* repo + install + run its
# tests inside the running sandbox. Exit code = exit code of `npm test`.
# No clever output parsing — modern runners (vitest, jest, tape, mocha,
# pytest, cargo test) all exit non-zero on failure. Just trust the code.
#
# Usage:
#   bin/sandbox.sh test-repo <repo-name>          # cheshirecode/<repo>
#   bin/sandbox.sh test-repo <owner>/<repo>       # explicit owner
cmd_test_repo() {
  local arg="${1:-}"
  [[ -z "$arg" ]] && { echo "sandbox test-repo: missing <repo-name>" >&2; return 2; }

  # Normalize: if no `/`, assume cheshirecode/<repo>
  local full_repo
  if [[ "$arg" == */* ]]; then full_repo="$arg"; else full_repo="cheshirecode/$arg"; fi
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
  for v in "$VOL_TOOLCHAINS" "$VOL_GH" "$VOL_CLAUDE" "$VOL_CODEX"; do
    docker volume rm "$v" >/dev/null 2>&1 && echo "  removed volume $v" || true
  done

  if [[ $nuke_runtime -eq 1 ]]; then
    echo "sandbox nuke: --all → also removing host runtime dirs"
    rm -rf "$SANDBOX_HOME_DIR" "$SANDBOX_INBOX_DIR"
  fi

  echo "sandbox nuke: state cleared. Next \`bin/sandbox.sh up\` is a fresh start."
}

# --- Dispatch --------------------------------------------------------------
usage() {
  cat <<EOF
sandbox — host-side wrapper around an ephemeral identity-isolated dev container.

  bin/sandbox.sh up               build (if needed) + run + drop into shell
  bin/sandbox.sh exec <cmd>       run a command in the running container
  bin/sandbox.sh down             stop the container (autosave fires)
  bin/sandbox.sh rebuild          force rebuild the image
  bin/sandbox.sh doctor           check host preconditions + show detected layout
  bin/sandbox.sh verify-llm-auth  in-container check: do the piped LLM creds
                                  actually authenticate?
  bin/sandbox.sh test-repo <name> clone cheshirecode/<name> (or <owner>/<repo>),
                                  install, run \`npm test\`. Exit code = test
                                  result. n=3-evidenced dogfood shortcut.
  bin/sandbox.sh nuke [--all]     remove container + image + named volumes
                                  (use --all to also remove .sandbox-home and
                                  learnings-inbox runtime dirs)
EOF
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)              cmd_up "$@" ;;
  exec)            cmd_exec "$@" ;;
  down)            cmd_down ;;
  rebuild)         cmd_rebuild ;;
  doctor)          cmd_doctor ;;
  verify-llm-auth) cmd_verify_llm_auth ;;
  test-repo)       cmd_test_repo "$@" ;;
  nuke)            cmd_nuke "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "sandbox: unknown subcommand '$cmd'" >&2; usage; exit 2 ;;
esac
