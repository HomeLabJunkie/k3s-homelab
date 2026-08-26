#!/usr/bin/env bash

set -u
set -o pipefail

KUBECTL="${KUBECTL:-kubectl}"
LONGHORN_NS="${LONGHORN_NS:-longhorn-system}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PVCS="$TMPDIR/pvcs.json"
PVS="$TMPDIR/pvs.json"
BACKUPS="$TMPDIR/backups.json"

PASS=0
WARN=0

pass() {
    printf 'PASS: %s\n' "$*"
    PASS=$((PASS + 1))
}

warn() {
    printf 'WARN: %s\n' "$*"
    WARN=$((WARN + 1))
}

echo "============================================================"
echo " K3S HOMELAB DR BACKUP INVENTORY"
echo "============================================================"
echo
echo "Date:    $(date)"
echo "Context: $($KUBECTL config current-context 2>/dev/null || echo unknown)"
echo

echo "===== CLUSTER ACCESS ====="

if ! $KUBECTL get --raw='/readyz' >/dev/null 2>&1; then
    echo "FAIL: Kubernetes API is not ready or cannot be reached."
    exit 1
fi

pass "Kubernetes API reachable"

echo
echo "===== LONGHORN BACKUP TARGET ====="

TARGET_AVAILABLE=$(
    $KUBECTL -n "$LONGHORN_NS" get backuptarget default \
        -o jsonpath='{.status.available}' 2>/dev/null || true
)

TARGET_URL=$(
    $KUBECTL -n "$LONGHORN_NS" get backuptarget default \
        -o jsonpath='{.spec.backupTargetURL}' 2>/dev/null || true
)

if [[ "$TARGET_AVAILABLE" == "true" ]]; then
    pass "Longhorn backup target available"
else
    echo "FAIL: Longhorn backup target is not available."
    exit 1
fi

echo "Target: ${TARGET_URL:-unknown}"

echo
echo "===== READING CLUSTER STORAGE STATE ====="

if ! $KUBECTL get pvc -A -o json > "$PVCS"; then
    echo "FAIL: Unable to read PVCs."
    exit 1
fi

if ! $KUBECTL get pv -o json > "$PVS"; then
    echo "FAIL: Unable to read PVs."
    exit 1
fi

if ! $KUBECTL -n "$LONGHORN_NS" get backups.longhorn.io \
        -o json > "$BACKUPS"; then
    echo "FAIL: Unable to read Longhorn backups."
    exit 1
fi

pass "PVC/PV/Longhorn backup state loaded"

echo
echo "===== PERSISTENT VOLUME BACKUP INVENTORY ====="
echo

printf '%-15s %-32s %-40s %-8s %-25s %-22s\n' \
    "NAMESPACE" \
    "PVC" \
    "LONGHORN VOLUME" \
    "SIZE" \
    "LATEST BACKUP" \
    "BACKUP TIME"

printf '%-15s %-32s %-40s %-8s %-25s %-22s\n' \
    "---------------" \
    "--------------------------------" \
    "----------------------------------------" \
    "--------" \
    "-------------------------" \
    "----------------------"

TOTAL_BYTES=0
PVC_COUNT=0
BACKED_UP=0
NO_BACKUP=0

while IFS=$'\t' read -r NS PVC PV SIZE; do

    [[ -z "$PV" || "$PV" == "null" ]] && continue

    DRIVER=$(
        jq -r \
            --arg PV "$PV" \
            '.items[]
             | select(.metadata.name==$PV)
             | .spec.csi.driver // ""' \
            "$PVS"
    )

    [[ "$DRIVER" != "driver.longhorn.io" ]] && continue

    VOLUME=$(
        jq -r \
            --arg PV "$PV" \
            '.items[]
             | select(.metadata.name==$PV)
             | .spec.csi.volumeHandle // ""' \
            "$PVS"
    )

    [[ -z "$VOLUME" ]] && continue

    CAPACITY=$(
        jq -r \
            --arg PV "$PV" \
            '.items[]
             | select(.metadata.name==$PV)
             | .spec.capacity.storage // "0"' \
            "$PVS"
    )

    BYTES=$(
        awk -v S="$CAPACITY" '
          BEGIN {
            if (S ~ /^[0-9]+Ki$/) {
              sub(/Ki$/, "", S)
              print S * 1024
            }
            else if (S ~ /^[0-9]+Mi$/) {
              sub(/Mi$/, "", S)
              print S * 1024 * 1024
            }
            else if (S ~ /^[0-9]+Gi$/) {
              sub(/Gi$/, "", S)
              print S * 1024 * 1024 * 1024
            }
            else if (S ~ /^[0-9]+Ti$/) {
              sub(/Ti$/, "", S)
              print S * 1024 * 1024 * 1024 * 1024
            }
            else if (S ~ /^[0-9]+$/) {
              print S
            }
            else {
              print 0
            }
          }
        '
    )

    if [[ "$BYTES" =~ ^[0-9]+$ ]]; then
        TOTAL_BYTES=$((TOTAL_BYTES + BYTES))
    fi

    PVC_COUNT=$((PVC_COUNT + 1))

    BACKUP_LINE=$(
        jq -r \
            --arg V "$VOLUME" '
              [
                .items[]
                | select(
                    .status.volumeName==$V
                    and .status.state=="Completed"
                    and (.status.snapshotCreatedAt != null)
                  )
                | {
                    name: .metadata.name,
                    time: .status.snapshotCreatedAt,
                    url:  .status.url
                  }
              ]
              | sort_by(.time)
              | last
              | if . == null then
                    ""
                else
                    [.name, .time, .url] | @tsv
                end
            ' "$BACKUPS"
    )

    BACKUP_NAME="-"
    BACKUP_TIME="-"
    BACKUP_URL=""

    if [[ -n "$BACKUP_LINE" ]]; then
        IFS=$'\t' read -r \
            BACKUP_NAME BACKUP_TIME BACKUP_URL <<< "$BACKUP_LINE"

        BACKED_UP=$((BACKED_UP + 1))
    else
        NO_BACKUP=$((NO_BACKUP + 1))
    fi

    printf '%-15s %-32s %-40s %-8s %-25s %-22s\n' \
        "$NS" \
        "$PVC" \
        "$VOLUME" \
        "$SIZE" \
        "$BACKUP_NAME" \
        "$BACKUP_TIME"

    {
        echo "NAMESPACE=$NS"
        echo "PVC=$PVC"
        echo "PV=$PV"
        echo "VOLUME=$VOLUME"
        echo "SIZE=$SIZE"
        echo "BACKUP=$BACKUP_NAME"
        echo "BACKUP_TIME=$BACKUP_TIME"
        echo "BACKUP_URL=$BACKUP_URL"
        echo
    } >> "$TMPDIR/details"

done < <(
    jq -r '
      .items[]
      | select(.status.phase=="Bound")
      | [
          .metadata.namespace,
          .metadata.name,
          .spec.volumeName,
          .status.capacity.storage
        ]
      | @tsv
    ' "$PVCS" |
    sort
)

echo
echo "===== SUMMARY ====="

TOTAL_GIB=$(
    awk -v B="$TOTAL_BYTES" \
        'BEGIN { printf "%.1f", B / 1073741824 }'
)

echo "Longhorn PVCs:       $PVC_COUNT"
echo "With backup:         $BACKED_UP"
echo "Without backup:      $NO_BACKUP"
echo "Provisioned storage: ${TOTAL_GIB} GiB"

if (( PVC_COUNT == 0 )); then
    warn "No Longhorn-backed PVCs discovered"
elif (( NO_BACKUP == 0 )); then
    pass "Every Longhorn PVC has at least one completed backup"
else
    warn "$NO_BACKUP Longhorn PVC(s) have no completed backup"
fi

echo
echo "===== LATEST RESTORE URLS ====="

if [[ -f "$TMPDIR/details" ]]; then

    while IFS= read -r LINE; do

        case "$LINE" in
            NAMESPACE=*)
                NS="${LINE#NAMESPACE=}"
                ;;

            PVC=*)
                PVC="${LINE#PVC=}"
                ;;

            BACKUP=*)
                BACKUP="${LINE#BACKUP=}"
                ;;

            BACKUP_URL=*)
                URL="${LINE#BACKUP_URL=}"

                if [[ -n "$URL" ]]; then
                    echo
                    echo "$NS / $PVC"
                    echo "Backup: $BACKUP"
                    echo "URL:    $URL"
                fi
                ;;
        esac

    done < "$TMPDIR/details"

fi

echo
echo "============================================================"

if (( NO_BACKUP == 0 && PVC_COUNT > 0 )); then
    echo " DR BACKUP INVENTORY PASSED"
    RC=0
else
    echo " DR BACKUP INVENTORY COMPLETED WITH WARNINGS"
    RC=2
fi

echo "============================================================"

exit "$RC"
