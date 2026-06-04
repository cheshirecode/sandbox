#!/usr/bin/env bash
# Assert mounts.env (used by bin/sandbox.sh) and .devcontainer/devcontainer.json
# (used by the devcontainer CLI / VS Code) declare the same set of container
# mount targets. Drift here is the v1 risk verifier 2 flagged in the design
# council — silent divergence between the two launch paths means a developer
# could `docker run` cleanly but `devcontainer up` lands with a broken layout
# (or vice versa).
#
# We compare the canonical list of `target=...` strings on both sides.
# Source paths can differ in surface form (env var expansion order); targets
# are stable.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOUNTS_ENV="$REPO_ROOT/mounts.env"
DEVCONTAINER="$REPO_ROOT/.devcontainer/devcontainer.json"

[[ -f "$MOUNTS_ENV" ]]    || { echo "check-mounts-sync: missing $MOUNTS_ENV" >&2; exit 1; }
[[ -f "$DEVCONTAINER" ]] || { echo "check-mounts-sync: missing $DEVCONTAINER" >&2; exit 1; }

extract_targets_from_mounts_env() {
  # Pull `target=...,` substrings out of mounts.env --mount lines.
  grep -oE 'target=[^,"]+' "$MOUNTS_ENV" | sort -u
}

extract_targets_from_devcontainer() {
  python3 - <<PY
import json, re, sys
# strip // comments since devcontainer.json allows them but json.load doesn't
text = open("$DEVCONTAINER").read()
text = re.sub(r'^\s*//.*$', '', text, flags=re.MULTILINE)
data = json.loads(text)
for m in data.get("mounts", []):
    for part in m.split(","):
        if part.startswith("target="):
            print(part)
PY
  : # silence trailing
}

env_targets=$(extract_targets_from_mounts_env)
dc_targets=$(extract_targets_from_devcontainer | sort -u)

if [[ "$env_targets" == "$dc_targets" ]]; then
  echo "check-mounts-sync: OK ($(echo "$env_targets" | wc -l | tr -d ' ') targets aligned)"
  exit 0
fi

echo "check-mounts-sync: DRIFT detected" >&2
echo "--- only in mounts.env ---" >&2
comm -23 <(echo "$env_targets") <(echo "$dc_targets") >&2
echo "--- only in devcontainer.json ---" >&2
comm -13 <(echo "$env_targets") <(echo "$dc_targets") >&2
exit 1
