#!/usr/bin/env bash
# shellcheck disable=SC2015  # Reporting helpers always return success.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR}"

RUN_DR=true
RUN_PREFLIGHT=true

PASS=0
WARN=0
FAIL=0
SKIP=0

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

skip() {
  printf 'SKIP: %s\n' "$*"
  SKIP=$((SKIP + 1))
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
  ./repo-doctor.sh [--quick] [--no-dr] [--no-preflight]

Options:
  --quick         Skip DR readiness and deployment preflight.
  --no-dr         Skip ./dr-status.sh.
  --no-preflight  Skip ./deploy.sh --preflight-only.
  -h, --help      Show this help.

Exit codes:
  0  Healthy
  1  One or more failures
  2  Healthy with warnings

Safety:
  Read-only diagnostics only.
  The deployment test uses --preflight-only.
  This script does not reconcile, bootstrap, restart, restore, or modify
  Kubernetes workloads.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --quick)
      RUN_DR=false
      RUN_PREFLIGHT=false
      shift
      ;;
    --no-dr)
      RUN_DR=false
      shift
      ;;
    --no-preflight)
      RUN_PREFLIGHT=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"

echo "============================================================"
echo " K3S HOMELAB REPOSITORY DOCTOR"
echo "============================================================"
echo
echo "Date:       $(date)"
echo "Repository: $ROOT_DIR"

section "1. GIT REPOSITORY"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git branch --show-current 2>/dev/null || true)"
  head="$(git rev-parse --short HEAD 2>/dev/null || true)"
  echo "Branch: ${branch:-unknown}"
  echo "HEAD:   ${head:-unknown}"

  [[ "$branch" == "main" ]] \
    && pass "Current branch is main" \
    || warn "Current branch is ${branch:-unknown}, expected main"

  if [[ -z "$(git status --porcelain)" ]]; then
    pass "Working tree is clean"
  else
    warn "Working tree has uncommitted changes"
    git status --short
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    pass "origin remote is configured"
  else
    fail_check "origin remote is not configured"
  fi

  if git fetch --quiet origin 2>/dev/null; then
    local_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    remote_sha="$(git rev-parse origin/main 2>/dev/null || true)"

    if [[ -n "$local_sha" && "$local_sha" == "$remote_sha" ]]; then
      pass "Local HEAD matches origin/main"
    else
      warn "Local HEAD does not match origin/main"
    fi
  else
    warn "Could not fetch origin to verify synchronization"
  fi
else
  fail_check "Repository root is not a Git working tree"
fi

section "2. AUTOMATION TOOLCHAIN"

if [[ -x "$ROOT_DIR/scripts/check-ansible-toolchain.sh" ]]; then
  set +e
  toolchain_output="$("$ROOT_DIR/scripts/check-ansible-toolchain.sh" 2>&1)"
  toolchain_rc=$?
  set -e
  printf '%s\n' "$toolchain_output"

  (( toolchain_rc == 0 )) \
    && pass "Ansible/Python toolchain is supported" \
    || fail_check "Ansible/Python toolchain check failed"
else
  fail_check "Toolchain checker is missing or not executable"
fi

section "3. ANSIBLE COLLECTIONS"

if [[ -x "$ROOT_DIR/scripts/ensure-ansible-collections.sh" ]]; then
  # The helper can install dependencies, so do not call it here. Doctor must
  # remain read-only. Instead inspect requirements and installed manifests.
  set +e
  collection_output="$(
    python3 - "$ROOT_DIR/collections/requirements.yml" \
      "$ROOT_DIR/.ansible/collections/ansible_collections" <<'PY'
from pathlib import Path
import json
import re
import sys

requirements = Path(sys.argv[1])
tree = Path(sys.argv[2])

entries = []
current = None
for raw in requirements.read_text().splitlines():
    line = raw.strip()
    m = re.match(r"-\s+name:\s*([A-Za-z0-9_.-]+)\s*$", line)
    if m:
        current = m.group(1)
        continue
    m = re.match(r"version:\s*[\"']?([^\"']+)[\"']?\s*$", line)
    if m and current:
        entries.append((current, m.group(1)))
        current = None

bad = False
for fqcn, wanted in entries:
    namespace, name = fqcn.split(".", 1)
    manifest = tree / namespace / name / "MANIFEST.json"
    if not manifest.exists():
        print(f"FAIL {fqcn}: missing (expected {wanted})")
        bad = True
        continue
    data = json.loads(manifest.read_text())
    actual = data.get("collection_info", {}).get("version")
    if actual == wanted:
        print(f"OK   {fqcn}: {actual}")
    else:
        print(f"FAIL {fqcn}: expected {wanted}, found {actual}")
        bad = True

raise SystemExit(1 if bad else 0)
PY
  )"
  collection_rc=$?
  set -e

  printf '%s\n' "$collection_output"

  (( collection_rc == 0 )) \
    && pass "Project-local Ansible collections match pinned versions" \
    || fail_check "Project-local Ansible collections are missing or mismatched"

  paths="$(ansible-config dump 2>/dev/null | sed -n 's/^COLLECTIONS_PATHS([^)]*) = //p')"
  scan="$(ansible-config dump 2>/dev/null | sed -n 's/^COLLECTIONS_SCAN_SYS_PATH([^)]*) = //p')"
  echo "Collection paths: ${paths:-unknown}"
  echo "Scan sys.path:    ${scan:-unknown}"

  [[ "$paths" == *"$ROOT_DIR/.ansible/collections"* ]] \
    && pass "Ansible uses the project-local collection path" \
    || fail_check "Project-local collection path is not active"

  [[ "$scan" == "False" ]] \
    && pass "System collection scanning is disabled" \
    || fail_check "System collection scanning is enabled"
else
  fail_check "Ansible collection helper is missing or not executable"
fi

section "4. DEPLOYMENT PREFLIGHT"

if [[ "$RUN_PREFLIGHT" == true ]]; then
  if [[ -x "$ROOT_DIR/deploy.sh" ]]; then
    set +e
    preflight_output="$("$ROOT_DIR/deploy.sh" --preflight-only 2>&1)"
    preflight_rc=$?
    set -e
    printf '%s\n' "$preflight_output"

    (( preflight_rc == 0 )) \
      && pass "Deployment preflight passed" \
      || fail_check "Deployment preflight failed"
  else
    fail_check "deploy.sh is missing or not executable"
  fi
else
  skip "Deployment preflight skipped by request"
fi

section "5. PRODUCTION KUBERNETES"

if command -v kubectl >/dev/null 2>&1; then
  readyz="$(kubectl get --raw=/readyz 2>/dev/null || true)"
  echo "API readyz: ${readyz:-unavailable}"

  [[ "$readyz" == "ok" ]] \
    && pass "Production Kubernetes API is ready" \
    || fail_check "Production Kubernetes API is not ready"

  node_output="$(kubectl get nodes --no-headers 2>/dev/null || true)"
  if [[ -n "$node_output" ]]; then
    printf '%s\n' "$node_output"
    node_total="$(awk 'END {print NR+0}' <<<"$node_output")"
    node_ready="$(awk '$2=="Ready" {n++} END {print n+0}' <<<"$node_output")"
    echo "Nodes Ready: ${node_ready}/${node_total}"

    (( node_total > 0 && node_ready == node_total )) \
      && pass "All Kubernetes nodes are Ready" \
      || fail_check "One or more Kubernetes nodes are not Ready"
  else
    fail_check "Could not read Kubernetes node status"
  fi

  cilium_bad="$(
    kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null |
      awk '$2!="1/1" || $3!="Running" {print}'
  )"
  [[ -z "$cilium_bad" ]] \
    && pass "Cilium pods are healthy" \
    || { printf '%s\n' "$cilium_bad"; fail_check "Cilium has unhealthy pods"; }

  vip_bad="$(
    kubectl -n kube-system get pods -l name=kube-vip-ds --no-headers 2>/dev/null |
      awk '$2!="1/1" || $3!="Running" {print}'
  )"
  [[ -z "$vip_bad" ]] \
    && pass "kube-vip pods are healthy" \
    || { printf '%s\n' "$vip_bad"; fail_check "kube-vip has unhealthy pods"; }

  lh_bad="$(
    kubectl -n longhorn-system get volumes.longhorn.io --no-headers \
      -o custom-columns='STATE:.status.state,ROBUSTNESS:.status.robustness,NAME:.metadata.name' \
      2>/dev/null |
      awk '$1!="attached" || $2!="healthy" {print}'
  )"

  [[ -z "$lh_bad" ]] \
    && pass "Longhorn volumes are attached and healthy" \
    || { printf '%s\n' "$lh_bad"; fail_check "Longhorn has unhealthy or detached volumes"; }
else
  fail_check "kubectl is not installed"
fi

section "6. SECURITY / LOCAL FILE HYGIENE"

if [[ -f "$ROOT_DIR/.secrets.enc" ]]; then
  mode="$(stat -c '%a' "$ROOT_DIR/.secrets.enc" 2>/dev/null || true)"
  echo ".secrets.enc mode: ${mode:-unknown}"
  case "$mode" in
    600|640|400|440)
      pass ".secrets.enc permissions are restrictive"
      ;;
    *)
      warn ".secrets.enc permissions are broader than expected"
      ;;
  esac
else
  warn ".secrets.enc is not present"
fi

if git ls-files --error-unmatch .secrets >/dev/null 2>&1; then
  fail_check "Plaintext .secrets is tracked by Git"
else
  pass "Plaintext .secrets is not tracked by Git"
fi

if git ls-files --error-unmatch kubeconfig >/dev/null 2>&1; then
  warn "Repository-local kubeconfig is tracked by Git"
else
  pass "Repository-local kubeconfig is not tracked by Git"
fi

if [[ -e "$ROOT_DIR/k3s-server-token.sha256" ]]; then
  echo "k3s-server-token.sha256:"
  ls -l "$ROOT_DIR/k3s-server-token.sha256" 2>/dev/null || true
  if [[ -r "$ROOT_DIR/k3s-server-token.sha256" ]]; then
    pass "Token checksum file is readable by current user"
  else
    warn "Token checksum file is intentionally/not currently readable by current user"
  fi
fi

section "7. DISASTER RECOVERY READINESS"

if [[ "$RUN_DR" == true ]]; then
  if [[ -x "$ROOT_DIR/dr-status.sh" ]]; then
    set +e
    dr_output="$("$ROOT_DIR/dr-status.sh" 2>&1)"
    dr_rc=$?
    set -e
    printf '%s\n' "$dr_output"

    case "$dr_rc" in
      0)
        pass "DR status is READY"
        ;;
      2)
        warn "DR status is READY WITH WARNINGS"
        ;;
      *)
        fail_check "DR status is NOT READY"
        ;;
    esac
  else
    fail_check "dr-status.sh is missing or not executable"
  fi
else
  skip "DR readiness check skipped by request"
fi

section "REPOSITORY DOCTOR SUMMARY"

echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"
echo "SKIP: $SKIP"
echo

if (( FAIL > 0 )); then
  echo "RESULT: ATTENTION REQUIRED"
  exit 1
elif (( WARN > 0 )); then
  echo "RESULT: HEALTHY WITH WARNINGS"
  exit 2
else
  echo "RESULT: HEALTHY"
  exit 0
fi
