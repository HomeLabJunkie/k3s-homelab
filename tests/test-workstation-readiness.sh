#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

MOCK="$TEST_ROOT/mock-stage.sh"
CALLS="$TEST_ROOT/calls"
LOG_DIR="$TEST_ROOT/logs"

cat >"$MOCK" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s|%s\n' "$name" "$*" >>"$MOCK_CALLS"
case "$name" in
  "$MOCK_WARN_STAGE") exit 2 ;;
  "$MOCK_FAIL_STAGE") exit 7 ;;
  *) exit 0 ;;
esac
EOF

chmod +x "$MOCK"

for name in repo-doctor deploy maintain backup dr-status dr-rehearsal; do
  ln -s "$MOCK" "$TEST_ROOT/$name"
done

pass_count=0
fail_count=0

run_case() {
  local name="$1"
  local warn_stage="$2"
  local fail_stage="$3"
  local expected_rc="$4"
  local expected_result="$5"
  local expected_calls="$6"
  local output="$TEST_ROOT/$name.out"
  local rc
  local actual_calls

  : >"$CALLS"

  set +e
  ROOT_DIR="$TEST_ROOT" \
    LOG_DIR="$LOG_DIR" \
    REPO_DOCTOR="$TEST_ROOT/repo-doctor" \
    DEPLOY="$TEST_ROOT/deploy" \
    MAINTAIN_CLUSTER="$TEST_ROOT/maintain" \
    BACKUP_VERIFY="$TEST_ROOT/backup" \
    DR_STATUS="$TEST_ROOT/dr-status" \
    DR_REHEARSAL="$TEST_ROOT/dr-rehearsal" \
    MOCK_CALLS="$CALLS" \
    MOCK_WARN_STAGE="$warn_stage" \
    MOCK_FAIL_STAGE="$fail_stage" \
    "$REPO_ROOT/workstation-readiness.sh" >"$output" 2>&1
  rc=$?
  set -e

  actual_calls="$(wc -l <"$CALLS")"

  if (( rc == expected_rc )) &&
     (( actual_calls == expected_calls )) &&
     grep -qF "$expected_result" "$output" &&
     grep -qF 'repo-doctor|--quick' "$CALLS" &&
     grep -qF 'deploy|--preflight-only' "$CALLS" &&
     grep -qF 'maintain|' "$CALLS" &&
     grep -qF 'dr-rehearsal|' "$CALLS"; then
    echo "PASS: $name"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $name (expected rc=$expected_rc, calls=$expected_calls; got rc=$rc, calls=$actual_calls)"
    sed -n '1,260p' "$output"
    echo "Calls:"
    sed -n '1,100p' "$CALLS"
    fail_count=$((fail_count + 1))
  fi
}

run_case success '' '' 0 'RESULT: WORKSTATION READY' 6
run_case warning dr-status '' 2 'RESULT: WORKSTATION READY WITH WARNINGS' 6
run_case failure '' backup 1 'RESULT: WORKSTATION NOT READY' 6

echo
echo "Workstation readiness tests: $pass_count passed, $fail_count failed"
(( fail_count == 0 ))
