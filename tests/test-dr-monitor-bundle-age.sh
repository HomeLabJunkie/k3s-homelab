#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
: >"$TEST_ROOT/apps.conf"

cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'/readyz'*) exit 0 ;;
  *'get nodes -o json'*)
    printf '%s\n' '{"items":[{"metadata":{"name":"node-0"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    ;;
  *'get backuptarget default'*) printf '%s' true ;;
  *'get backupvolumes.longhorn.io'*) printf '%s\n' '{"items":[]}' ;;
  *'get volumes.longhorn.io'*) : ;;
  *) exit 0 ;;
esac
EOF

cat >"$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'is-enabled'*) printf '%s\n' enabled ;;
  *'is-active'*) printf '%s\n' active ;;
  *'is-failed'*) printf '%s\n' inactive ;;
  *) exit 0 ;;
esac
EOF

cat >"$TEST_ROOT/verify-warning" <<'EOF'
#!/usr/bin/env bash
echo '==> Backup age: 24h (max 30h)'
echo 'BACKUP VERIFICATION PASSED'
EOF

cat >"$TEST_ROOT/verify-critical" <<'EOF'
#!/usr/bin/env bash
echo '==> Backup age: 31h (max 30h)'
echo 'ERROR: latest cluster backup is too old.'
exit 1
EOF

chmod +x "$TEST_ROOT/bin/kubectl" "$TEST_ROOT/bin/systemctl" \
  "$TEST_ROOT/verify-warning" "$TEST_ROOT/verify-critical"

run_monitor() {
  local verifier="$1" state="$2" output="$3"
  PATH="$TEST_ROOT/bin:$PATH" \
    APPS_FILE="$TEST_ROOT/apps.conf" \
    STATE_DIR="$state" \
    BACKUP_VERIFY="$verifier" \
    NOTIFY=/bin/true \
    "$REPO_ROOT/monitoring/dr-monitor.sh" >"$output" 2>&1
}

warning_output="$TEST_ROOT/warning.out"
run_monitor "$TEST_ROOT/verify-warning" "$TEST_ROOT/warning-state" "$warning_output"
grep -qF 'Status: WARNING' "$warning_output"
grep -qF 'WARNING: Cluster recovery bundle is 24h old' "$warning_output"

critical_output="$TEST_ROOT/critical.out"
set +e
run_monitor "$TEST_ROOT/verify-critical" "$TEST_ROOT/critical-state" "$critical_output"
critical_rc=$?
set -e
(( critical_rc == 1 ))
grep -qF 'Status: CRITICAL' "$critical_output"
grep -qF 'CRITICAL: Cluster recovery bundle verification failed at age 31h' "$critical_output"

echo 'PASS: DR monitor bundle-age warning and critical thresholds'
