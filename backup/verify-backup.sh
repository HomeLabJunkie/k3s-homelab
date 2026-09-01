#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

# shellcheck source=backup/remote-storage.sh
source "$SCRIPT_DIR/remote-storage.sh"

NAS="${NAS:-${UNRAID_IP:-192.0.2.9}}"
EXPORT="${EXPORT:-${CLUSTER_BACKUP_EXPORT:-/mnt/user/K3S-Backup}}"
MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-30}"

cleanup() {
    storage_unmount
}
trap cleanup EXIT

storage_init
storage_mount

LATEST="$(storage_sudo readlink -f "${STORAGE_MOUNT}/cluster/latest")"
storage_sudo test -d "$LATEST" || {
    echo "ERROR: No latest backup found."
    exit 1
}

echo "==> Latest backup:"
echo "$LATEST"

storage_sudo test -s "$LATEST/BACKUP-MANIFEST.txt" || {
    echo "ERROR: BACKUP-MANIFEST.txt missing."
    exit 1
}
MANIFEST="$(storage_sudo cat "$LATEST/BACKUP-MANIFEST.txt")"
CREATED_AT="$(awk -F= '$1=="created_at"{print substr($0,index($0,"=")+1)}' <<<"$MANIFEST")"
[[ -n "$CREATED_AT" ]] || {
    echo "ERROR: created_at missing from manifest."
    exit 1
}

NOW="$(date +%s)"
CREATED_EPOCH="$(date -d "$CREATED_AT" +%s)"
AGE_HOURS=$(( (NOW - CREATED_EPOCH) / 3600 ))
echo "==> Backup age: ${AGE_HOURS}h (max ${MAX_BACKUP_AGE_HOURS}h)"
(( AGE_HOURS <= MAX_BACKUP_AGE_HOURS )) || {
    echo "ERROR: latest cluster backup is too old."
    exit 1
}

echo
echo "==> Verifying SHA256..."
storage_root_script "$LATEST" <<'REMOTE'
set -Eeuo pipefail
cd "$1"
sha256sum -c SHA256SUMS
REMOTE

echo
echo "==> Checking repository archive..."
storage_sudo tar -tzf "$LATEST/repo/k3s-repository.tar.gz" >/dev/null

echo "==> Checking etcd snapshot..."
ETCD="$(storage_sudo find "$LATEST/etcd" -maxdepth 1 -type f -size +0c -print -quit)"
[[ -n "$ETCD" ]] || {
    echo "ERROR: etcd snapshot missing."
    exit 1
}

echo "==> Checking PVC volume map..."
storage_sudo test -s "$LATEST/cluster-state/pvc-volume-map.txt"

echo
echo "==> Checking Longhorn backup target..."
AVAILABLE="$(kubectl -n longhorn-system get backuptarget default -o jsonpath='{.status.available}')"
[[ "$AVAILABLE" == true ]] || {
    echo "ERROR: Longhorn backup target unavailable."
    exit 1
}
kubectl -n longhorn-system get backuptarget default -o wide

echo
echo "==> Checking Longhorn completed backups..."
COMPLETED="$(
    kubectl -n longhorn-system get backups.longhorn.io -o json |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for x in d.get("items",[]) if x.get("status",{}).get("state")=="Completed"))'
)"
echo "Completed Longhorn backups: $COMPLETED"
(( COMPLETED > 0 )) || {
    echo "ERROR: no completed Longhorn backups found."
    exit 1
}

echo
echo "============================================"
echo " BACKUP VERIFICATION PASSED"
echo "============================================"
