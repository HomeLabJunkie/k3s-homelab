#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DR_HOST="${DR_HOST:-k3s-dr}"
REMOTE_DIR="${REMOTE_DIR:-/usr/local/libexec/k3s-dr}"
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
KUBECTL="${KUBECTL:-kubectl}"
SSH="${SSH:-ssh}"
SCP="${SCP:-scp}"
PLAN_ONLY=1
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
RESTORE_MANIFEST="${RESTORE_MANIFEST:-$SCRIPT_DIR/generated-latest-restore.yaml}"
BINDINGS_MANIFEST="${BINDINGS_MANIFEST:-$SCRIPT_DIR/generated-latest-bindings.yaml}"
VALIDATION_MANIFEST="${VALIDATION_MANIFEST:-$SCRIPT_DIR/generated-latest-validation.yaml}"

INVENTORY="$SCRIPT_DIR/dr-find-backups.sh"
GEN_RESTORE="$SCRIPT_DIR/dr-generate-restore.sh"
GEN_VALIDATION="$SCRIPT_DIR/dr-generate-validation.sh"

REMOTE_PREFLIGHT="$REMOTE_DIR/dr-preflight.sh"
REMOTE_VALIDATE_GENERATED="$REMOTE_DIR/dr-validate-generated.sh"
REMOTE_APPLY="$REMOTE_DIR/dr-apply-restore.sh"
REMOTE_BIND="$REMOTE_DIR/dr-bind-restores.sh"
REMOTE_VALIDATE_APPS="$REMOTE_DIR/dr-validate-apps.sh"
REMOTE_APPLY_VALIDATION="$REMOTE_DIR/dr-apply-validation.sh"
REMOTE_CLEANUP="$REMOTE_DIR/dr-cleanup.sh"

STAMP="$(date +%Y%m%d-%H%M%S)"

REMOTE_RESTORE="$REMOTE_TMP/$(basename "$RESTORE_MANIFEST")"
REMOTE_BINDINGS="$REMOTE_TMP/generated-bindings-$STAMP.yaml"
REMOTE_VALIDATION="$REMOTE_TMP/$(basename "$VALIDATION_MANIFEST")"

usage() {
cat <<'EOF'
Usage:
  dr-rehearsal.sh [--execute]

Default:
  Plan/preflight only. No destructive actions.

--execute:
  Run the full DR rehearsal.

Safety:
  - Never auto-types RESTORE, BIND, or CLEANUP.
  - Validation failure preserves DR state.
  - Cleanup is not started after failed validation.
EOF
}

while (( $# )); do
  case "$1" in
    --execute) PLAN_ONLY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/dr-rehearsal-$STAMP.log"
exec > >(tee -a "$LOG_FILE") 2>&1

declare -A RESULT=(
  [production_api]="NOT RUN"
  [backup_inventory]="NOT RUN"
  [dr_preflight]="NOT RUN"
  [restore_generation]="NOT RUN"
  [validation_generation]="NOT RUN"
  [restore_validation]="NOT RUN"
  [longhorn_restore]="NOT RUN"
  [binding]="NOT RUN"
  [validation_apply]="NOT RUN"
  [application_validation]="NOT RUN"
  [cleanup]="NOT RUN"
  [final_preflight]="NOT RUN"
)

print_summary() {
  echo
  echo "============================================================"
  echo " DR REHEARSAL RESULT"
  echo "============================================================"
  printf '%-34s %s\n' "Production Kubernetes API:" "${RESULT[production_api]}"
  printf '%-34s %s\n' "Production backup inventory:" "${RESULT[backup_inventory]}"
  printf '%-34s %s\n' "DR preflight:" "${RESULT[dr_preflight]}"
  printf '%-34s %s\n' "Restore manifest generation:" "${RESULT[restore_generation]}"
  printf '%-34s %s\n' "Validation manifest generation:" "${RESULT[validation_generation]}"
  printf '%-34s %s\n' "Restore manifest validation:" "${RESULT[restore_validation]}"
  printf '%-34s %s\n' "Longhorn restore:" "${RESULT[longhorn_restore]}"
  printf '%-34s %s\n' "PV/PVC binding:" "${RESULT[binding]}"
  printf '%-34s %s\n' "Validation workloads:" "${RESULT[validation_apply]}"
  printf '%-34s %s\n' "Application/data validation:" "${RESULT[application_validation]}"
  printf '%-34s %s\n' "DR cleanup:" "${RESULT[cleanup]}"
  printf '%-34s %s\n' "Final clean-state preflight:" "${RESULT[final_preflight]}"
  echo
  echo "Log: $LOG_FILE"
}

fail_stage() {
  RESULT["$1"]="FAIL"
  echo "ERROR: $2" >&2
  print_summary
  exit 1
}

for f in "$INVENTORY" "$GEN_RESTORE" "$GEN_VALIDATION"; do
  [[ -x "$f" ]] || { echo "ERROR: missing helper: $f" >&2; exit 2; }
done

echo "============================================================"
echo " K3S HOMELAB DR REHEARSAL ORCHESTRATOR"
echo "============================================================"
echo "Date:    $(date)"
echo "Mode:    $([[ $PLAN_ONLY -eq 1 ]] && echo PLAN-ONLY || echo EXECUTE)"
echo "DR host: $DR_HOST"
echo "Log:     $LOG_FILE"
echo

echo "===== 1. VERIFY DR SSH ====="
"$SSH" -o BatchMode=yes "$DR_HOST" 'echo "PASS: SSH reachable"; hostname' \
  || fail_stage dr_preflight "Passwordless SSH to $DR_HOST failed."

echo
echo "===== 2. VERIFY PRODUCTION API ====="
if "$KUBECTL" get --raw='/readyz' >/dev/null 2>&1; then
  RESULT[production_api]="PASS"
  echo "PASS: Production API reachable"
else
  fail_stage production_api "Production API not ready."
fi

echo
echo "===== 3. BACKUP INVENTORY ====="
"$INVENTORY" && RESULT[backup_inventory]="PASS" \
  || fail_stage backup_inventory "Backup inventory failed."

echo
echo "===== 4. DR PREFLIGHT ====="
"$SSH" "$DR_HOST" "sudo -n '$REMOTE_PREFLIGHT'" \
  && RESULT[dr_preflight]="PASS" \
  || fail_stage dr_preflight "DR preflight failed."

echo
echo "===== 5. GENERATE RESTORE MANIFEST ====="
"$GEN_RESTORE" --output "$RESTORE_MANIFEST" \
  && RESULT[restore_generation]="PASS" \
  || fail_stage restore_generation "Restore manifest generation failed."

echo
echo "===== 6. GENERATE VALIDATION MANIFEST ====="
"$GEN_VALIDATION" --output "$VALIDATION_MANIFEST" \
  && RESULT[validation_generation]="PASS" \
  || fail_stage validation_generation "Validation manifest generation failed."

echo
echo "===== 7. COPY MANIFESTS ====="
"$SCP" "$RESTORE_MANIFEST" "$VALIDATION_MANIFEST" "$DR_HOST:$REMOTE_TMP/" \
  || fail_stage restore_validation "Failed to copy manifests."

echo
echo "===== 8. VALIDATE RESTORE MANIFEST ====="
"$SSH" "$DR_HOST" "sudo -n '$REMOTE_VALIDATE_GENERATED' '$REMOTE_RESTORE'" \
  && RESULT[restore_validation]="PASS" \
  || fail_stage restore_validation "Restore manifest validation failed."

if (( PLAN_ONLY )); then
  echo
  echo "PLAN-ONLY REHEARSAL COMPLETE"
  echo "No restore/bind/validation/cleanup resources were applied."
  print_summary
  exit 0
fi

echo
echo "===== 9. LONGHORN RESTORE ====="
"$SSH" -t "$DR_HOST" "sudo -n '$REMOTE_APPLY' --manifest '$REMOTE_RESTORE'" \
  && RESULT[longhorn_restore]="PASS" \
  || fail_stage longhorn_restore "Restore failed or cancelled."

echo
echo "===== 10. PV/PVC BINDING ====="
echo "Remote generated bindings: $REMOTE_BINDINGS"

"$SSH" -t "$DR_HOST" \
  "sudo -n '$REMOTE_BIND' --manifest '$REMOTE_RESTORE' --output '$REMOTE_BINDINGS' --apply" \
  && RESULT[binding]="PASS" \
  || fail_stage binding "Binding failed or cancelled."

echo
echo "===== 11-12. VALIDATE / APPLY VALIDATION WORKLOADS ====="
"$SSH" "$DR_HOST" \
  "sudo -n '$REMOTE_APPLY_VALIDATION' '$REMOTE_VALIDATION'" \
  && RESULT[validation_apply]="PASS" \
  || fail_stage validation_apply "Validation workload dry-run/apply failed."

echo
echo "===== 13. APPLICATION VALIDATION ====="
set +e
"$SSH" "$DR_HOST" "sudo -n '$REMOTE_VALIDATE_APPS'"
RC=$?
set -e

if (( RC == 0 )); then
  RESULT[application_validation]="PASS"
elif (( RC == 2 )); then
  RESULT[application_validation]="WARN"
else
  RESULT[application_validation]="FAIL"
  echo "Validation failed; DR state preserved. Cleanup NOT started."
  print_summary
  exit 1
fi

echo
echo "===== 14. GUARDED CLEANUP ====="
"$SSH" -t "$DR_HOST" "sudo -n '$REMOTE_CLEANUP'" \
  && RESULT[cleanup]="PASS" \
  || fail_stage cleanup "Cleanup failed or cancelled."

echo
echo "===== 15. FINAL PREFLIGHT ====="
"$SSH" "$DR_HOST" "sudo -n '$REMOTE_PREFLIGHT'" \
  && RESULT[final_preflight]="PASS" \
  || fail_stage final_preflight "Final preflight failed."

print_summary

if [[ "${RESULT[application_validation]}" == "WARN" ]]; then
  echo "RESULT: FULL DR REHEARSAL PASSED WITH WARNINGS"
  exit 2
fi

echo "RESULT: FULL DR REHEARSAL PASSED"
