#!/usr/bin/env bash
set -Eeuo pipefail

KUBECTL="${KUBECTL:-kubectl}"
LONGHORN_NS="${LONGHORN_NS:-longhorn-system}"
POLL_SECONDS="${POLL_SECONDS:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"

usage() {
    cat <<'EOF'
Usage:
  dr-cleanup.sh

Environment overrides:
  KUBECTL          Kubernetes CLI command. Default: kubectl
  LONGHORN_NS      Longhorn namespace. Default: longhorn-system
  POLL_SECONDS     Seconds between detach checks. Default: 5
  TIMEOUT_SECONDS  Max wait per restore volume detach. Default: 600

Safety:
  - Inventories all known DR resources first.
  - Requires typing CLEANUP exactly.
  - Deletes validation Pods/Services/ConfigMaps first.
  - Deletes DR PVCs, then retained DR PVs.
  - Waits for restored Longhorn volumes to detach.
  - Deletes only known dr-restore-* Longhorn volumes.
  - Does not touch Longhorn Backup objects or the backup target.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if (( $# != 0 )); then
    echo "ERROR: This script takes no positional arguments." >&2
    usage >&2
    exit 2
fi

if ! $KUBECTL get --raw='/readyz' >/dev/null 2>&1; then
    echo "ERROR: Kubernetes API is not ready." >&2
    exit 1
fi

VALIDATION_RESOURCES=(
  "trilium pod trilium-dr-validation"
  "trilium service trilium-dr-validation"
  "vaultwarden pod vaultwarden-dr-validation"
  "vaultwarden service vaultwarden-dr-validation"
  "portainer pod portainer-dr-validation"
  "portainer service portainer-dr-validation"
  "monitoring pod grafana-dr-validation"
  "monitoring service grafana-dr-validation"
  "monitoring pod prometheus-dr-validation"
  "monitoring service prometheus-dr-validation"
  "monitoring pod alertmanager-dr-validation"
  "monitoring service alertmanager-dr-validation"
  "monitoring configmap prometheus-dr-validation-config"
  "monitoring configmap alertmanager-dr-validation-config"
  "logging pod loki-dr-validation"
  "logging service loki-dr-validation"
  "logging service loki-dr-validation-memberlist"
  "logging configmap loki-dr-validation-config"
  "logging configmap loki-dr-validation-runtime"
)

PVC_RESOURCES=(
  "logging loki-dr"
  "monitoring alertmanager-dr"
  "monitoring grafana-dr"
  "monitoring prometheus-dr"
  "portainer portainer-dr"
  "trilium trilium-dr"
  "vaultwarden vaultwarden-dr"
)

PV_RESOURCES=(
  "loki-dr-pv"
  "alertmanager-dr-pv"
  "grafana-dr-pv"
  "prometheus-dr-pv"
  "portainer-dr-pv"
  "trilium-dr-pv"
  "vaultwarden-dr-pv"
)

LH_VOLUMES=(
  "dr-restore-logging-loki"
  "dr-restore-monitoring-alertmanager"
  "dr-restore-monitoring-grafana"
  "dr-restore-monitoring-prometheus"
  "dr-restore-portainer"
  "dr-restore-trilium"
  "dr-restore-vaultwarden"
)

echo "============================================================"
echo " K3S HOMELAB DR CLEANUP"
echo "============================================================"
echo
echo "Date: $(date)"
echo

echo "===== INVENTORY: VALIDATION RESOURCES ====="
FOUND=0
for entry in "${VALIDATION_RESOURCES[@]}"; do
    read -r ns kind name <<< "$entry"
    if $KUBECTL -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
        echo "FOUND: $ns $kind $name"
        FOUND=$((FOUND + 1))
    fi
done
(( FOUND > 0 )) || echo "none"

echo
echo "===== INVENTORY: DR PVCs ====="
FOUND=0
for entry in "${PVC_RESOURCES[@]}"; do
    read -r ns name <<< "$entry"
    if $KUBECTL -n "$ns" get pvc "$name" >/dev/null 2>&1; then
        echo "FOUND: $ns/$name"
        FOUND=$((FOUND + 1))
    fi
done
(( FOUND > 0 )) || echo "none"

echo
echo "===== INVENTORY: DR PVs ====="
FOUND=0
for name in "${PV_RESOURCES[@]}"; do
    if $KUBECTL get pv "$name" >/dev/null 2>&1; then
        echo "FOUND: $name"
        FOUND=$((FOUND + 1))
    fi
done
(( FOUND > 0 )) || echo "none"

echo
echo "===== INVENTORY: RESTORED LONGHORN VOLUMES ====="
FOUND=0
for name in "${LH_VOLUMES[@]}"; do
    if $KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$name" >/dev/null 2>&1; then
        state="$($KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$name" \
            -o jsonpath='{.status.state}' 2>/dev/null || true)"
        node="$($KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$name" \
            -o jsonpath='{.status.currentNodeID}' 2>/dev/null || true)"
        echo "FOUND: $name state=${state:-unknown} node=${node:--}"
        FOUND=$((FOUND + 1))
    fi
done
(( FOUND > 0 )) || echo "none"

echo
echo "WARNING:"
echo "This will remove ONLY the known DR validation/binding/restore resources."
echo "Longhorn backups and the backup target are not deleted."
printf 'Type CLEANUP exactly to continue: '
read -r CONFIRM

if [[ "$CONFIRM" != "CLEANUP" ]]; then
    echo
    echo "Confirmation not received. Nothing was deleted."
    exit 0
fi

echo
echo "===== 1. DELETE VALIDATION WORKLOADS ====="
for entry in "${VALIDATION_RESOURCES[@]}"; do
    read -r ns kind name <<< "$entry"
    $KUBECTL -n "$ns" delete "$kind" "$name" \
        --ignore-not-found >/dev/null 2>&1 || true
done
echo "PASS: validation resources deletion requested"

echo
echo "===== 2. DELETE DR PVCs ====="
for entry in "${PVC_RESOURCES[@]}"; do
    read -r ns name <<< "$entry"
    $KUBECTL -n "$ns" delete pvc "$name" \
        --ignore-not-found >/dev/null 2>&1 || true
done
echo "PASS: DR PVC deletion requested"

echo
echo "===== 3. WAIT FOR LONGHORN DETACH ====="
for name in "${LH_VOLUMES[@]}"; do
    if ! $KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$name" >/dev/null 2>&1; then
        echo "$name: not present"
        continue
    fi

    start="$(date +%s)"

    while true; do
        state="$($KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$name" \
            -o jsonpath='{.status.state}' 2>/dev/null || true)"
        node="$($KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$name" \
            -o jsonpath='{.status.currentNodeID}' 2>/dev/null || true)"

        echo "$name: state=${state:-unknown} node=${node:--}"

        if [[ "$state" == "detached" && -z "$node" ]]; then
            break
        fi

        now="$(date +%s)"
        if (( now - start >= TIMEOUT_SECONDS )); then
            echo "ERROR: timed out waiting for $name to detach." >&2
            echo "Cleanup stopped before deleting PVs/Longhorn volume." >&2
            exit 1
        fi

        sleep "$POLL_SECONDS"
    done
done
echo "PASS: all present restored Longhorn volumes detached"

echo
echo "===== 4. DELETE RETAINED DR PVs ====="
for name in "${PV_RESOURCES[@]}"; do
    $KUBECTL delete pv "$name" --ignore-not-found >/dev/null 2>&1 || true
done
echo "PASS: DR PV deletion requested"

echo
echo "===== 5. DELETE RESTORED LONGHORN VOLUMES ====="
for name in "${LH_VOLUMES[@]}"; do
    $KUBECTL -n "$LONGHORN_NS" delete volumes.longhorn.io "$name" \
        --ignore-not-found >/dev/null 2>&1 || true
done
echo "PASS: restored Longhorn volume deletion requested"

echo
echo "===== 6. FINAL CHECK ====="

REMAINING=0

for entry in "${VALIDATION_RESOURCES[@]}"; do
    read -r ns kind name <<< "$entry"
    if $KUBECTL -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
        echo "REMAINS: $ns $kind $name"
        REMAINING=$((REMAINING + 1))
    fi
done

for entry in "${PVC_RESOURCES[@]}"; do
    read -r ns name <<< "$entry"
    if $KUBECTL -n "$ns" get pvc "$name" >/dev/null 2>&1; then
        echo "REMAINS: PVC $ns/$name"
        REMAINING=$((REMAINING + 1))
    fi
done

for name in "${PV_RESOURCES[@]}"; do
    if $KUBECTL get pv "$name" >/dev/null 2>&1; then
        echo "REMAINS: PV $name"
        REMAINING=$((REMAINING + 1))
    fi
done

for name in "${LH_VOLUMES[@]}"; do
    if $KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$name" >/dev/null 2>&1; then
        echo "REMAINS: Longhorn volume $name"
        REMAINING=$((REMAINING + 1))
    fi
done

if (( REMAINING == 0 )); then
    echo
    echo "============================================================"
    echo " DR CLEANUP PASSED"
    echo "============================================================"
    exit 0
fi

echo
echo "============================================================"
echo " DR CLEANUP INCOMPLETE"
echo "============================================================"
echo "Remaining resources: $REMAINING"
exit 1
