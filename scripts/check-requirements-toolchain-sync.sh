#!/usr/bin/env bash
set -Eeuo pipefail

# Guard against the drift that occurs when Dependabot (or a manual edit) moves
# the ansible-core constraint in requirements.in without updating the supported
# range in config/toolchain.env. deploy.sh and maintain-node.sh both gate on
# config/toolchain.env via scripts/check-ansible-toolchain.sh, so the two files
# must always agree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REQUIREMENTS_IN="${REQUIREMENTS_IN:-$REPO_DIR/requirements.in}"
POLICY_FILE="${TOOLCHAIN_POLICY_FILE:-$REPO_DIR/config/toolchain.env}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -r "$REQUIREMENTS_IN" ]] || fail "requirements.in is missing: $REQUIREMENTS_IN"
[[ -r "$POLICY_FILE" ]] || fail "toolchain policy is missing: $POLICY_FILE"

# Expected form: ansible-core>=2.21.3,<2.22   (whitespace tolerant)
core_line="$(grep -E '^[[:space:]]*ansible-core[[:space:]]*>=' "$REQUIREMENTS_IN" || true)"
[[ -n "$core_line" ]] || fail "no 'ansible-core>=...' constraint found in requirements.in"

req_min="$(sed -E 's/.*>=[[:space:]]*([0-9]+(\.[0-9]+){0,2}).*/\1/' <<<"$core_line")"
req_max="$(sed -E 's/.*<[[:space:]]*([0-9]+(\.[0-9]+){0,2}).*/\1/' <<<"$core_line")"

[[ "$req_min" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "could not parse lower bound from: $core_line"
[[ "$req_max" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "could not parse upper bound from: $core_line"

# shellcheck disable=SC1090
source "$POLICY_FILE"

: "${ANSIBLE_CORE_MIN:?ANSIBLE_CORE_MIN not set in $POLICY_FILE}"
: "${ANSIBLE_CORE_MAX_EXCLUSIVE:?ANSIBLE_CORE_MAX_EXCLUSIVE not set in $POLICY_FILE}"

normalize() {
  # Pad to three numeric components so 2.22 == 2.22.0.
  python3 - "$1" <<'PY'
import re, sys
nums = [int(x) for x in re.findall(r'\d+', sys.argv[1])[:3]]
print('.'.join(str(n) for n in (nums + [0, 0, 0])[:3]))
PY
}

req_min_n="$(normalize "$req_min")"
req_max_n="$(normalize "$req_max")"
pol_min_n="$(normalize "$ANSIBLE_CORE_MIN")"
pol_max_n="$(normalize "$ANSIBLE_CORE_MAX_EXCLUSIVE")"

echo "requirements.in : ansible-core >= $req_min_n, < $req_max_n"
echo "toolchain.env   : ansible-core >= $pol_min_n, < $pol_max_n"

status=0
if [[ "$req_min_n" != "$pol_min_n" ]]; then
  echo "MISMATCH: ANSIBLE_CORE_MIN ($pol_min_n) != requirements.in lower bound ($req_min_n)" >&2
  status=1
fi
if [[ "$req_max_n" != "$pol_max_n" ]]; then
  echo "MISMATCH: ANSIBLE_CORE_MAX_EXCLUSIVE ($pol_max_n) != requirements.in upper bound ($req_max_n)" >&2
  status=1
fi

if (( status != 0 )); then
  echo "" >&2
  echo "Update config/toolchain.env to match requirements.in (or vice versa)." >&2
  echo "Remember to refresh the 'Automation toolchain guard' section of README.md too." >&2
  exit 1
fi

echo "PASS: requirements.in and config/toolchain.env agree on the ansible-core range"
