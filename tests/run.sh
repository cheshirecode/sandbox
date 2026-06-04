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
  # So: create → start → exec-to-plant-token → exec-entrypoint. The previous
  # ordering (create → cp → start) worked on macOS Docker Desktop but failed
  # in CI's Docker because /run/secrets didn't exist in the container yet.

  docker create \
    --name "$TEST_CONTAINER" \
    --mount "type=tmpfs,target=/run/secrets" \
    "$@" \
    "$TEST_IMAGE" \
    sleep infinity >/dev/null

  docker start "$TEST_CONTAINER" >/dev/null

  # Plant fake token via stdin (no host tmp file, no docker cp race).
  # The string is a literal non-functional ASCII pattern; never a real cred.
  docker exec -i "$TEST_CONTAINER" sh -c \
    'cat > /run/secrets/gh_token && chmod 0400 /run/secrets/gh_token' \
    <<<'fake-token-for-test-only-not-a-real-credential'

  # Run the entrypoint in the background; capture output to /tmp inside.
  docker exec -d "$TEST_CONTAINER" bash -c '/usr/local/bin/sandbox-entrypoint sleep 60 > /tmp/entrypoint.out 2>&1'
  sleep 3  # give entrypoint time to run snapshots, git config, etc.
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
    ok "tmpfs token wiped after entrypoint read"
  else
    fail "tmpfs token still present (not shredded)"
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
  # Council item #7: pragma comments below mark intentional fake-but-shaped
  # values for secret-scanner tools; these are non-functional ASCII strings.
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
  # Same create→start→exec-stdin pattern as start_test_container (tmpfs
  # at /run/secrets only materializes at docker start, not docker create).
  cleanup_test_container
  docker create \
    --name "$TEST_CONTAINER" \
    --mount "type=tmpfs,target=/run/secrets" \
    -e "GIT_AUTHOR_NAME=override-name" \
    "$TEST_IMAGE" sleep 60 >/dev/null
  docker start "$TEST_CONTAINER" >/dev/null
  docker exec -i "$TEST_CONTAINER" sh -c \
    'cat > /run/secrets/gh_token && chmod 0400 /run/secrets/gh_token' \
    <<<'fake-token-for-test-only-not-a-real-credential'
  docker exec -d "$TEST_CONTAINER" /usr/local/bin/sandbox-entrypoint sleep 60
  sleep 2
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
