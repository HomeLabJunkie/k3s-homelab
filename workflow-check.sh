#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR}"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"

PASS=0
WARN=0
FAIL=0

pass() {
  printf 'PASS: %s\n' "$*"
  PASS=$((PASS + 1))
}

warn() {
  printf 'WARN: %s\n' "$*"
  WARN=$((WARN + 1))
}

fail_check() {
  printf 'FAIL: %s\n' "$*"
  FAIL=$((FAIL + 1))
}

section() {
  echo
  echo "============================================================"
  echo " $1"
  echo "============================================================"
}

usage() {
  cat <<'EOF'
Usage:
  ./workflow-check.sh
  ./workflow-check.sh existing
  ./workflow-check.sh bootstrap
  ./workflow-check.sh maintenance
  ./workflow-check.sh dr

Modes:
  existing     Validate the normal existing-cluster deployment entry point.
  bootstrap    Validate the explicit new-cluster bootstrap entry point.
  maintenance  Validate single-control-plane maintenance in Ansible check mode.
  dr           Validate disaster-recovery readiness.
  all          Run all validations. This is the default.

Safety:
  All modes are read-only.
  deploy.sh is always invoked with --preflight-only.
  maintenance uses Ansible --check.
  No reconciliation, bootstrap, restart, restore, or backup creation occurs.
EOF
}

MODE="${1:-all}"

case "$MODE" in
  all|existing|bootstrap|maintenance|dr) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "ERROR: cluster environment is missing: $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"

if [[ -f "$ROOT_DIR/.secrets.enc" ]]; then
  command -v sops >/dev/null 2>&1 || {
    echo "ERROR: sops is required" >&2
    exit 1
  }
  # shellcheck disable=SC1090
  source <(sops --decrypt "$ROOT_DIR/.secrets.enc")
elif [[ -f "$ROOT_DIR/.secrets" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/.secrets"
else
  echo "ERROR: no secrets file found" >&2
  exit 1
fi
set +a

echo "============================================================"
echo " K3S HOMELAB DEPLOYMENT WORKFLOW VALIDATOR"
echo "============================================================"
echo
echo "Mode:       $MODE"
echo "Repository: $ROOT_DIR"

run_existing() {
  section "NORMAL EXISTING-CLUSTER ENTRY POINT"

  echo "Command under test:"
  echo "  ./deploy.sh --preflight-only"
  echo

  set +e
  output="$("$ROOT_DIR/deploy.sh" --preflight-only 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$output"

  if (( rc == 0 )); then
    pass "Existing-cluster deployment preflight passed"
  else
    fail_check "Existing-cluster deployment preflight failed"
  fi

  if grep -q 'Deployment mode: existing' <<<"$output"; then
    pass "Default deployment mode resolves to existing-cluster reconciliation"
  else
    fail_check "Existing-cluster mode was not selected"
  fi

  if grep -q 'maintenance/reconcile-existing-cluster.yml' <<<"$output"; then
    pass "Existing-cluster lifecycle playbook was selected"
  else
    warn "Preflight output did not explicitly show the lifecycle playbook path"
  fi
}

run_bootstrap() {
  section "EXPLICIT BOOTSTRAP ENTRY POINT"

  echo "Command under test:"
  echo "  ./deploy.sh --bootstrap --preflight-only"
  echo

  set +e
  output="$("$ROOT_DIR/deploy.sh" --bootstrap --preflight-only 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$output"

  if (( rc == 0 )); then
    pass "Bootstrap deployment preflight passed"
  else
    fail_check "Bootstrap deployment preflight failed"
  fi

  if grep -q 'Deployment mode: bootstrap' <<<"$output"; then
    pass "Bootstrap mode requires and honors explicit --bootstrap"
  else
    fail_check "Bootstrap mode was not selected"
  fi

  if grep -q 'site.yml' <<<"$output"; then
    pass "Bootstrap lifecycle playbook was selected"
  else
    warn "Preflight output did not explicitly show site.yml"
  fi
}

run_maintenance() {
  section "SINGLE CONTROL-PLANE MAINTENANCE ENTRY POINT"

  target="${MAINTENANCE_TARGET:-${K3S_NODE_0:-}}"

  if [[ -z "$target" ]]; then
    fail_check "Could not determine maintenance target from K3S_NODE_0"
    return
  fi

  echo "Target: $target"
  echo "Command under test:"
  echo "  ansible-playbook ... maintenance/reconcile-k3s-server.yml -e target=$target --check"
  echo

  set +e
  output="$(
    ansible-playbook \
      -i "$ROOT_DIR/inventory/k3s-ansible/hosts.ini" \
      "$ROOT_DIR/maintenance/reconcile-k3s-server.yml" \
      -e "target=$target" \
      --check 2>&1
  )"
  rc=$?
  set -e

  printf '%s\n' "$output"

  if (( rc == 0 )); then
    pass "Single-server maintenance check mode passed"
  else
    fail_check "Single-server maintenance check mode failed"
  fi

  if grep -q 'existing embedded-etcd member' <<<"$output" ||
     grep -q 'Refuse bootstrap through maintenance path' <<<"$output"; then
    pass "Maintenance path includes existing-etcd/bootstrap safeguards"
  else
    warn "Could not confirm maintenance safeguard text in output"
  fi

  if grep -q 'PLAY RECAP' <<<"$output" &&
     ! grep -q 'failed=[1-9]' <<<"$output"; then
    pass "Maintenance check completed without Ansible failures"
  else
    fail_check "Maintenance check reported an Ansible failure"
  fi
}

run_dr() {
  section "DISASTER-RECOVERY ENTRY POINT"

  echo "Command under test:"
  echo "  ./dr-status.sh"
  echo

  if [[ ! -x "$ROOT_DIR/dr-status.sh" ]]; then
    fail_check "dr-status.sh is missing or not executable"
    return
  fi

  set +e
  output="$("$ROOT_DIR/dr-status.sh" 2>&1)"
  rc=$?
  set -e

  printf '%s\n' "$output"

  case "$rc" in
    0)
      pass "DR readiness is READY"
      ;;
    2)
      warn "DR readiness is READY WITH WARNINGS"
      ;;
    *)
      fail_check "DR readiness is NOT READY"
      ;;
  esac

  if grep -q 'RESULT: DR READY' <<<"$output"; then
    pass "Canonical DR readiness result is DR READY"
  elif grep -q 'RESULT: DR READY WITH WARNINGS' <<<"$output"; then
    warn "Canonical DR readiness result has warnings"
  else
    fail_check "Canonical DR readiness result is not READY"
  fi
}

case "$MODE" in
  all)
    run_existing
    run_bootstrap
    run_maintenance
    run_dr
    ;;
  existing)
    run_existing
    ;;
  bootstrap)
    run_bootstrap
    ;;
  maintenance)
    run_maintenance
    ;;
  dr)
    run_dr
    ;;
esac

section "WORKFLOW VALIDATION SUMMARY"

echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"
echo

if (( FAIL > 0 )); then
  echo "RESULT: WORKFLOW ATTENTION REQUIRED"
  exit 1
elif (( WARN > 0 )); then
  echo "RESULT: WORKFLOWS VALID WITH WARNINGS"
  exit 2
else
  echo "RESULT: ALL WORKFLOWS VALID"
  exit 0
fi
