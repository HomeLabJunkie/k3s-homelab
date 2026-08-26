#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs/readiness}"

if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
  export VIRTUAL_ENV="${VIRTUAL_ENV:-$ROOT_DIR/.venv}"
  export PATH="$ROOT_DIR/.venv/bin:$PATH"
fi

REPO_DOCTOR="${REPO_DOCTOR:-$ROOT_DIR/repo-doctor.sh}"
DEPLOY="${DEPLOY:-$ROOT_DIR/deploy.sh}"
MAINTAIN_CLUSTER="${MAINTAIN_CLUSTER:-$ROOT_DIR/maintain-cluster.sh}"
BACKUP_VERIFY="${BACKUP_VERIFY:-$ROOT_DIR/backup/verify-backup.sh}"
DR_STATUS="${DR_STATUS:-$ROOT_DIR/dr-status.sh}"
DR_REHEARSAL="${DR_REHEARSAL:-$ROOT_DIR/recovery/dr-rehearsal.sh}"

RUN_MAINTENANCE=true
RUN_BACKUP=true
RUN_DR=true
BACKUP_SUDO_CHECK="${BACKUP_SUDO_CHECK:-true}"

usage() {
  cat <<'EOF'
Usage:
  ./workstation-readiness.sh [options]

Options:
  --no-maintenance  Skip the rolling cluster check-mode validation.
  --no-backup       Skip the production backup verifier.
  --no-dr           Skip DR status and plan-only rehearsal checks.
  -h, --help        Show this help.

Exit codes:
  0  READY
  1  NOT READY
  2  READY WITH WARNINGS

Safety:
  This wrapper never passes --apply, --bootstrap, or --execute.
  It runs maintenance in check mode and DR rehearsal in plan-only mode.
  The backup verifier may temporarily mount and unmount the configured NFS
  backup export, but it does not modify backup contents.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --no-maintenance)
      RUN_MAINTENANCE=false
      shift
      ;;
    --no-backup)
      RUN_BACKUP=false
      shift
      ;;
    --no-dr)
      RUN_DR=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/workstation-readiness-$STAMP.log"
exec > >(tee -a "$LOG_FILE") 2>&1

declare -a STAGE_ORDER=()
declare -A STAGE_LABEL=()
declare -A STAGE_STATUS=()
declare -A STAGE_RC=()

PASS=0
WARN=0
FAIL=0
SKIP=0

record_stage() {
  local id="$1"
  local label="$2"
  local status="$3"
  local rc="$4"

  STAGE_ORDER+=("$id")
  STAGE_LABEL["$id"]="$label"
  STAGE_STATUS["$id"]="$status"
  STAGE_RC["$id"]="$rc"

  case "$status" in
    PASS) PASS=$((PASS + 1)) ;;
    WARN) WARN=$((WARN + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
    SKIP) SKIP=$((SKIP + 1)) ;;
  esac
}

run_stage() {
  local id="$1"
  local label="$2"
  shift 2
  local command_path="$1"
  local rc
  local status

  echo
  echo "============================================================"
  echo " $label"
  echo "============================================================"

  if [[ ! -x "$command_path" ]]; then
    echo "ERROR: required command is missing or not executable: $command_path"
    record_stage "$id" "$label" FAIL 127
    return 0
  fi

  set +e
  "$@"
  rc=$?
  set -e

  case "$rc" in
    0) status=PASS ;;
    2) status=WARN ;;
    *) status=FAIL ;;
  esac

  echo "Stage result: $status (exit $rc)"
  record_stage "$id" "$label" "$status" "$rc"
}

skip_stage() {
  local id="$1"
  local label="$2"
  echo
  echo "SKIP: $label"
  record_stage "$id" "$label" SKIP 0
}

echo "============================================================"
echo " THINKPAD / OPERATOR WORKSTATION READINESS"
echo "============================================================"
echo
echo "Date:       $(date)"
echo "Host:       $(hostname)"
echo "Repository: $ROOT_DIR"
echo "DR host:    ${DR_HOST:-k3s-dr}"
echo "Log:        $LOG_FILE"

run_stage repo_doctor "Repository and cluster quick doctor" \
  "$REPO_DOCTOR" --quick

run_stage deploy_preflight "Deployment preflight" \
  "$DEPLOY" --preflight-only

if [[ "$RUN_MAINTENANCE" == true ]]; then
  run_stage maintenance "Rolling cluster maintenance check mode" \
    "$MAINTAIN_CLUSTER"
else
  skip_stage maintenance "Rolling cluster maintenance check mode"
fi

if [[ "$RUN_BACKUP" == true ]]; then
  if [[ "$BACKUP_SUDO_CHECK" == true ]]; then
    echo
    echo "Backup verification requires temporary sudo access for the NFS mount."
    if [[ -t 0 ]]; then
      if sudo -v; then
        run_stage backup "Production backup verification" \
          "$BACKUP_VERIFY"
      else
        echo "ERROR: sudo authentication failed; backup verification did not run."
        record_stage backup "Production backup verification" FAIL 1
      fi
    elif sudo -n -v >/dev/null 2>&1; then
      run_stage backup "Production backup verification" \
        "$BACKUP_VERIFY"
    else
      echo "ERROR: backup verification requires cached or passwordless sudo in non-interactive mode."
      record_stage backup "Production backup verification" FAIL 1
    fi
  else
    run_stage backup "Production backup verification" \
      "$BACKUP_VERIFY"
  fi
else
  skip_stage backup "Production backup verification"
fi

if [[ "$RUN_DR" == true ]]; then
  run_stage dr_status "Disaster-recovery readiness status" \
    "$DR_STATUS"
  run_stage dr_rehearsal "Disaster-recovery plan-only rehearsal" \
    "$DR_REHEARSAL"
else
  skip_stage dr_status "Disaster-recovery readiness status"
  skip_stage dr_rehearsal "Disaster-recovery plan-only rehearsal"
fi

echo
echo "============================================================"
echo " WORKSTATION READINESS SUMMARY"
echo "============================================================"
printf '%-48s %-6s %s\n' "CHECK" "RESULT" "EXIT"
for id in "${STAGE_ORDER[@]}"; do
  printf '%-48s %-6s %s\n' \
    "${STAGE_LABEL[$id]}" \
    "${STAGE_STATUS[$id]}" \
    "${STAGE_RC[$id]}"
done

echo
echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"
echo "SKIP: $SKIP"
echo "Log:  $LOG_FILE"
echo

if (( FAIL > 0 )); then
  echo "RESULT: WORKSTATION NOT READY"
  exit 1
fi

if (( WARN > 0 )); then
  echo "RESULT: WORKSTATION READY WITH WARNINGS"
  exit 2
fi

echo "RESULT: WORKSTATION READY"
exit 0
