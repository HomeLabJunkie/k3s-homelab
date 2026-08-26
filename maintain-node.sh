#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR}"
INVENTORY="${INVENTORY:-$ROOT_DIR/inventory/k3s-ansible/hosts.ini}"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"

APPLY=false
ASSUME_YES=false
TARGET=""
POST_MAINTENANCE_VALIDATION_ATTEMPTS="${POST_MAINTENANCE_VALIDATION_ATTEMPTS:-60}"
POST_MAINTENANCE_VALIDATION_INTERVAL_SECONDS="${POST_MAINTENANCE_VALIDATION_INTERVAL_SECONDS:-2}"

fail() {
  echo
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./maintain-node.sh <TARGET>
  ./maintain-node.sh <TARGET> --apply
  ./maintain-node.sh <TARGET> --apply --yes

Examples:
  # Safe default: plan/check only
  ./maintain-node.sh 192.168.1.212
  ./maintain-node.sh 192.168.1.214

  # Apply after a successful check and interactive confirmation
  ./maintain-node.sh 192.168.1.212 --apply

  # Explicit non-interactive apply
  ./maintain-node.sh 192.168.1.214 --apply --yes

Behavior:
  - discovers whether TARGET is a control-plane server or worker
  - refuses unknown/ambiguous inventory targets
  - validates toolchain and pinned project collections
  - runs the correct dedicated maintenance playbook in --check first
  - defaults to check-only and makes no node changes
  - live execution requires --apply
  - --apply requires confirmation unless --yes is also supplied
  - validates API, target Node Ready, Cilium, kube-vip (control-plane),
    and Longhorn volumes after live execution
  - prints a PASS/FAIL summary and exits nonzero if validation fails

Safety:
  This wrapper is for EXISTING cluster nodes only. It never bootstraps a node.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      if [[ -n "$TARGET" ]]; then
        fail "specify exactly one target"
      fi
      TARGET="$1"
      shift
      ;;
  esac
done

[[ -n "$TARGET" ]] || {
  usage >&2
  exit 2
}

if [[ "$ASSUME_YES" == true && "$APPLY" != true ]]; then
  fail "--yes is only valid with --apply"
fi

[[ "$POST_MAINTENANCE_VALIDATION_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] ||
  fail "POST_MAINTENANCE_VALIDATION_ATTEMPTS must be a positive integer"

[[ "$POST_MAINTENANCE_VALIDATION_INTERVAL_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
  fail "POST_MAINTENANCE_VALIDATION_INTERVAL_SECONDS must be a nonnegative number"

cd "$ROOT_DIR"

for cmd in ansible ansible-playbook ansible-inventory kubectl python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
done

[[ -r "$INVENTORY" ]] || fail "inventory is missing: $INVENTORY"
[[ -r "$ENV_FILE" ]] || fail "cluster environment is missing: $ENV_FILE"

echo "============================================================"
echo " K3S SINGLE-NODE MAINTENANCE"
echo "============================================================"
echo
echo "Target: $TARGET"
echo "Mode:   $([[ "$APPLY" == true ]] && echo apply || echo check-only)"

echo
echo "===== TOOLCHAIN / COLLECTIONS ====="
"$ROOT_DIR/scripts/check-ansible-toolchain.sh"
"$ROOT_DIR/scripts/ensure-ansible-collections.sh"

echo
echo "===== LOAD CLUSTER CONFIGURATION ====="

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"

if [[ -f "$ROOT_DIR/.secrets.enc" ]]; then
  command -v sops >/dev/null 2>&1 || fail "sops is required"
  # shellcheck disable=SC1090
  source <(sops --decrypt "$ROOT_DIR/.secrets.enc")
elif [[ -f "$ROOT_DIR/.secrets" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$ROOT_DIR/.secrets"
else
  fail "neither .secrets.enc nor .secrets exists"
fi
set +a

echo "===== INVENTORY CLASSIFICATION ====="

inventory_json="$(mktemp)"
trap 'rm -f "$inventory_json"' EXIT

if ! ansible-inventory -i "$INVENTORY" --list >"$inventory_json"; then
  fail "ansible-inventory could not render the inventory"
fi

classification="$(
  python3 - "$TARGET" "$inventory_json" <<'PY_INVENTORY'
import json
import sys

target = sys.argv[1]
inventory_path = sys.argv[2]

with open(inventory_path, encoding="utf-8") as f:
    data = json.load(f)

def hosts(group):
    value = data.get(group, {})
    if isinstance(value, dict):
        return set(value.get("hosts", []) or [])
    return set()

master = target in hosts("master")
node = target in hosts("node")

if master and node:
    print("ambiguous")
elif master:
    print("master")
elif node:
    print("node")
else:
    print("unknown")
PY_INVENTORY
)"

rm -f "$inventory_json"
trap - EXIT

case "$classification" in
  master)
    PLAYBOOK="$ROOT_DIR/maintenance/reconcile-k3s-server.yml"
    NODE_TYPE="control-plane"
    ;;
  node)
    PLAYBOOK="$ROOT_DIR/maintenance/reconcile-k3s-agent.yml"
    NODE_TYPE="worker"
    ;;
  ambiguous)
    fail "target appears in both master and node inventory groups"
    ;;
  *)
    fail "target is not present in the master or node inventory group"
    ;;
esac

echo "Type:     $NODE_TYPE"
echo "Playbook: ${PLAYBOOK#"$ROOT_DIR"/}"

echo
echo "===== PRE-MAINTENANCE CLUSTER HEALTH ====="

readyz="$(kubectl get --raw=/readyz 2>/dev/null || true)"
[[ "$readyz" == "ok" ]] || fail "Kubernetes API is not ready"

target_name="$(
  kubectl get nodes -o wide --no-headers 2>/dev/null |
  awk -v ip="$TARGET" '$6 == ip {print $1; exit}'
)"

[[ -n "$target_name" ]] || fail "could not map target IP $TARGET to a Kubernetes node"

target_ready="$(
  kubectl get node "$target_name" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
)"

[[ "$target_ready" == "True" ]] ||
  fail "target Kubernetes node $target_name is not Ready"

echo "API:       ok"
echo "Node:      $target_name"
echo "NodeReady: True"

echo
echo "===== ANSIBLE CHECK MODE ====="

set +e
ansible-playbook \
  -i "$INVENTORY" \
  "$PLAYBOOK" \
  -e "target=$TARGET" \
  --check
CHECK_RC=$?
set -e

(( CHECK_RC == 0 )) || fail "maintenance check mode failed"

echo
echo "============================================================"
echo " CHECK MODE PASSED"
echo "============================================================"

if [[ "$APPLY" != true ]]; then
  echo
  echo "No node changes were made."
  echo
  echo "To apply this maintenance plan:"
  echo "  ./maintain-node.sh $TARGET --apply"
  exit 0
fi

echo
echo "===== APPLY AUTHORIZATION ====="

if [[ "$ASSUME_YES" != true ]]; then
  echo "About to reconcile:"
  echo "  Node:     $target_name"
  echo "  Address:  $TARGET"
  echo "  Type:     $NODE_TYPE"
  echo "  Playbook: ${PLAYBOOK#"$ROOT_DIR"/}"
  echo
  read -r -p "Type APPLY $TARGET to continue: " confirmation

  [[ "$confirmation" == "APPLY $TARGET" ]] ||
    fail "confirmation did not match; no live maintenance was run"
else
  echo "Explicit --apply --yes supplied; continuing non-interactively."
fi

echo
echo "===== LIVE SINGLE-NODE RECONCILIATION ====="

ansible-playbook \
  -i "$INVENTORY" \
  "$PLAYBOOK" \
  -e "target=$TARGET"

echo
echo "===== POST-MAINTENANCE VALIDATION ====="

api_ok=false
node_ok=false
cilium_ok=false
vip_ok=false
longhorn_ok=false

api_detail="Kubernetes API /readyz did not return ok"
node_detail="target node $target_name is not Ready"
cilium_detail="Cilium is unhealthy on $target_name"
vip_detail="kube-vip is unhealthy on $target_name"
longhorn_detail="Longhorn volume status could not be read"

for (( attempt = 1; attempt <= POST_MAINTENANCE_VALIDATION_ATTEMPTS; attempt++ )); do
  readyz="$(kubectl get --raw=/readyz 2>/dev/null || true)"
  if [[ "$readyz" == "ok" ]]; then
    api_ok=true
    api_detail="Kubernetes API /readyz returned ok"
  else
    api_ok=false
    api_detail="Kubernetes API /readyz returned ${readyz:-no response}"
  fi

  target_ready="$(
    kubectl get node "$target_name" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null || true
  )"
  if [[ "$target_ready" == "True" ]]; then
    node_ok=true
    node_detail="$target_name is Ready"
  else
    node_ok=false
    node_detail="$target_name Ready condition is ${target_ready:-unavailable}"
  fi

  if cilium="$(
    kubectl -n kube-system get pod \
      -l k8s-app=cilium \
      --field-selector "spec.nodeName=$target_name" \
      --no-headers 2>/dev/null
  )"; then
    bad_cilium="$(awk '$2!="1/1" || $3!="Running" {print}' <<<"$cilium")"
    if [[ -n "$cilium" && -z "$bad_cilium" ]]; then
      cilium_ok=true
      cilium_detail="Cilium is healthy on $target_name"
    elif [[ -z "$cilium" ]]; then
      cilium_ok=false
      cilium_detail="no Cilium pod found on $target_name"
    else
      cilium_ok=false
      cilium_detail="unhealthy Cilium pod(s): ${bad_cilium//$'\n'/; }"
    fi
  else
    cilium_ok=false
    cilium_detail="could not read Cilium pod status on $target_name"
  fi

  if [[ "$NODE_TYPE" != "control-plane" ]]; then
    vip_ok=true
    vip_detail="not applicable to worker nodes"
  elif vip_pod="$(
    kubectl -n kube-system get pod \
      -l name=kube-vip-ds \
      --field-selector "spec.nodeName=$target_name" \
      --no-headers 2>/dev/null
  )"; then
    bad_vip="$(awk '$2!="1/1" || $3!="Running" {print}' <<<"$vip_pod")"
    if [[ -n "$vip_pod" && -z "$bad_vip" ]]; then
      vip_ok=true
      vip_detail="kube-vip is healthy on $target_name"
    elif [[ -z "$vip_pod" ]]; then
      vip_ok=false
      vip_detail="no kube-vip pod found on $target_name"
    else
      vip_ok=false
      vip_detail="unhealthy kube-vip pod(s): ${bad_vip//$'\n'/; }"
    fi
  else
    vip_ok=false
    vip_detail="could not read kube-vip pod status on $target_name"
  fi

  if longhorn_volumes="$(
    kubectl -n longhorn-system get volumes.longhorn.io \
      --no-headers \
      -o custom-columns='STATE:.status.state,ROBUSTNESS:.status.robustness,NAME:.metadata.name' \
      2>/dev/null
  )"; then
    bad_longhorn="$(awk '$1!="attached" || $2!="healthy" {print}' <<<"$longhorn_volumes")"
    if [[ -z "$bad_longhorn" ]]; then
      longhorn_ok=true
      if [[ -n "$longhorn_volumes" ]]; then
        longhorn_detail="all Longhorn volumes are attached and healthy"
      else
        longhorn_detail="no Longhorn volumes found; nothing to validate"
      fi
    else
      longhorn_ok=false
      longhorn_detail="unhealthy or detached Longhorn volume(s): ${bad_longhorn//$'\n'/; }"
    fi
  else
    longhorn_ok=false
    longhorn_detail="could not read Longhorn volume status"
  fi

  if [[ "$api_ok" == true && "$node_ok" == true && \
        "$cilium_ok" == true && "$vip_ok" == true && \
        "$longhorn_ok" == true ]]; then
    break
  fi

  if (( attempt < POST_MAINTENANCE_VALIDATION_ATTEMPTS )); then
    sleep "$POST_MAINTENANCE_VALIDATION_INTERVAL_SECONDS"
  fi
done

echo
echo "============================================================"
echo " POST-MAINTENANCE VALIDATION SUMMARY"
echo "============================================================"

validation_failed=false

if [[ "$api_ok" == true ]]; then
  echo "PASS: API /readyz - $api_detail"
else
  echo "FAIL: API /readyz - $api_detail"
  validation_failed=true
fi

if [[ "$node_ok" == true ]]; then
  echo "PASS: Target node - $node_detail"
else
  echo "FAIL: Target node - $node_detail"
  validation_failed=true
fi

if [[ "$cilium_ok" == true ]]; then
  echo "PASS: Cilium - $cilium_detail"
else
  echo "FAIL: Cilium - $cilium_detail"
  validation_failed=true
fi

if [[ "$NODE_TYPE" == "control-plane" ]]; then
  if [[ "$vip_ok" == true ]]; then
    echo "PASS: kube-vip - $vip_detail"
  else
    echo "FAIL: kube-vip - $vip_detail"
    validation_failed=true
  fi
else
  echo "SKIP: kube-vip - $vip_detail"
fi

if [[ "$longhorn_ok" == true ]]; then
  echo "PASS: Longhorn volumes - $longhorn_detail"
else
  echo "FAIL: Longhorn volumes - $longhorn_detail"
  validation_failed=true
fi

if [[ "$validation_failed" == true ]]; then
  echo
  echo "POST-MAINTENANCE VALIDATION: FAIL"
  exit 1
fi

echo
echo "POST-MAINTENANCE VALIDATION: PASS"

echo
echo "===== QUICK REPOSITORY DOCTOR ====="

set +e
"$ROOT_DIR/repo-doctor.sh" --quick
DOCTOR_RC=$?
set -e

if [[ "$DOCTOR_RC" -eq 1 ]]; then
  fail "post-maintenance repository doctor found a failure"
fi

echo
echo "============================================================"
echo " SINGLE-NODE MAINTENANCE COMPLETE"
echo "============================================================"
echo "Node: $target_name ($TARGET)"
echo "Type: $NODE_TYPE"
