#!/usr/bin/env bash
set -Eeuo pipefail

# monitoring/dr-metrics.sh and the DR monitor's push: what reaches the
# Pushgateway, and that a failed push never fails the job.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/pushed"
: >"$TEST_ROOT/apps.conf"

# Each push is saved as pushed/<unit>; PUSH_FAIL=1 makes every push fail.
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'create --raw' ]]; then
  [[ "${PUSH_FAIL:-0}" == 1 ]] && { echo 'connection refused' >&2; exit 1; }
  [[ "$3" == /api/v1/namespaces/monitoring/services/http:pushgateway:9091/proxy/metrics/job/k3s-dr/unit/* ]] ||
    { echo "unexpected path $3" >&2; exit 1; }
  cat >"$PUSHED/${3##*/}"
  exit 0
fi
case "$*" in
  *'/readyz'*) exit 0 ;;
  *'get nodes -o json'*)
    printf '%s\n' '{"items":[{"metadata":{"name":"node-0"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    ;;
  *'get backuptarget default'*) printf '%s' true ;;
  *'get backupvolumes.longhorn.io'*) printf '%s\n' '{"items":[]}' ;;
  *) exit 0 ;;
esac
EOF

# The Velero canary's last run failed; the SMTP test has not run since login.
cat >"$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'is-enabled'*) printf '%s\n' enabled ;;
  *'is-active'*) printf '%s\n' active ;;
  *'is-failed'*) printf '%s\n' inactive ;;
  *'-p Result --value k3s-dr-restore-canary.service'*) printf '%s\n' exit-code ;;
  *'-p Result --value'*) printf '%s\n' success ;;
  *'smtp-test'*) printf '\n' ;;
  *'ExecMainStartTimestamp'*) printf '%s\n' @1700000000 ;;
  *'ExecMainExitTimestamp'*) printf '%s\n' @1700000600 ;;
  *) exit 0 ;;
esac
EOF

cat >"$TEST_ROOT/verify-backup" <<'EOF'
#!/usr/bin/env bash
echo '==> Backup storage free: 812 GiB (61%)'
echo '==> Backup age: 1h (max 30h)'
echo '==> Backup created: 1700000123'
echo 'BACKUP VERIFICATION PASSED'
EOF

cat >"$TEST_ROOT/verify-velero" <<'EOF'
#!/usr/bin/env bash
echo '==> Velero backup age: 0h'
EOF

chmod +x "$TEST_ROOT/bin/kubectl" "$TEST_ROOT/bin/systemctl" \
  "$TEST_ROOT/verify-backup" "$TEST_ROOT/verify-velero"
export PATH="$TEST_ROOT/bin:$PATH" PUSHED="$TEST_ROOT/pushed"

# ExecStopPost: SERVICE_RESULT, not the unit's Result, decides the outcome.
SERVICE_RESULT=success "$REPO_ROOT/monitoring/dr-metrics.sh" unit k3s-dr-restore-canary.service
grep -qx 'k3s_dr_job_last_result 1' "$PUSHED/k3s-dr-restore-canary.service"
grep -qx 'k3s_dr_job_last_success_timestamp_seconds 1700000600' "$PUSHED/k3s-dr-restore-canary.service"
grep -qx 'k3s_dr_job_last_duration_seconds 600' "$PUSHED/k3s-dr-restore-canary.service"

PATH="$TEST_ROOT/bin:$PATH" \
  APPS_FILE="$TEST_ROOT/apps.conf" \
  STATE_DIR="$TEST_ROOT/state" \
  BACKUP_VERIFY="$TEST_ROOT/verify-backup" \
  VELERO_VERIFY="$TEST_ROOT/verify-velero" \
  NOTIFY=/bin/true \
  "$REPO_ROOT/monitoring/dr-monitor.sh" >"$TEST_ROOT/monitor.out" 2>&1

monitor="$PUSHED/k3s-dr-monitor.service"
grep -qx 'k3s_dr_status 0' "$monitor"
grep -qx 'k3s_dr_bundle_verified 1' "$monitor"
grep -qx 'k3s_dr_bundle_created_timestamp_seconds 1700000123' "$monitor"
grep -qx 'k3s_dr_backup_storage_free_bytes 871878361088' "$monitor"
grep -qx 'k3s_dr_backup_storage_free_ratio 0.61' "$monitor"
grep -qx 'k3s_dr_timer_active{timer="k3s-dr-smtp-test.timer"} 1' "$monitor"
grep -qx 'k3s_dr_problems{severity="critical"} 0' "$monitor"

# The monitor's refresh reports the canary's failure but sends no success time.
grep -qx 'k3s_dr_job_last_result 0' "$PUSHED/k3s-dr-restore-canary.service"
if grep -q 'last_success' "$PUSHED/k3s-dr-restore-canary.service"; then
  echo 'FAIL: a failed run pushed a success time' >&2
  exit 1
fi
grep -qx 'k3s_dr_job_last_result 1' "$PUSHED/k3s-dr-backup.service"
[[ ! -e "$PUSHED/k3s-dr-smtp-test.service" ]]

# A failed push warns and still exits 0.
out="$(PUSH_FAIL=1 "$REPO_ROOT/monitoring/dr-metrics.sh" unit k3s-dr-backup.service 2>&1)"
grep -qF 'WARNING: could not push DR metrics for k3s-dr-backup.service' <<<"$out"

echo 'PASS: DR metrics pushes'
