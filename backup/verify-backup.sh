#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(basename "$ROOT_DIR")" == "backup" || "$(basename "$ROOT_DIR")" == "recovery" ]]; then
  ROOT_DIR="$(dirname "$ROOT_DIR")"
fi
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi


NAS="${NAS:-${UNRAID_IP:-192.0.2.9}}"
EXPORT="${EXPORT:-${CLUSTER_BACKUP_EXPORT:-/mnt/user/K3S-Backup}}"
MOUNT="${MOUNT:-/mnt/k3s-backup}"
MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-30}"
MOUNTED_BY_SCRIPT=0

cleanup() {
  cd /
  if [[ "$MOUNTED_BY_SCRIPT" == "1" ]] && mountpoint -q "$MOUNT" 2>/dev/null; then
    sudo umount "$MOUNT" || true
  fi
}
trap cleanup EXIT

sudo mkdir -p "$MOUNT"
if ! mountpoint -q "$MOUNT"; then
  sudo mount -t nfs4 -o vers=4.2,proto=tcp "${NAS}:${EXPORT}" "$MOUNT"
  MOUNTED_BY_SCRIPT=1
fi

LATEST="$(readlink -f "${MOUNT}/cluster/latest")"
[[ -d "$LATEST" ]] || { echo "ERROR: No latest backup found."; exit 1; }

echo "==> Latest backup:"
echo "$LATEST"

sudo test -s "$LATEST/BACKUP-MANIFEST.txt" || { echo "ERROR: BACKUP-MANIFEST.txt missing."; exit 1; }
CREATED_AT="$(
  sudo awk -F= '$1=="created_at"{print substr($0,index($0,"=")+1)}'     "$LATEST/BACKUP-MANIFEST.txt"
)"
[[ -n "$CREATED_AT" ]] || { echo "ERROR: created_at missing from manifest."; exit 1; }

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
sudo bash -c '
  cd "$1"
  sha256sum -c SHA256SUMS
' _ "$LATEST"

echo
echo "==> Checking repository archive..."
sudo tar -tzf "$LATEST/repo/k3s-repository.tar.gz" >/dev/null

echo "==> Checking etcd snapshot..."
ETCD="$(sudo find "$LATEST/etcd" -maxdepth 1 -type f | head -1)"
[[ -n "$ETCD" ]] && sudo test -s "$ETCD" || {
  echo "ERROR: etcd snapshot missing."
  exit 1
}

echo "==> Checking PVC volume map..."
sudo test -s "$LATEST/cluster-state/pvc-volume-map.txt"

echo
echo "==> Checking Longhorn backup target..."
AVAILABLE="$(kubectl -n longhorn-system get backuptarget default -o jsonpath='{.status.available}')"
[[ "$AVAILABLE" == "true" ]] || { echo "ERROR: Longhorn backup target unavailable."; exit 1; }
kubectl -n longhorn-system get backuptarget default -o wide

echo
echo "==> Checking Longhorn completed backups..."
COMPLETED="$(
  kubectl -n longhorn-system get backups.longhorn.io -o json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for x in d.get("items",[]) if x.get("status",{}).get("state")=="Completed"))'
)"
echo "Completed Longhorn backups: $COMPLETED"
(( COMPLETED > 0 )) || { echo "ERROR: no completed Longhorn backups found."; exit 1; }

echo
echo "============================================"
echo " BACKUP VERIFICATION PASSED"
echo "============================================"
