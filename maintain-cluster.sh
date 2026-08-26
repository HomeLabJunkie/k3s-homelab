#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR}"
INVENTORY="${INVENTORY:-$ROOT_DIR/inventory/k3s-ansible/hosts.ini}"
NODE_SCRIPT="${NODE_SCRIPT:-$ROOT_DIR/maintain-node.sh}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs/maintenance}"

APPLY=false
ASSUME_YES=false

fail() {
  echo
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./maintain-cluster.sh
  ./maintain-cluster.sh --apply
  ./maintain-cluster.sh --apply --yes

Behavior:
  - discovers worker and control-plane targets from the Ansible inventory
  - processes workers first, then control-plane nodes
  - runs exactly one node at a time through maintain-node.sh
  - defaults to check-only and makes no node changes
  - stops immediately when any node fails
  - writes a timestamped log and prints a final per-node summary

Safety:
  Live execution requires --apply and cluster-level confirmation.
  --yes is available only with --apply for explicit unattended execution.
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
    *)
      fail "unknown option: $1"
      ;;
  esac
done

if [[ "$ASSUME_YES" == true && "$APPLY" != true ]]; then
  fail "--yes is only valid with --apply"
fi

cd "$ROOT_DIR"

for cmd in ansible-inventory python3 tee; do
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
done

[[ -r "$INVENTORY" ]] || fail "inventory is missing: $INVENTORY"
[[ -x "$NODE_SCRIPT" ]] || fail "node maintenance script is not executable: $NODE_SCRIPT"

inventory_json="$(mktemp)"
trap 'rm -f "$inventory_json"' EXIT

if ! ansible-inventory -i "$INVENTORY" --list >"$inventory_json"; then
  fail "ansible-inventory could not render the inventory"
fi

mapfile -t targets < <(
  python3 - "$inventory_json" <<'PY_INVENTORY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    inventory = json.load(f)

def hosts(group):
    value = inventory.get(group, {})
    if isinstance(value, dict):
        return list(value.get("hosts", []) or [])
    return []

workers = hosts("node")
masters = hosts("master")

duplicates = sorted(set(workers) & set(masters))
if duplicates:
    print("ERROR: targets appear in both node and master: " + ", ".join(duplicates), file=sys.stderr)
    raise SystemExit(1)

if not workers:
    print("ERROR: inventory node group is empty", file=sys.stderr)
    raise SystemExit(1)

if not masters:
    print("ERROR: inventory master group is empty", file=sys.stderr)
    raise SystemExit(1)

for host in workers:
    print(f"worker\t{host}")
for host in masters:
    print(f"control-plane\t{host}")
PY_INVENTORY
)

(( ${#targets[@]} > 0 )) || fail "no maintenance targets were discovered"

rm -f "$inventory_json"
trap - EXIT

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/maintain-cluster-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo " K3S ROLLING CLUSTER MAINTENANCE"
echo "============================================================"
echo
echo "Mode:    $([[ "$APPLY" == true ]] && echo apply || echo check-only)"
echo "Log:     $LOG_FILE"
echo "Targets: ${#targets[@]}"
echo

for entry in "${targets[@]}"; do
  IFS=$'\t' read -r node_type target <<<"$entry"
  printf '  %-14s %s\n' "$node_type" "$target"
done

if [[ "$APPLY" == true ]]; then
  echo
  echo "===== APPLY AUTHORIZATION ====="
  if [[ "$ASSUME_YES" == true ]]; then
    echo "Explicit --apply --yes supplied; continuing non-interactively."
  else
    echo "This will reconcile all listed nodes sequentially."
    read -r -p "Type APPLY CLUSTER to continue: " confirmation
    [[ "$confirmation" == "APPLY CLUSTER" ]] ||
      fail "confirmation did not match; no cluster maintenance was run"
  fi
fi

declare -a completed=()
failed_target=""
failed_type=""
failed_rc=0

for entry in "${targets[@]}"; do
  IFS=$'\t' read -r node_type target <<<"$entry"

  echo
  echo "============================================================"
  echo " START: $target ($node_type)"
  echo "============================================================"

  args=("$target")
  if [[ "$APPLY" == true ]]; then
    args+=(--apply --yes)
  fi

  set +e
  "$NODE_SCRIPT" "${args[@]}"
  rc=$?
  set -e

  if (( rc != 0 )); then
    failed_target="$target"
    failed_type="$node_type"
    failed_rc=$rc
    echo
    echo "FAIL: $target ($node_type) exited with status $rc"
    break
  fi

  completed+=("$node_type"$'\t'"$target")
  echo
  echo "PASS: $target ($node_type)"
done

echo
echo "============================================================"
echo " ROLLING MAINTENANCE SUMMARY"
echo "============================================================"

for entry in "${completed[@]}"; do
  IFS=$'\t' read -r node_type target <<<"$entry"
  echo "PASS: $target ($node_type)"
done

if [[ -n "$failed_target" ]]; then
  echo "FAIL: $failed_target ($failed_type), exit status $failed_rc"
  echo "SKIP: remaining nodes were not processed"
  echo
  echo "ROLLING CLUSTER MAINTENANCE: FAIL"
  echo "Log: $LOG_FILE"
  exit "$failed_rc"
fi

echo
echo "ROLLING CLUSTER MAINTENANCE: PASS"
echo "Log: $LOG_FILE"
