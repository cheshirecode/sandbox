#!/usr/bin/env bash
# Pin mounted-source execution, dev permissions, diagnostics, and exit status.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/workspace"
cat > "$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == ps ]]; then
  [[ "${PROBE_FAIL:-0}" == 0 ]] || exit 9
  [[ "${NOT_RUNNING:-0}" == 0 ]] && echo testuser-sandbox
  exit 0
fi
printf '%s\n' "$@" > "$CALL_FILE"
echo "fake protocol output"
exit "${RESULT:-0}"
SH
chmod +x "$tmp/bin/docker"
run() {
  env -i PATH="$tmp/bin:$PATH" HOME="$tmp/home" SANDBOX_LOGIN=testuser \
    SANDBOX_WORKSPACE="$tmp/workspace" CALL_FILE="$tmp/call" \
    RESULT="${RESULT:-0}" PROBE_FAIL="${PROBE_FAIL:-0}" NOT_RUNNING="${NOT_RUNNING:-0}" \
    bash "$ROOT/bin/sandbox.sh" test-worklog "$@" > "$tmp/output" 2>&1
}
run
grep -qx -- '--user' "$tmp/call"
grep -qx dev "$tmp/call"
grep -qx /workspace/oss/dotfiles "$tmp/call"
grep -qx bin/dogfood-worklog-mcp.sh "$tmp/call"
grep -q 'full log:' "$tmp/output"
grep -qr 'fake protocol output' "$tmp/workspace/learnings-inbox"
rc=0; RESULT=7 run || rc=$?
[[ "$rc" == 7 ]]
grep -q 'exit=7' "$tmp/output"
rc=0; PROBE_FAIL=1 run || rc=$?
[[ "$rc" == 2 ]]
rc=0; NOT_RUNNING=1 run || rc=$?
[[ "$rc" == 2 ]]
rc=0; run unexpected || rc=$?
[[ "$rc" == 2 ]]
echo "worklog command: source, user, log, failure, unavailable, and arguments passed"
