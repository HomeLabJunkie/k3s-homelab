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
DR_POWER="${DR_POWER:-$ROOT_DIR/recovery/dr-host-power.sh}"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"
# The DR stages and the power script read DR_HOST from cluster.env; use the
# same host here, without bringing the rest of that file into this shell.
if [[ -z "${DR_HOST:-}" && -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  DR_HOST="$(set -a; source "$ENV_FILE" >/dev/null 2>&1; printf '%s' "${DR_HOST:-}")"
fi
DR_HOST="${DR_HOST:-k3s-dr}"

RUN_MAINTENANCE=true
RUN_BACKUP=true
RUN_DR=true
DR_AUTO_POWER=true

usage() {
  cat <<'EOF'
Usage:
  ./workstation-readiness.sh [options]

Options:
  --no-maintenance  Skip the rolling cluster check-mode validation.
  --no-backup       Skip the production backup verifier.
  --no-dr           Skip DR status and plan-only rehearsal checks.
  --no-dr-power     Do not power the DR server on if the DR host is
                    unreachable; the DR checks then run against it as is.
  -h, --help        Show this help.

Exit codes:
  0  READY
  1  NOT READY
  2  READY WITH WARNINGS

Safety:
  This wrapper never passes --apply, --bootstrap, or --execute.
  It runs maintenance in check mode and DR rehearsal in plan-only mode.
  If the DR host does not answer on SSH, it powers the DR server on with
  recovery/dr-host-power.sh, runs the DR checks, and powers it off again,
  also when a check fails or the run is interrupted. A server that was
  already on is left on.
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
    --no-dr-power)
      DR_AUTO_POWER=false
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

dr_host_answers() {
  ssh -o BatchMode=yes -o ConnectTimeout=6 "$DR_HOST" true >/dev/null 2>&1
}

# Switches the DR server off again if this run switched it on. A failure here
# leaves the server running, which costs power but does not make the
# workstation less ready, so it is a warning.
DR_POWERED_ON=false
dr_power_off() {
  local rc
  [[ "$DR_POWERED_ON" == true ]] || return 0
  DR_POWERED_ON=false
  echo
  echo "============================================================"
  echo " Power off the DR server"
  echo "============================================================"
  set +e
  "$DR_POWER" off
  rc=$?
  set -e
  if (( rc == 0 )); then
    echo "Stage result: PASS (exit 0)"
    record_stage dr_power_off "Power off the DR server" PASS 0
  else
    echo "WARNING: the DR server may still be on; run $DR_POWER off"
    echo "Stage result: WARN (exit $rc)"
    record_stage dr_power_off "Power off the DR server" WARN "$rc"
  fi
}

# Ctrl-C or a kill during the DR checks still powers the server off. Ctrl-C
# also stops the tee that copies output to the terminal, so the cleanup writes
# to the log file and tells the terminal directly.
# shellcheck disable=SC2317  # say and on_exit run from the EXIT trap
say() { { printf '%s\n' "$*" >/dev/tty; } 2>/dev/null || true; }
# shellcheck disable=SC2317
on_exit() {
  [[ "$DR_POWERED_ON" == true ]] || return 0
  trap '' PIPE INT TERM
  exec >>"$LOG_FILE" 2>&1
  say "Interrupted; powering the DR server off (details in $LOG_FILE)..."
  echo
  echo "Interrupted; powering the DR server off before exiting."
  dr_power_off
  if [[ "${STAGE_STATUS[dr_power_off]:-}" == PASS ]]; then
    say "DR server is off."
  else
    say "WARNING: the DR server may still be on; run $DR_POWER off"
  fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

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
echo "DR host:    $DR_HOST"
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
  run_stage backup "Production backup verification" \
    "$BACKUP_VERIFY"
else
  skip_stage backup "Production backup verification"
fi

if [[ "$RUN_DR" == true ]]; then
  if [[ "$DR_AUTO_POWER" == true ]] && ! dr_host_answers; then
    echo
    echo "DR host $DR_HOST does not answer on SSH; powering the DR server on for the DR checks."
    # Set first: even a failed or interrupted power-on may have started the
    # server, so always try to switch it off again.
    DR_POWERED_ON=true
    run_stage dr_power_on "Power on the DR server" "$DR_POWER" on
  fi
  run_stage dr_status "Disaster-recovery readiness status" \
    "$DR_STATUS"
  run_stage dr_rehearsal "Disaster-recovery plan-only rehearsal" \
    "$DR_REHEARSAL"
  dr_power_off
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
