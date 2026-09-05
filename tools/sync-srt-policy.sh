#!/usr/bin/env bash
# Regenerate srt-settings.json from the srt-policy-packs generic-agent pack.
#
#   tools/sync-srt-policy.sh          rewrite srt-settings.json in place
#   tools/sync-srt-policy.sh --check  exit 1 if the committed file has drifted
#
# This repo is consumer #1 of github.com/cheshirecode/srt-policy-packs. The
# pack is the content source; this repo owns only the delta in
# srt-settings.overlay.json (extra domains and paths the sandbox needs) plus
# the --nested derivation (enableWeakerNestedSandbox, required inside Docker
# where privileged namespaces are unavailable).
#
# Vendoring is deliberate: srt-settings.json stays committed and baked into
# the image by the Dockerfile, so container start does NO network fetch and
# the entrypoint's sha256 default-upgrade mechanism is untouched. Syncing is
# a developer action, run against a local pack checkout.
#
# Merge rule: union, pack order first, overlay extras appended. The overlay
# can only ADD entries. An upstream deny can never be dropped by editing
# this repo — the failure mode that silently widens a fence.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PACK_NAME="generic-agent"
PACKS_REPO="github.com/cheshirecode/srt-policy-packs"
OVERLAY="srt-settings.overlay.json"
TARGET="srt-settings.json"

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  "")      ;;
  *)       echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

command -v jq >/dev/null || { echo "sync-srt-policy: jq required" >&2; exit 93; }

# Locate a local srt-policy-packs checkout. SRT_POLICY_PACKS wins; otherwise
# try the conventional siblings. Absent is a distinct exit code (93) so the
# test harness can SKIP rather than FAIL on a machine without the checkout.
find_packs_dir() {
  local d
  for d in "${SRT_POLICY_PACKS:-}" "$REPO_ROOT/../srt-policy-packs" "$HOME/Documents/oss/srt-policy-packs"; do
    [[ -n "$d" && -f "$d/packs/$PACK_NAME.json" ]] && { (cd "$d" && pwd); return 0; }
  done
  return 1
}

PACKS_DIR="$(find_packs_dir)" || {
  echo "sync-srt-policy: no srt-policy-packs checkout found." >&2
  echo "  Set SRT_POLICY_PACKS=/path/to/srt-policy-packs, or clone it beside this repo:" >&2
  echo "  git clone https://$PACKS_REPO $REPO_ROOT/../srt-policy-packs" >&2
  exit 93
}

PACK="$PACKS_DIR/packs/$PACK_NAME.json"
pack_sha="$(shasum -a 256 "$PACK" | awk '{print $1}')"

render() {
  jq -n \
    --slurpfile pack "$PACK" \
    --slurpfile ov "$OVERLAY" \
    --arg src "vendored from $PACKS_REPO packs/$PACK_NAME.json (sha256 $pack_sha) + $OVERLAY, --nested derivation, by tools/sync-srt-policy.sh. Do not hand-edit: edit $OVERLAY (or the pack upstream) and re-run the script." \
    '
    def union($a; $b):
      reduce (($a // []) + ($b // []))[] as $x ([]; if index([$x]) then . else . + [$x] end);
    $pack[0] as $p | $ov[0] as $o |
    {
      _comment: $o._settings_comment,
      _source: $src,
      enableWeakerNestedSandbox: true,
      network: {
        allowedDomains: union($p.network.allowedDomains; $o.network.allowedDomains),
        deniedDomains:  union($p.network.deniedDomains;  $o.network.deniedDomains)
      },
      filesystem: {
        denyRead:   union($p.filesystem.denyRead;   $o.filesystem.denyRead),
        allowWrite: union($p.filesystem.allowWrite; $o.filesystem.allowWrite),
        denyWrite:  union($p.filesystem.denyWrite;  $o.filesystem.denyWrite)
      }
    }'
}

NEW="$(mktemp)"
trap 'rm -f "$NEW"' EXIT
render > "$NEW"

# srt 1.0.0 rejects a settings file missing these even when empty. Verify the
# rendered file before it can replace a working policy.
jq -e '.network.allowedDomains and (.network.deniedDomains != null)
       and .filesystem.denyRead and .filesystem.allowWrite
       and (.filesystem.denyWrite != null)' "$NEW" >/dev/null \
  || { echo "sync-srt-policy: rendered policy is schema-incomplete — refusing to write" >&2; exit 65; }

if [[ $CHECK -eq 1 ]]; then
  if diff -u "$TARGET" "$NEW"; then
    echo "sync-srt-policy: $TARGET matches $PACK_NAME + $OVERLAY"
  else
    echo "sync-srt-policy: $TARGET has DRIFTED from the pack — run tools/sync-srt-policy.sh" >&2
    exit 1
  fi
else
  cat "$NEW" > "$TARGET"
  echo "sync-srt-policy: wrote $TARGET from $PACKS_DIR/packs/$PACK_NAME.json (sha256 $pack_sha)"
fi
