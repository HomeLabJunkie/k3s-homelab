#!/usr/bin/env bash
set -Eeuo pipefail

MANIFEST=""
OUTPUT="recovery/generated-latest-bindings.yaml"
APPLY=0
KUBECTL="${KUBECTL:-kubectl}"
LONGHORN_NS="${LONGHORN_NS:-longhorn-system}"

usage() {
    cat <<'EOF'
Usage:
  dr-bind-restores.sh --manifest FILE [--output FILE] [--apply]

Required:
  -m, --manifest FILE   Generated Longhorn restore manifest.

Options:
  -o, --output FILE     Generated PV/PVC binding manifest.
                        Default: recovery/generated-latest-bindings.yaml
  --apply               Apply bindings after explicit BIND confirmation.
  -h, --help            Show help.

Safety:
  Default mode only GENERATES bindings.
  --apply requires restored Longhorn volumes to already exist.
  --apply requires typing BIND exactly.
  PV reclaimPolicy is Retain.
  This script never starts application workloads.
EOF
}

while (( $# )); do
    case "$1" in
        -m|--manifest) MANIFEST="${2:?missing manifest}"; shift 2 ;;
        -o|--output) OUTPUT="${2:?missing output}"; shift 2 ;;
        --apply) APPLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$MANIFEST" ]] || { echo "ERROR: --manifest is required" >&2; exit 2; }
[[ -f "$MANIFEST" ]] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 2; }

command -v awk >/dev/null || { echo "ERROR: awk is required" >&2; exit 2; }

mapping() {
    case "$1" in
        dr-restore-logging-loki)            printf '%s\t%s\n' logging loki-dr ;;
        dr-restore-monitoring-alertmanager) printf '%s\t%s\n' monitoring alertmanager-dr ;;
        dr-restore-monitoring-grafana)      printf '%s\t%s\n' monitoring grafana-dr ;;
        dr-restore-monitoring-prometheus)   printf '%s\t%s\n' monitoring prometheus-dr ;;
        dr-restore-portainer)               printf '%s\t%s\n' portainer portainer-dr ;;
        dr-restore-trilium)                 printf '%s\t%s\n' trilium trilium-dr ;;
        dr-restore-vaultwarden)             printf '%s\t%s\n' vaultwarden vaultwarden-dr ;;
        *) return 1 ;;
    esac
}

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Extract Volume name + byte size from the generated Longhorn restore YAML.
awk '
  /^kind:[[:space:]]*Volume[[:space:]]*$/ { in_volume=1; name=""; size=""; next }
  in_volume && /^metadata:[[:space:]]*$/ { in_meta=1; next }
  in_volume && in_meta && /^[[:space:]]+name:[[:space:]]*/ && name=="" {
      line=$0; sub(/^[[:space:]]+name:[[:space:]]*/, "", line); gsub(/"/, "", line); name=line; next
  }
  in_volume && /^spec:[[:space:]]*$/ { in_meta=0; in_spec=1; next }
  in_volume && in_spec && /^[[:space:]]+size:[[:space:]]*/ {
      line=$0; sub(/^[[:space:]]+size:[[:space:]]*/, "", line); gsub(/"/, "", line); size=line
  }
  /^---[[:space:]]*$/ {
      if (in_volume && name!="" && size!="") print name "\t" size
      in_volume=0; in_meta=0; in_spec=0; name=""; size=""
  }
  END {
      if (in_volume && name!="" && size!="") print name "\t" size
  }
' "$MANIFEST" > "$TMP"

[[ -s "$TMP" ]] || { echo "ERROR: no Longhorn restore volumes found" >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT")"
: > "$OUTPUT"

COUNT=0
while IFS=$'\t' read -r VOL BYTES; do
    [[ "$BYTES" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid size for $VOL: $BYTES" >&2; exit 1; }

    if ! MAP="$(mapping "$VOL")"; then
        echo "ERROR: no PV/PVC mapping defined for $VOL" >&2
        exit 1
    fi
    IFS=$'\t' read -r NS PVC <<< "$MAP"

    PV="${PVC}-pv"
    SIZE_GI=$(( (BYTES + 1073741823) / 1073741824 ))

    (( COUNT += 1 ))

    (( COUNT == 1 )) || printf '%s\n' '---' >> "$OUTPUT"
    cat >> "$OUTPUT" <<EOF
# Restored Longhorn volume: $VOL
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $PV
spec:
  capacity:
    storage: ${SIZE_GI}Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: $VOL
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  namespace: $NS
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  storageClassName: longhorn
  volumeName: $PV
  resources:
    requests:
      storage: ${SIZE_GI}Gi
EOF
done < "$TMP"

echo "============================================================"
echo " K3S HOMELAB DR RESTORE BINDING GENERATOR"
echo "============================================================"
echo
echo "Input:    $MANIFEST"
echo "Output:   $OUTPUT"
echo "Bindings: $COUNT"
echo
echo "Generated PV/PVC mappings:"
grep -E '^# Restored|^  name:|^  namespace:' "$OUTPUT" || true

if (( APPLY == 0 )); then
    echo
    echo "GENERATION COMPLETE"
    echo "No Kubernetes resources were applied."
    exit 0
fi

echo
echo "===== APPLY PREFLIGHT ====="
$KUBECTL get --raw='/readyz' >/dev/null
echo "PASS: Kubernetes API ready"

while IFS=$'\t' read -r VOL BYTES; do
    if ! $KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$VOL" >/dev/null 2>&1; then
        echo "ERROR: restored Longhorn volume does not exist: $VOL" >&2
        exit 1
    fi
    echo "PASS: $VOL exists"
done < "$TMP"

echo
echo "WARNING: this will create $COUNT static PV/PVC bindings."
echo "It will NOT start applications."
printf 'Type BIND exactly to continue: '
read -r CONFIRM
if [[ "$CONFIRM" != "BIND" ]]; then
    echo "Confirmation not received. Nothing was applied."
    exit 0
fi

$KUBECTL apply -f "$OUTPUT"

echo
echo "BINDINGS APPLIED"
echo "Restored Longhorn data remains protected by PV reclaimPolicy=Retain."
