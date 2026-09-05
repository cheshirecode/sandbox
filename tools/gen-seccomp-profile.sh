#!/usr/bin/env bash
# Regenerate seccomp-bwrap.json: Docker's default seccomp profile (pinned
# moby release) plus one unconditional-allow rule for the syscalls
# bubblewrap needs to build its sandbox as an unprivileged user (userns +
# mount ns + pivot_root). Everything else keeps the default filtering —
# this replaces the blanket `seccomp=unconfined` the sandbox shipped with
# first.
#
# The generated file is COMMITTED so `sandbox.sh up` never needs network.
# Rerun this script (and commit the diff) to bump the pinned moby version.
set -euo pipefail

MOBY_VERSION="v27.5.1"
URL="https://raw.githubusercontent.com/moby/moby/${MOBY_VERSION}/profiles/seccomp/default.json"
OUT="$(cd "$(dirname "$0")/.." && pwd)/seccomp-bwrap.json"

curl -fsSL "$URL" | jq --arg v "$MOBY_VERSION" '
  .syscalls += [{
    "names": [
      "clone", "clone3", "unshare", "setns",
      "mount", "umount2", "pivot_root",
      "sethostname", "setdomainname"
    ],
    "action": "SCMP_ACT_ALLOW",
    "comment": ("sandbox: bubblewrap userns/mountns for srt; base profile moby " + $v)
  }]
' > "$OUT"

echo "wrote $OUT (base: moby $MOBY_VERSION)"
