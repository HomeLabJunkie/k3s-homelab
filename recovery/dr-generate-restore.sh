#!/usr/bin/env bash

set -Eeuo pipefail

KUBECTL="${KUBECTL:-kubectl}"
LONGHORN_NS="${LONGHORN_NS:-longhorn-system}"
REPLICAS="${REPLICAS:-1}"
NAME_PREFIX="${NAME_PREFIX:-dr-restore-}"
OUTPUT="${OUTPUT:-}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PVCS="$TMPDIR/pvcs.json"
PVS="$TMPDIR/pvs.json"
BACKUPS="$TMPDIR/backups.json"
OUT="$TMPDIR/restore.yaml"

usage() {
    cat <<'EOF'
Usage:
  dr-generate-restore.sh [options]

Options:
  -o, --output FILE     Write generated YAML to FILE.
                        Default: print YAML to stdout.
  -r, --replicas N      Longhorn replica count for restored volumes.
                        Default: 1
  -p, --prefix PREFIX   Prefix for generated restore volume names.
                        Default: dr-restore-
  -h, --help            Show this help.

Environment overrides:
  KUBECTL        Kubernetes CLI command. Default: kubectl
  LONGHORN_NS    Longhorn namespace. Default: longhorn-system
  REPLICAS       Replica count. Default: 1
  NAME_PREFIX    Restore-volume name prefix. Default: dr-restore-
  OUTPUT         Output file path.

Safety:
  This script is read-only with respect to Kubernetes.
  It generates YAML only. It never runs kubectl apply/create/patch/delete.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        -o|--output)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 2; }
            OUTPUT="$2"
            shift 2
            ;;
        -r|--replicas)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 2; }
            REPLICAS="$2"
            shift 2
            ;;
        -p|--prefix)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 2; }
            NAME_PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! [[ "$REPLICAS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: replicas must be a positive integer." >&2
    exit 2
fi

sanitize_name() {
    local raw="$1"

    raw="${raw,,}"
    raw="$(printf '%s' "$raw" \
        | sed -E 's/[^a-z0-9.-]+/-/g; s/^[^a-z0-9]+//; s/[^a-z0-9]+$//; s/-+/-/g')"

    if (( ${#raw} > 180 )); then
        local digest
        digest="$(printf '%s' "$raw" | sha256sum | awk '{print substr($1,1,10)}')"
        raw="${raw:0:168}-${digest}"
        raw="${raw%-}"
    fi

    printf '%s\n' "$raw"
}

restore_basename() {
    local ns="$1"
    local pvc="$2"

    case "${ns}/${pvc}" in
        logging/storage-loki-0)
            printf '%s\n' "logging-loki"
            ;;
        monitoring/alertmanager-monitoring-kube-prometheus-alertmanager-db-alertmanager-monitoring-kube-prometheus-alertmanager-0)
            printf '%s\n' "monitoring-alertmanager"
            ;;
        monitoring/monitoring-grafana)
            printf '%s\n' "monitoring-grafana"
            ;;
        monitoring/prometheus-monitoring-kube-prometheus-prometheus-db-prometheus-monitoring-kube-prometheus-prometheus-0)
            printf '%s\n' "monitoring-prometheus"
            ;;
        portainer/portainer)
            printf '%s\n' "portainer"
            ;;
        trilium/trilium-data)
            printf '%s\n' "trilium"
            ;;
        vaultwarden/vaultwarden-data)
            printf '%s\n' "vaultwarden"
            ;;
        *)
            sanitize_name "${ns}-${pvc}"
            ;;
    esac
}

echo "Reading Kubernetes storage state..." >&2

if ! $KUBECTL get --raw='/readyz' >/dev/null 2>&1; then
    echo "ERROR: Kubernetes API is not ready or cannot be reached." >&2
    exit 1
fi

TARGET_AVAILABLE="$(
    $KUBECTL -n "$LONGHORN_NS" get backuptarget default \
        -o jsonpath='{.status.available}' 2>/dev/null || true
)"

if [[ "$TARGET_AVAILABLE" != "true" ]]; then
    echo "ERROR: Longhorn backup target is not available." >&2
    exit 1
fi

$KUBECTL get pvc -A -o json > "$PVCS"
$KUBECTL get pv -o json > "$PVS"
$KUBECTL -n "$LONGHORN_NS" get backups.longhorn.io -o json > "$BACKUPS"

: > "$OUT"

COUNT=0
TOTAL_BYTES=0
MISSING=0

while IFS=$'\t' read -r NS PVC PV PVC_SIZE; do
    [[ -z "$PV" || "$PV" == "null" ]] && continue

    DRIVER="$(
        jq -r \
            --arg PV "$PV" \
            '.items[]
             | select(.metadata.name==$PV)
             | .spec.csi.driver // ""' \
            "$PVS"
    )"

    [[ "$DRIVER" != "driver.longhorn.io" ]] && continue

    SOURCE_VOLUME="$(
        jq -r \
            --arg PV "$PV" \
            '.items[]
             | select(.metadata.name==$PV)
             | .spec.csi.volumeHandle // ""' \
            "$PVS"
    )"

    [[ -n "$SOURCE_VOLUME" ]] || continue

    BACKUP_JSON="$(
        jq -c \
            --arg V "$SOURCE_VOLUME" '
              [
                .items[]
                | select(
                    .status.volumeName==$V
                    and .status.state=="Completed"
                    and (.status.snapshotCreatedAt != null)
                    and (.status.url != null)
                  )
              ]
              | sort_by(.status.snapshotCreatedAt)
              | last // empty
            ' "$BACKUPS"
    )"

    if [[ -z "$BACKUP_JSON" ]]; then
        echo "WARNING: No completed backup found for $NS/$PVC ($SOURCE_VOLUME)." >&2
        MISSING=$((MISSING + 1))
        continue
    fi

    BACKUP_NAME="$(jq -r '.metadata.name' <<< "$BACKUP_JSON")"
    BACKUP_TIME="$(jq -r '.status.snapshotCreatedAt' <<< "$BACKUP_JSON")"
    BACKUP_URL="$(jq -r '.status.url' <<< "$BACKUP_JSON")"
    BACKUP_SIZE="$(jq -r '.status.volumeSize' <<< "$BACKUP_JSON")"

    if ! [[ "$BACKUP_SIZE" =~ ^[0-9]+$ ]]; then
        echo "WARNING: Invalid backup size for $NS/$PVC: $BACKUP_SIZE" >&2
        MISSING=$((MISSING + 1))
        continue
    fi

    BASE_NAME="$(restore_basename "$NS" "$PVC")"
    RESTORE_NAME="$(sanitize_name "${NAME_PREFIX}${BASE_NAME}")"

    if (( COUNT > 0 )); then
        printf -- '---\n' >> "$OUT"
    fi

    cat >> "$OUT" <<EOF
# Source namespace: $NS
# Source PVC:       $PVC
# Source PV:        $PV
# Longhorn volume:  $SOURCE_VOLUME
# Backup:           $BACKUP_NAME
# Backup created:   $BACKUP_TIME
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: $RESTORE_NAME
  namespace: $LONGHORN_NS
spec:
  size: "$BACKUP_SIZE"
  fromBackup: "$BACKUP_URL"
  numberOfReplicas: $REPLICAS
  frontend: blockdev
  dataEngine: v1
EOF

    COUNT=$((COUNT + 1))
    TOTAL_BYTES=$((TOTAL_BYTES + BACKUP_SIZE))

done < <(
    jq -r '
      .items[]
      | select(.status.phase=="Bound")
      | [
          .metadata.namespace,
          .metadata.name,
          .spec.volumeName,
          (.status.capacity.storage // "")
        ]
      | @tsv
    ' "$PVCS" | sort
)

if (( COUNT == 0 )); then
    echo "ERROR: No restorable Longhorn-backed PVCs were found." >&2
    exit 1
fi

TOTAL_GIB="$(
    awk -v B="$TOTAL_BYTES" \
        'BEGIN { printf "%.1f", B / 1073741824 }'
)"

{
    echo
    echo "# ------------------------------------------------------------"
    echo "# Generated restore summary"
    echo "# ------------------------------------------------------------"
    echo "# Restore volumes: $COUNT"
    echo "# Total backup size: ${TOTAL_GIB} GiB"
    echo "# Missing completed backups: $MISSING"
    echo "# Replica count: $REPLICAS"
    echo "#"
    echo "# SAFETY:"
    echo "# Review this file before applying it."
    echo "# This generator does not apply any resources."
} >> "$OUT"

if [[ -n "$OUTPUT" ]]; then
    mkdir -p "$(dirname "$OUTPUT")"
    cp "$OUT" "$OUTPUT"

    echo "Generated: $OUTPUT" >&2
    echo "Restore volumes: $COUNT" >&2
    echo "Total backup size: ${TOTAL_GIB} GiB" >&2
    echo "Missing completed backups: $MISSING" >&2
else
    cat "$OUT"
fi

if (( MISSING > 0 )); then
    exit 2
fi
