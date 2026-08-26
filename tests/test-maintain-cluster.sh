#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/fixture"
MOCK_BIN="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"

mkdir -p "$FIXTURE_ROOT/inventory" "$MOCK_BIN" "$STATE_DIR"
: >"$FIXTURE_ROOT/inventory/hosts.ini"

cat >"$MOCK_BIN/ansible-inventory" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "node": {"hosts": ["worker-1", "worker-2"]},
  "master": {"hosts": ["master-1"]}
}
JSON
EOF

cat >"$TEST_ROOT/mock-maintain-node.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$MOCK_CALLS_FILE"
if [[ -n "${MOCK_FAIL_TARGET:-}" && "$1" == "$MOCK_FAIL_TARGET" ]]; then
  exit 7
fi
exit 0
EOF

chmod +x "$MOCK_BIN/ansible-inventory" "$TEST_ROOT/mock-maintain-node.sh"

pass_count=0
fail_count=0

assert_case() {
  local name="$1"
  local fail_target="$2"
  local expected_rc="$3"
  local expected_calls="$4"
  local expected_text="$5"
  local calls_file="$STATE_DIR/$name.calls"
  local output_file="$STATE_DIR/$name.out"
  local rc
  local actual_calls

  : >"$calls_file"

  set +e
  PATH="$MOCK_BIN:$PATH" \
    ROOT_DIR="$FIXTURE_ROOT" \
    INVENTORY="$FIXTURE_ROOT/inventory/hosts.ini" \
    NODE_SCRIPT="$TEST_ROOT/mock-maintain-node.sh" \
    LOG_DIR="$STATE_DIR/logs" \
    MOCK_CALLS_FILE="$calls_file" \
    MOCK_FAIL_TARGET="$fail_target" \
    "$REPO_ROOT/maintain-cluster.sh" >"$output_file" 2>&1
  rc=$?
  set -e

  actual_calls="$(<"$calls_file")"

  if (( rc == expected_rc )) &&
     [[ "$actual_calls" == "$expected_calls" ]] &&
     grep -qF "$expected_text" "$output_file"; then
    echo "PASS: $name"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $name"
    echo "Expected rc: $expected_rc; actual rc: $rc"
    echo "Expected calls:"
    printf '%s\n' "$expected_calls"
    echo "Actual calls:"
    printf '%s\n' "$actual_calls"
    sed -n '1,260p' "$output_file"
    fail_count=$((fail_count + 1))
  fi
}

assert_case \
  success \
  '' \
  0 \
  $'worker-1\nworker-2\nmaster-1' \
  'ROLLING CLUSTER MAINTENANCE: PASS'

assert_case \
  stop-on-failure \
  'worker-2' \
  7 \
  $'worker-1\nworker-2' \
  'SKIP: remaining nodes were not processed'

echo
echo "Rolling wrapper tests: $pass_count passed, $fail_count failed"
(( fail_count == 0 ))
