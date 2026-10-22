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
[[ "$name" == "${MOCK_KILL_STAGE:-}" ]] && kill -TERM "$PPID"
[[ "$name $*" == "dr-power off" ]] && exit "${MOCK_POWER_OFF_RC:-0}"
case "$name" in
  "$MOCK_WARN_STAGE") exit 2 ;;
  "$MOCK_FAIL_STAGE") exit 7 ;;
  *) exit 0 ;;
esac
EOF

# The DR host answers on SSH only when MOCK_DR_UP=1.
mkdir -p "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/ssh" <<'EOF'
#!/usr/bin/env bash
[[ "${MOCK_DR_UP:-1}" == 1 ]]
EOF

chmod +x "$MOCK" "$TEST_ROOT/bin/ssh"

for name in repo-doctor deploy maintain backup dr-status dr-rehearsal dr-power; do
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
    DR_POWER="$TEST_ROOT/dr-power" \
    PATH="$TEST_ROOT/bin:$PATH" \
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
[[ "$(grep -c '^dr-power|' "$CALLS")" == 0 ]] || {
  echo "FAIL: the DR server was powered while the DR host answered"
  fail_count=$((fail_count + 1))
}

# The DR host is down: power on before the DR checks, power off after them.
# Expected calls, in order, one per line.
run_power_case() {
  local name="$1" expected_rc="$2" expected_calls="$3"
  shift 3
  local output="$TEST_ROOT/$name.out" rc
  : >"$CALLS"
  set +e
  env ROOT_DIR="$TEST_ROOT" LOG_DIR="$LOG_DIR" \
    REPO_DOCTOR="$TEST_ROOT/repo-doctor" DEPLOY="$TEST_ROOT/deploy" \
    MAINTAIN_CLUSTER="$TEST_ROOT/maintain" BACKUP_VERIFY="$TEST_ROOT/backup" \
    DR_STATUS="$TEST_ROOT/dr-status" DR_REHEARSAL="$TEST_ROOT/dr-rehearsal" \
    DR_POWER="$TEST_ROOT/dr-power" PATH="$TEST_ROOT/bin:$PATH" \
    MOCK_CALLS="$CALLS" MOCK_WARN_STAGE='' MOCK_FAIL_STAGE='' MOCK_DR_UP=0 \
    "$@" "$REPO_ROOT/workstation-readiness.sh" "${READINESS_ARGS[@]}" >"$output" 2>&1
  rc=$?
  set -e
  if (( rc == expected_rc )) &&
     [[ "$(cut -d'|' -f1,2 "$CALLS")" == "$expected_calls" ]]; then
    echo "PASS: $name"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $name (expected rc=$expected_rc; got rc=$rc)"
    echo "Expected calls:"; printf '%s\n' "$expected_calls"
    echo "Calls:"; cat "$CALLS"
    sed -n '1,200p' "$output"
    fail_count=$((fail_count + 1))
  fi
}

READINESS_ARGS=()
POWERED="repo-doctor|--quick
deploy|--preflight-only
maintain|
backup|
dr-power|on
dr-status|
dr-rehearsal|
dr-power|off"

run_power_case power-cycle 0 "$POWERED"
if ! grep -qF 'Power on the DR server' "$TEST_ROOT/power-cycle.out" ||
   ! grep -qF 'Power off the DR server' "$TEST_ROOT/power-cycle.out"; then
  echo "FAIL: power stages missing from the summary"
  fail_count=$((fail_count + 1))
fi
run_power_case power-off-after-failed-check 1 "$POWERED" MOCK_FAIL_STAGE=dr-rehearsal
run_power_case power-off-fails-warns 2 "$POWERED" MOCK_POWER_OFF_RC=1
grep -qF 'the DR server may still be on' "$TEST_ROOT/power-off-fails-warns.out" || {
  echo "FAIL: no warning when power-off fails"
  fail_count=$((fail_count + 1))
}
run_power_case power-off-on-interrupt 130 "repo-doctor|--quick
deploy|--preflight-only
maintain|
backup|
dr-power|on
dr-status|
dr-rehearsal|
dr-power|off" MOCK_KILL_STAGE=dr-rehearsal
READINESS_ARGS=(--no-dr-power)
run_power_case no-dr-power 0 "repo-doctor|--quick
deploy|--preflight-only
maintain|
backup|
dr-status|
dr-rehearsal|"

echo
echo "Workstation readiness tests: $pass_count passed, $fail_count failed"
(( fail_count == 0 ))
