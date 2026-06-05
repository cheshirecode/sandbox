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

build_env_args() {
  local args=()
  for var in "${SANDBOX_ENV_ALLOWLIST[@]}"; do
    if [[ -n "${!var:-}" ]]; then
      args+=(--env "$var=${!var}")
    fi
  done
  printf '%s\n' "${args[@]}"
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
  echo "  INFO volumes:        $VOL_TOOLCHAINS, $VOL_GH"
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

  # Pull a fresh token from the host keychain (via .envrc-loaded gh).
  # Token lives in a private tmp file (mode 0600) only long enough for
  # docker cp to land it on the container's tmpfs; immediately shredded.
  local token_tmp host_token
  host_token="$(require_token)"
  token_tmp="$(mktemp -t sandbox-token.XXXXXX)"
  chmod 600 "$token_tmp"
  trap 'shred -u "$token_tmp" 2>/dev/null || rm -f "$token_tmp"' EXIT

  printf '%s' "$host_token" > "$token_tmp"
  unset host_token

  # Build env-var allowlist args.
  mapfile -t env_args < <(build_env_args)

  # Run detached so we can docker cp the token, THEN attach.
  # shellcheck disable=SC2068 # intentional array expansion
  docker run -d \
    --name "$CONTAINER_NAME" \
    ${SANDBOX_MOUNTS[@]} \
    ${SANDBOX_RUNFLAGS[@]} \
    ${env_args[@]+"${env_args[@]}"} \
    "$IMAGE_NAME:$IMAGE_TAG" \
    sleep infinity >/dev/null

  # Land the token on the container's tmpfs at /run/secrets/gh_token.
  docker cp "$token_tmp" "$CONTAINER_NAME:/run/secrets/gh_token"
  docker exec "$CONTAINER_NAME" chmod 0400 /run/secrets/gh_token

  shred -u "$token_tmp" 2>/dev/null || rm -f "$token_tmp"
  trap - EXIT

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
  echo "sandbox: stopped. Volumes (toolchains, gh) preserved."
}

# --- Dispatch --------------------------------------------------------------
usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)       cmd_up "$@" ;;
  exec)     cmd_exec "$@" ;;
  down)     cmd_down ;;
  rebuild)  cmd_rebuild ;;
  doctor)   cmd_doctor ;;
  ""|-h|--help|help) usage ;;
  *) echo "sandbox: unknown subcommand '$cmd'" >&2; usage; exit 2 ;;
esac
