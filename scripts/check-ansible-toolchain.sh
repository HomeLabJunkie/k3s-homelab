#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_FILE="${TOOLCHAIN_POLICY_FILE:-$REPO_DIR/config/toolchain.env}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v ansible >/dev/null 2>&1 || fail "ansible command is required"
command -v python3 >/dev/null 2>&1 || fail "python3 command is required"
[[ -r "$POLICY_FILE" ]] || fail "toolchain policy is missing: $POLICY_FILE"

# shellcheck disable=SC1090
source "$POLICY_FILE"

version_ge() {
  python3 - "$1" "$2" <<'PY'
import re, sys
def parse(v):
    nums=[int(x) for x in re.findall(r'\d+', v)[:3]]
    return tuple((nums+[0,0,0])[:3])
raise SystemExit(0 if parse(sys.argv[1]) >= parse(sys.argv[2]) else 1)
PY
}

version_lt() {
  python3 - "$1" "$2" <<'PY'
import re, sys
def parse(v):
    nums=[int(x) for x in re.findall(r'\d+', v)[:3]]
    return tuple((nums+[0,0,0])[:3])
raise SystemExit(0 if parse(sys.argv[1]) < parse(sys.argv[2]) else 1)
PY
}

ANSIBLE_CORE_VERSION="$(ansible --version | sed -n '1s/.*core \([^]]*\).*/\1/p')"
PYTHON_VERSION="$(python3 -c 'import platform; print(platform.python_version())')"

[[ -n "$ANSIBLE_CORE_VERSION" ]] || fail "could not determine ansible-core version"

echo "Ansible core: $ANSIBLE_CORE_VERSION"
echo "Python:       $PYTHON_VERSION"

version_ge "$ANSIBLE_CORE_VERSION" "$ANSIBLE_CORE_MIN" ||
  fail "ansible-core $ANSIBLE_CORE_VERSION is below supported minimum $ANSIBLE_CORE_MIN"
version_lt "$ANSIBLE_CORE_VERSION" "$ANSIBLE_CORE_MAX_EXCLUSIVE" ||
  fail "ansible-core $ANSIBLE_CORE_VERSION is outside validated series; require < $ANSIBLE_CORE_MAX_EXCLUSIVE"
version_ge "$PYTHON_VERSION" "$PYTHON_MIN" ||
  fail "Python $PYTHON_VERSION is below supported minimum $PYTHON_MIN"
version_lt "$PYTHON_VERSION" "$PYTHON_MAX_EXCLUSIVE" ||
  fail "Python $PYTHON_VERSION is outside validated range; require < $PYTHON_MAX_EXCLUSIVE"

echo "PASS: automation toolchain is within the repository-supported range"
