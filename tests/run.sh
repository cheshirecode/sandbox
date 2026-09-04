#!/usr/bin/env bash
# Test harness for the sandbox repo. Same script runs locally and in CI.
#
#   tests/run.sh static       static lint only (shellcheck + sync + JSON parse)
#   tests/run.sh build        docker build only
#   tests/run.sh functional   run image-based behavior tests (requires built image)
#   tests/run.sh all          static → build → functional
#
# Behavior tests use NON-SECRET fixture tokens (literal string "fake-token-xxxxx"
# whose only purpose is to exercise the entrypoint's read+shred path). Real GitHub
# auth is NOT exercised in CI (out of scope, identity-isolation principle: a CI
# runner should never hold a real GitHub credential).
#
# Skipped in CI (documented, not hidden):
#   - real `gh auth login --with-token` against api.github.com
#   - OrbStack-specific behavior (CI is Linux, no OrbStack)
#   - actual `apt install` package-discovery diff (slow, varies by mirror)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../mounts.env
source mounts.env
TEST_IMAGE="$IMAGE_NAME:test"
TEST_CONTAINER="${SANDBOX_LOGIN}-sandbox-test"

PASS=0; FAIL=0
say() { printf "  %-7s %s\n" "$1" "$2"; }
ok()   { say PASS "$1"; PASS=$((PASS+1)); }
fail() { say FAIL "$1"; FAIL=$((FAIL+1)); }

# --- Static checks ---------------------------------------------------------
test_static() {
  echo "=== static ==="

  if command -v shellcheck >/dev/null; then
    if shellcheck --severity=warning bin/*.sh tools/*.sh tests/*.sh entrypoint.sh container-autosave.sh; then
      ok "shellcheck"
    else
      fail "shellcheck"
    fi
  else
    say SKIP "shellcheck not installed"
  fi

  if ./tools/check-mounts-sync.sh; then
    ok "mounts.env ↔ devcontainer.json sync"
  else
    fail "mount-target drift"
  fi

  if python3 -c "
import json, re
t = open('.devcontainer/devcontainer.json').read()
t = re.sub(r'^\s*//.*$', '', t, flags=re.MULTILINE)
json.loads(t)
" 2>/dev/null; then
    ok "devcontainer.json parses"
  else
    fail "devcontainer.json malformed"
  fi

  # Runtime shim contract (mounts.env). Each was proven red against the
  # pre-shim mounts.env before landing.
  if (SANDBOX_RUNTIME=bogus "$BASH" -c 'source mounts.env' 2>/dev/null); then
    fail "shim rejects unknown SANDBOX_RUNTIME"
  else
    ok "shim rejects unknown SANDBOX_RUNTIME"
  fi
  shim_out=$(SANDBOX_RUNTIME=podman PATH="$(mktemp -d)" "$BASH" -c 'source mounts.env' 2>&1 || true)
  if printf '%s' "$shim_out" | grep -q 'not on PATH'; then
    ok "shim names a runtime missing from PATH"
  else
    fail "shim names a runtime missing from PATH"
  fi
  if "$BASH" -c 'source mounts.env >/dev/null 2>&1; [ -n "$SANDBOX_RT" ] && declare -F docker >/dev/null'; then
    ok "shim resolves a runtime and shadows docker"
  else
    fail "shim resolves a runtime and shadows docker"
  fi
}

# --- Build -----------------------------------------------------------------
test_build() {
  echo "=== build ==="
  if docker build \
        --build-arg "HOST_UID=$(id -u 2>/dev/null || echo 1000)" \
        --build-arg "HOST_GID=$(id -g 2>/dev/null || echo 1000)" \
        -t "$TEST_IMAGE" \
        . >/dev/null; then
    ok "docker build"
  else
    fail "docker build"
    return 1
  fi

  # Size budget — council A6 said <1.5GB.
  local bytes mb
  bytes=$(docker image inspect "$TEST_IMAGE" --format '{{.Size}}')
  mb=$((bytes / 1024 / 1024))
  if [[ $mb -lt 1500 ]]; then
    ok "image size ${mb}MB < 1500MB budget"
  else
    fail "image size ${mb}MB exceeds 1500MB budget"
  fi
}

# --- Functional -----------------------------------------------------------
cleanup_test_container() {
  docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true
  # Inbox is a bind mount — clean per test so earlier-run env.diffs can't
  # leak into a current test's assertions (e.g., test #9's secret-shape check).
  rm -rf "${SANDBOX_INBOX_DIR:?}"/*  2>/dev/null || true
}

# Run entrypoint with given env / stdin token. Returns exit code.
# Stdout/stderr are captured to $1 (out file) / $2 (err file).
run_entry() {
  local outf="$1" errf="$2"; shift 2
  cleanup_test_container
  docker run --rm \
    --name "$TEST_CONTAINER" \
    "$@" \
    --entrypoint /usr/local/bin/sandbox-entrypoint \
    "$TEST_IMAGE" \
    true \
    >"$outf" 2>"$errf"
}

# Run entrypoint then exec an arbitrary check command inside.
# Container stays around for `docker exec` queries, removed at end.
# shellcheck disable=SC2120 # extra args forwarded variadically; callers may pass zero
start_test_container() {
  cleanup_test_container
  # tmpfs mount only materializes at `docker start`, not at `docker create`.
  # So: create → start → exec-to-plant-token while entrypoint waits briefly.
  # The previous ordering (create → cp → start) worked on macOS Docker
  # Desktop but failed in CI's Docker because /run/secrets didn't exist yet.
  mkdir -p "$SANDBOX_HOME_DIR/.sandbox"
  rm -f "$SANDBOX_HOME_DIR/.sandbox/entrypoint-ready"

  docker create \
    --name "$TEST_CONTAINER" \
    --mount "type=tmpfs,target=/run/secrets" \
    -e "SANDBOX_WAIT_FOR_SECRETS=1" \
    "$@" \
    "$TEST_IMAGE" \
    sleep infinity >/dev/null

  docker start "$TEST_CONTAINER" >/dev/null

  # Plant fake token via stdin (no host tmp file, no docker cp race).
  # The string is a literal non-functional ASCII pattern; never a real cred.
  docker exec -i "$TEST_CONTAINER" sh -c \
    'cat > /run/secrets/gh_token && chmod 0400 /run/secrets/gh_token' \
    <<<'fake-token-for-test-only-not-a-real-credential'

  # Plant a structurally-valid-but-non-functional Anthropic credentials blob.
  # Same pattern as gh_token — exercises the entrypoint's read-and-shred logic
  # plus the named-volume write to ~/.claude/.credentials.json.
  docker exec -i "$TEST_CONTAINER" sh -c \
    'cat > /run/secrets/anthropic_token && chmod 0400 /run/secrets/anthropic_token' \
    <<<'{"access_token":"fake-anthropic-oauth-not-a-real-credential","refresh_token":"fake-refresh"}'

  # Plant a structurally-valid-but-non-functional Codex auth.json blob.
  # Mirrors the Anthropic plant exactly so test #4e-#4g exercise the same
  # read-and-shred path for the openai_token tmpfs entry.
  docker exec -i "$TEST_CONTAINER" sh -c \
    'cat > /run/secrets/openai_token && chmod 0400 /run/secrets/openai_token' \
    <<<'{"OPENAI_API_KEY":"sk-fake-not-a-real-credential","auth_mode":"oauth","tokens":{"access_token":"fake","refresh_token":"fake"}}'

  # Plant a fake OpenRouter token for Hermes Agent tests.
  docker exec -i "$TEST_CONTAINER" sh -c \
    'cat > /run/secrets/openrouter_token && chmod 0400 /run/secrets/openrouter_token' \
    <<<'sk-or-v1-fake-openrouter-token-for-test-only'

  # Entrypoint is PID1 and waits briefly for the tmpfs token before setup.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if docker exec "$TEST_CONTAINER" test -f /workspace/home/.sandbox/entrypoint-ready >/dev/null 2>&1; then
      return
    fi
    sleep 0.25
  done
  fail "entrypoint did not become ready"
}

test_functional() {
  echo "=== functional ==="

  # 1. Refuses GITHUB_TOKEN env (work-identity-shaped).
  local out err
  out=$(mktemp); err=$(mktemp)
  if ! run_entry "$out" "$err" -e "GITHUB_TOKEN=fake"; then
    if grep -q "refusing to start" "$err"; then
      ok "refuses GITHUB_TOKEN env"
    else
      fail "non-zero exit but missing 'refusing to start' message"
    fi
  else
    fail "did NOT refuse GITHUB_TOKEN (zero exit)"
  fi
  rm -f "$out" "$err"

  # 2. Refuses any env matching SANDBOX_REFUSE_PATTERNS (user-configurable
  # via .envrc; default empty means only GITHUB_TOKEN/GH_ENTERPRISE_TOKEN refused).
  # Test sets a synthetic pattern + env that matches it; entrypoint must refuse.
  out=$(mktemp); err=$(mktemp)
  if ! run_entry "$out" "$err" \
        -e "SANDBOX_REFUSE_PATTERNS=TESTREFUSE" \
        -e "TESTREFUSE_PROBE=v"; then
    if grep -q "refusing to start" "$err"; then
      ok "refuses env matching SANDBOX_REFUSE_PATTERNS"
    else
      fail "non-zero exit but missing 'refusing to start' message"
    fi
  else
    fail "did NOT refuse env matching SANDBOX_REFUSE_PATTERNS"
  fi
  rm -f "$out" "$err"

  # 3-7: start a long-lived container and exec checks.
  start_test_container

  # 3. Snapshot directory created.
  if docker exec "$TEST_CONTAINER" test -d /workspace/home/.sandbox/snapshot-entry; then
    ok "snapshot-entry/ created"
  else
    fail "snapshot-entry/ missing"
  fi

  # 4. Token file shredded after entrypoint consumed it.
  if ! docker exec "$TEST_CONTAINER" test -f /run/secrets/gh_token; then
    ok "tmpfs gh token wiped after entrypoint read"
  else
    fail "tmpfs gh token still present (not shredded)"
  fi

  # 4b. Anthropic tmpfs token also shredded.
  if ! docker exec "$TEST_CONTAINER" test -f /run/secrets/anthropic_token; then
    ok "tmpfs anthropic token wiped after entrypoint read"
  else
    fail "tmpfs anthropic token still present (not shredded)"
  fi

  # 4c. Anthropic credentials installed at ~/.claude/.credentials.json
  # (named-volume-backed; persists across docker rm).
  if docker exec "$TEST_CONTAINER" test -f /workspace/home/.claude/.credentials.json; then
    # Mode must be 0600 — exposed creds inside the container should not be
    # world-readable. Check octal.
    mode=$(docker exec "$TEST_CONTAINER" stat -c '%a' /workspace/home/.claude/.credentials.json 2>/dev/null)
    if [[ "$mode" == "600" ]]; then
      ok "Anthropic credentials installed at ~/.claude/.credentials.json mode 0600"
    else
      fail "Anthropic credentials mode is '$mode' (expected 600)"
    fi
  else
    fail "Anthropic credentials not installed at ~/.claude/.credentials.json"
  fi

  # 4d. Work-context exclusion (structural): no host ~/.claude bind mount.
  # The credentials are read from the EPHEMERAL tmpfs path, not from a
  # bind-mounted host directory. Host conversations + work MCP configs
  # therefore cannot reach the sandbox.
  bind_count=$(docker inspect "$TEST_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{end}}{{end}}' \
    2>/dev/null | tr ' ' '\n' | grep -cE '\.claude$' || true)
  if [[ "$bind_count" == "0" ]]; then
    ok "no host ~/.claude/ bind mount (work conversations isolated)"
  else
    fail "found $bind_count bind mount(s) targeting a .claude dir (potential work-context leak)"
  fi

  # 4e. Codex tmpfs token also shredded.
  if ! docker exec "$TEST_CONTAINER" test -f /run/secrets/openai_token; then
    ok "tmpfs openai/codex token wiped after entrypoint read"
  else
    fail "tmpfs openai/codex token still present (not shredded)"
  fi

  # 4f. Codex auth.json installed at ~/.codex/ mode 0600.
  if docker exec "$TEST_CONTAINER" test -f /workspace/home/.codex/auth.json; then
    mode=$(docker exec "$TEST_CONTAINER" stat -c '%a' /workspace/home/.codex/auth.json 2>/dev/null)
    if [[ "$mode" == "600" ]]; then
      ok "Codex credentials installed at ~/.codex/auth.json mode 0600"
    else
      fail "Codex credentials mode is '$mode' (expected 600)"
    fi
  else
    fail "Codex credentials not installed at ~/.codex/auth.json"
  fi

  # 4k. OpenRouter tmpfs token also shredded.
  if ! docker exec "$TEST_CONTAINER" test -f /run/secrets/openrouter_token; then
    ok "tmpfs openrouter token wiped after entrypoint read"
  else
    fail "tmpfs openrouter token still present (not shredded)"
  fi

  # 4l. Hermes Agent config/env installed at ~/.hermes/ mode 0600.
  if docker exec "$TEST_CONTAINER" test -f /workspace/home/.hermes/.env; then
    mode=$(docker exec "$TEST_CONTAINER" stat -c '%a' /workspace/home/.hermes/.env 2>/dev/null)
    if [[ "$mode" == "600" ]]; then
      ok "Hermes credentials installed at ~/.hermes/.env mode 0600"
    else
      fail "Hermes credentials mode is '$mode' (expected 600)"
    fi
  else
    fail "Hermes credentials not installed at ~/.hermes/.env"
  fi

  # 4j. Entrypoint clears stale .gitconfig.lock without aborting.
  # Regression: a prior killed entrypoint left a lock that made every
  # subsequent `up` exit 255 before `exec sleep infinity` ran.
  cleanup_test_container
  # Create a stale lock in the bind-mount target (simulating a prior crash).
  mkdir -p "${SANDBOX_HOME_DIR:?}"
  touch "$SANDBOX_HOME_DIR/.gitconfig.lock"
  docker run -d --name "$TEST_CONTAINER" \
    --mount "type=tmpfs,target=/run/secrets" \
    --mount "type=bind,source=$SANDBOX_HOME_DIR,target=/workspace/home" \
    --entrypoint /usr/bin/sleep \
    --user dev \
    "$TEST_IMAGE" 60 >/dev/null
  if docker exec "$TEST_CONTAINER" /usr/local/bin/sandbox-entrypoint true >/dev/null 2>&1; then
    ok "entrypoint completes despite stale .gitconfig.lock (cleared idempotently)"
  else
    fail "entrypoint aborted on stale .gitconfig.lock"
  fi
  rm -f "$SANDBOX_HOME_DIR/.gitconfig.lock"
  cleanup_test_container

  # 4i. Named-volume mount points are writable by dev (the actual container user).
  # Regression test for a real bug found during dogfood: image's mount targets
  # were root-owned, so when docker initialized empty named volumes from the
  # image, the resulting volumes were unwritable by dev. The prior 16 tests
  # missed this because the test container didn't run with `--user dev`.
  cleanup_test_container
  docker run -d --name "$TEST_CONTAINER" \
    --mount "type=volume,source=test-claude-vol,target=/workspace/home/.claude" \
    --mount "type=volume,source=test-codex-vol,target=/workspace/home/.codex" \
    --mount "type=volume,source=test-hermes-vol,target=/workspace/home/.hermes" \
    --user dev \
    "$TEST_IMAGE" 60 >/dev/null
  if docker exec "$TEST_CONTAINER" sh -c \
      'touch /workspace/home/.claude/.write-probe && touch /workspace/home/.codex/.write-probe && touch /workspace/home/.hermes/.write-probe'; then
    ok "named-volume mount points writable by dev user"
  else
    fail "named-volume mount points NOT writable by dev (root-owned image dirs?)"
  fi
  docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm test-claude-vol test-codex-vol test-hermes-vol >/dev/null 2>&1 || true

  # 4h. Graceful no-credentials startup (Linux/CI parity).
  # Asserts the entrypoint runs cleanly when ZERO LLM tokens are piped —
  # the "host has no LLM CLI installed" path that CI always exercises.
  cleanup_test_container
  docker run -d --name "$TEST_CONTAINER" \
    --mount "type=tmpfs,target=/run/secrets" \
    --entrypoint /usr/bin/sleep \
    "$TEST_IMAGE" 60 >/dev/null
  # Run entrypoint WITHOUT planting any tokens
  if docker exec "$TEST_CONTAINER" /usr/local/bin/sandbox-entrypoint true >/dev/null 2>&1; then
    ok "entrypoint completes cleanly with zero LLM tokens piped"
  else
    fail "entrypoint failed when no LLM tokens were piped"
  fi
  cleanup_test_container

  # Restart the standard test container for the remaining assertions
  start_test_container

  # 4g. Work-context exclusion (structural): no host ~/.codex bind mount.
  bind_count_codex=$(docker inspect "$TEST_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{end}}{{end}}' \
    2>/dev/null | tr ' ' '\n' | grep -cE '\.codex$' || true)
  if [[ "$bind_count_codex" == "0" ]]; then
    ok "no host ~/.codex/ bind mount (Codex sessions isolated)"
  else
    fail "found $bind_count_codex bind mount(s) targeting a .codex dir"
  fi

  # 5. HTTPS insteadOf installed. git stores the key as `insteadOf` with
  # capital O; --get-all on the canonical key avoids case-sensitivity drift.
  if docker exec "$TEST_CONTAINER" git config --global --get-all 'url.https://github.com/.insteadOf' 2>/dev/null \
       | grep -q 'git@github.com:'; then
    ok "HTTPS insteadOf rewrite installed"
  else
    fail "HTTPS insteadOf rewrite missing"
  fi

  # 6. Git identity falls through to "user" under fake-token (which fails
  # `gh api user`). Entrypoint precedence: GIT_AUTHOR_NAME → gh api .login →
  # literal fallback "user". This test asserts the fallback path. The
  # override-wins path (GIT_AUTHOR_NAME respected when set) is test #8.
  name=$(docker exec "$TEST_CONTAINER" git config --global user.name 2>/dev/null || true)
  if [[ "$name" == "user" ]]; then
    ok "git identity falls through to 'user' on fake-token (entrypoint chain works)"
  else
    fail "git identity is '$name' (expected 'user' — fake token shouldn't auth gh api)"
  fi

  # 7. commit.gpgsign disabled.
  gpg=$(docker exec "$TEST_CONTAINER" git config --global commit.gpgsign 2>/dev/null || true)
  if [[ "$gpg" == "false" ]]; then
    ok "commit.gpgsign=false"
  else
    fail "commit.gpgsign='$gpg' (expected false)"
  fi

  cleanup_test_container

  # 9. Secret-shape filter strips AWS/Google/OpenAI/GitHub key shapes.
  # `pragma: allowlist secret` comments below mark intentional fake-but-
  # shaped values for secret scanners; these are non-functional ASCII.
  start_test_container
  # pragma: allowlist secret
  docker exec "$TEST_CONTAINER" bash -c '
    export AWS_ACCESS_KEY_ID=AKIA0000FAKEFAKEFAKE  # pragma: allowlist secret
    export GOOGLE_API_KEY=AIza0000FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE  # pragma: allowlist secret
    export OPENAI_API_KEY=sk-0000FAKEFAKEFAKEFAKEFAKEFAKE  # pragma: allowlist secret
    export GH_PAT=ghp_0000FAKEFAKEFAKEFAKEFAKEFAKE  # pragma: allowlist secret
    bash /usr/local/bin/container-autosave final >/dev/null 2>&1
    # Find env.diff files; check each for key-shaped leaks. Zero files = CLEAN
    # (filter stripped enough that diff was empty and auto-pruned).
    diff_files=$(find /workspace/inbox -name env.diff -type f 2>/dev/null)
    if [[ -z "$diff_files" ]]; then
      echo CLEAN
    elif echo "$diff_files" | xargs grep -lE "AKIA|AIza|sk-0000FAKE|ghp_" >/dev/null 2>&1; then
      echo LEAK
    else
      echo CLEAN
    fi
  ' > /tmp/secret-filter-result.txt 2>/dev/null
  filter_result=$(cat /tmp/secret-filter-result.txt | tail -1)
  if [[ "$filter_result" == "CLEAN" ]]; then
    ok "container-autosave strips AWS/Google/OpenAI/GitHub key shapes"
  else
    fail "container-autosave LEAKED key-shaped env vars to env.diff"
  fi
  rm -f /tmp/secret-filter-result.txt
  cleanup_test_container

  # 8. GIT_AUTHOR_NAME override wins.
  start_test_container -e "GIT_AUTHOR_NAME=override-name"
  name=$(docker exec "$TEST_CONTAINER" git config --global user.name 2>/dev/null || true)
  if [[ "$name" == "override-name" ]]; then
    ok "GIT_AUTHOR_NAME env override wins"
  else
    fail "GIT_AUTHOR_NAME override ignored (got '$name')"
  fi
  cleanup_test_container
}

# --- Dispatch --------------------------------------------------------------
case "${1:-all}" in
  static)     test_static ;;
  build)      test_build ;;
  functional) test_functional ;;
  all)        test_static; test_build && test_functional ;;
  *) echo "usage: $0 {static|build|functional|all}" >&2; exit 2 ;;
esac

echo
echo "tests: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]]
