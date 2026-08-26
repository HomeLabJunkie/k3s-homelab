#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Repository / environment discovery
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(basename "$SCRIPT_DIR")" == "backup" || "$(basename "$SCRIPT_DIR")" == "recovery" ]]; then
    ROOT_DIR="$(dirname "$SCRIPT_DIR")"
else
    ROOT_DIR="$SCRIPT_DIR"
fi

ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

REPO="${REPO:-$ROOT_DIR}"

# Resolve the repository to an absolute canonical path.
if ! REPO="$(readlink -f "$REPO" 2>/dev/null)"; then
    echo "ERROR: unable to resolve repository path: $REPO" >&2
    exit 1
fi

NAS="${NAS:-${UNRAID_IP:-192.0.2.9}}"
EXPORT="${EXPORT:-${CLUSTER_BACKUP_EXPORT:-/mnt/user/K3S-Backup}}"
MOUNT="${MOUNT:-/mnt/k3s-backup}"

HOST="$(hostname -s)"
STAMP="$(date +%Y%m%d-%H%M%S)"

DEST="${MOUNT}/cluster/${HOST}/${STAMP}"

BACKUP_KEEP_COUNT="${BACKUP_KEEP_COUNT:-14}"
LOCK_FILE="${LOCK_FILE:-/tmp/k3s-dr-backup.lock}"

MOUNTED_BY_SCRIPT=0
DEST_CREATED=0
BACKUP_COMPLETE=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    local cmd="$1"
    local hint="${2:-}"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        if [[ -n "$hint" ]]; then
            fail "required command not found: $cmd ($hint)"
        else
            fail "required command not found: $cmd"
        fi
    fi
}

on_error() {
    local rc=$?
    local line="${BASH_LINENO[0]:-unknown}"

    echo >&2
    echo "ERROR: backup failed at line ${line} with exit code ${rc}" >&2
    echo "ERROR: latest backup symlink was not updated." >&2

    return "$rc"
}

cleanup() {
    local rc=$?

    cd / || true

    # Remove an incomplete destination so a failed run cannot look like
    # a valid recovery bundle.
    if (( rc != 0 || BACKUP_COMPLETE == 0 )) &&
       (( DEST_CREATED == 1 )) &&
       [[ -n "${DEST:-}" ]] &&
       [[ "$DEST" == "${MOUNT}/cluster/${HOST}/"* ]] &&
       [[ -d "$DEST" ]]; then

        echo "==> Removing incomplete backup bundle:"
        echo "    $DEST"
        sudo rm -rf -- "$DEST" || true
    fi

    if [[ "$MOUNTED_BY_SCRIPT" == "1" ]] &&
       mountpoint -q "$MOUNT" 2>/dev/null; then
        echo "==> Unmounting backup target..."
        sudo umount "$MOUNT" || true
    fi

    return "$rc"
}

trap on_error ERR
trap cleanup EXIT

prune_cluster_bundles() {
    [[ "$BACKUP_KEEP_COUNT" =~ ^[0-9]+$ ]] ||
        fail "BACKUP_KEEP_COUNT must be a non-negative integer"

    (( BACKUP_KEEP_COUNT > 0 )) || return 0

    local bundle_root="${MOUNT}/cluster/${HOST}"

    mapfile -t bundles < <(
        find "$bundle_root" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name '20????????-??????' \
            -printf '%f\n' 2>/dev/null |
        sort -r
    )

    if (( ${#bundles[@]} <= BACKUP_KEEP_COUNT )); then
        return 0
    fi

    echo "==> Pruning old cluster bundles; keeping newest ${BACKUP_KEEP_COUNT}..."

    local old
    for old in "${bundles[@]:BACKUP_KEEP_COUNT}"; do
        echo "    deleting ${old}"
        sudo rm -rf -- "${bundle_root}/${old}"
    done
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

echo "============================================"
echo " K3S CLUSTER RECOVERY BACKUP"
echo "============================================"
echo
echo "Host:       $HOST"
echo "Repository: $REPO"
echo "NAS:        ${NAS}:${EXPORT}"
echo "Mount:      $MOUNT"
echo

[[ -d "$REPO" ]] ||
    fail "repository path does not exist: $REPO"

[[ -d "$REPO/.git" ]] ||
    fail "repository path is not a Git working tree: $REPO"

require_command kubectl
require_command helm
require_command ssh
require_command tar
require_command sha256sum
require_command flock
require_command mountpoint
require_command mount
require_command find
require_command readlink
require_command sudo

# mount.nfs/mount.nfs4 is supplied by nfs-utils on Arch/Omarchy.
if ! command -v mount.nfs4 >/dev/null 2>&1 &&
   ! command -v mount.nfs >/dev/null 2>&1; then
    fail "NFS client helper is missing. On Arch/Omarchy install: sudo pacman -S nfs-utils"
fi

# Obtain/validate sudo credentials before doing any real backup work.
sudo -v || fail "sudo authentication failed"

# Prevent concurrent backup runs.
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    fail "another backup.sh instance is already running"
fi

# ---------------------------------------------------------------------------
# Kubernetes / Longhorn preflight
# ---------------------------------------------------------------------------

echo "==> Checking Kubernetes..."

kubectl get --raw='/readyz' >/dev/null ||
    fail "Kubernetes API is not ready"

kubectl get nodes >/dev/null ||
    fail "unable to query Kubernetes nodes"

NOT_READY="$(
    kubectl get nodes --no-headers |
    awk '$2 != "Ready" {print}'
)"

if [[ -n "$NOT_READY" ]]; then
    echo "$NOT_READY" >&2
    fail "one or more Kubernetes nodes are not Ready"
fi

echo "==> Checking Longhorn backup target..."

AVAILABLE="$(
    kubectl -n longhorn-system \
        get backuptarget default \
        -o jsonpath='{.status.available}'
)"

[[ "$AVAILABLE" == "true" ]] ||
    fail "Longhorn backup target is unavailable"

# ---------------------------------------------------------------------------
# Mount backup destination
# ---------------------------------------------------------------------------

echo "==> Mounting Unraid K3S-Backup..."

sudo mkdir -p "$MOUNT"

if ! mountpoint -q "$MOUNT"; then
    sudo mount \
        -t nfs4 \
        -o vers=4.2,proto=tcp \
        "${NAS}:${EXPORT}" \
        "$MOUNT"

    MOUNTED_BY_SCRIPT=1
fi

mountpoint -q "$MOUNT" ||
    fail "backup target is not mounted: $MOUNT"

[[ -d "${MOUNT}/cluster" ]] ||
    sudo mkdir -p "${MOUNT}/cluster"

sudo mkdir -p \
    "${DEST}/repo" \
    "${DEST}/cluster-state" \
    "${DEST}/etcd"

DEST_CREATED=1

# ---------------------------------------------------------------------------
# Repository backup
# ---------------------------------------------------------------------------

echo "==> Backing up repository..."

REPO_PARENT="$(dirname "$REPO")"
REPO_NAME="$(basename "$REPO")"

[[ -d "${REPO_PARENT}/${REPO_NAME}" ]] ||
    fail "resolved repository directory does not exist: ${REPO_PARENT}/${REPO_NAME}"

sudo tar \
    --exclude='.git' \
    --exclude='logs' \
    --exclude='*.tmp' \
    --exclude='recovery/state/*/archive' \
    -C "$REPO_PARENT" \
    -czf "${DEST}/repo/k3s-repository.tar.gz" \
    "$REPO_NAME"

sudo test -s "${DEST}/repo/k3s-repository.tar.gz" ||
    fail "repository archive was not created"

echo "    repository: $REPO"
echo "    archive root: $REPO_NAME"

# ---------------------------------------------------------------------------
# Cluster state
# ---------------------------------------------------------------------------

echo "==> Saving cluster state..."

kubectl get nodes -o yaml |
    sudo tee "${DEST}/cluster-state/nodes.yaml" >/dev/null

kubectl get namespaces -o yaml |
    sudo tee "${DEST}/cluster-state/namespaces.yaml" >/dev/null

kubectl get storageclass -o yaml |
    sudo tee "${DEST}/cluster-state/storageclasses.yaml" >/dev/null

kubectl get pv -o yaml |
    sudo tee "${DEST}/cluster-state/persistentvolumes.yaml" >/dev/null

kubectl get pvc -A -o yaml |
    sudo tee "${DEST}/cluster-state/persistentvolumeclaims.yaml" >/dev/null

kubectl get ingress -A -o yaml |
    sudo tee "${DEST}/cluster-state/ingresses.yaml" >/dev/null

kubectl get pvc -A \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,VOLUME:.spec.volumeName,SC:.spec.storageClassName,STATUS:.status.phase' |
    sudo tee "${DEST}/cluster-state/pvc-volume-map.txt" >/dev/null

kubectl -n longhorn-system get volumes.longhorn.io -o yaml |
    sudo tee "${DEST}/cluster-state/longhorn-volumes.yaml" >/dev/null

kubectl -n longhorn-system get backups.longhorn.io -o yaml |
    sudo tee "${DEST}/cluster-state/longhorn-backups.yaml" >/dev/null

kubectl -n longhorn-system get backupvolumes.longhorn.io -o yaml |
    sudo tee "${DEST}/cluster-state/longhorn-backupvolumes.yaml" >/dev/null

kubectl -n longhorn-system get backuptarget default -o yaml |
    sudo tee "${DEST}/cluster-state/longhorn-backuptarget.yaml" >/dev/null

kubectl -n longhorn-system get recurringjobs.longhorn.io -o yaml |
    sudo tee "${DEST}/cluster-state/longhorn-recurringjobs.yaml" >/dev/null

kubectl -n longhorn-system get systembackups.longhorn.io -o yaml 2>/dev/null |
    sudo tee "${DEST}/cluster-state/longhorn-systembackups.yaml" >/dev/null ||
    true

helm list -A -o yaml |
    sudo tee "${DEST}/cluster-state/helm-releases.yaml" >/dev/null

# ---------------------------------------------------------------------------
# etcd snapshot
# ---------------------------------------------------------------------------

echo "==> Requesting K3s etcd snapshot..."

CONTROL_NODE="$(
    kubectl get nodes \
        -l node-role.kubernetes.io/control-plane \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
    sort |
    head -1
)"

[[ -n "$CONTROL_NODE" ]] ||
    fail "no control-plane node found"

CONTROL_IP="$(
    kubectl get node "$CONTROL_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
)"

[[ -n "$CONTROL_IP" ]] ||
    fail "could not determine InternalIP for control-plane node $CONTROL_NODE"

echo "    node: $CONTROL_NODE ($CONTROL_IP)"

ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$CONTROL_IP" \
    "sudo k3s etcd-snapshot save --name manual-${STAMP}"

SNAPSHOT="$(
    ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "$CONTROL_IP" \
        "sudo find /var/lib/rancher/k3s/server/db/snapshots \
            -maxdepth 1 \
            -type f \
            -name 'manual-${STAMP}*' \
            -printf '%f\n' |
         head -1"
)"

[[ -n "$SNAPSHOT" ]] ||
    fail "etcd snapshot was not found on $CONTROL_NODE"

echo "    snapshot: $SNAPSHOT"

ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$CONTROL_IP" \
    "sudo cat '/var/lib/rancher/k3s/server/db/snapshots/${SNAPSHOT}'" |
    sudo tee "${DEST}/etcd/${SNAPSHOT}" >/dev/null

sudo test -s "${DEST}/etcd/${SNAPSHOT}" ||
    fail "copied etcd snapshot is empty"

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

echo "==> Creating backup manifest..."

KUBERNETES_VERSION="$(
    kubectl version -o json 2>/dev/null |
    python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data.get("serverVersion", {}).get("gitVersion", "unknown"))
' 2>/dev/null ||
    echo unknown
)"

LONGHORN_TARGET="$(
    kubectl -n longhorn-system \
        get backuptarget default \
        -o jsonpath='{.spec.backupTargetURL}'
)"

{
    echo "created_at=$(date -Iseconds)"
    echo "host=${HOST}"
    echo "repository=${REPO}"
    echo "repository_name=${REPO_NAME}"
    echo "kubernetes_server=${KUBERNETES_VERSION}"
    echo "longhorn_target=${LONGHORN_TARGET}"
    echo "control_node=${CONTROL_NODE}"
    echo "control_ip=${CONTROL_IP}"
    echo "etcd_snapshot=${SNAPSHOT}"
    echo "backup_keep_count=${BACKUP_KEEP_COUNT}"
} |
    sudo tee "${DEST}/BACKUP-MANIFEST.txt" >/dev/null

sudo test -s "${DEST}/BACKUP-MANIFEST.txt" ||
    fail "backup manifest was not created"

# ---------------------------------------------------------------------------
# Checksums and archive validation
# ---------------------------------------------------------------------------

echo "==> Creating checksums..."

sudo bash -c '
    set -e
    cd "$1"

    find . \
        -type f \
        ! -name SHA256SUMS \
        -exec sha256sum {} \;
' _ "$DEST" |
    sudo tee "${DEST}/SHA256SUMS" >/dev/null

sudo test -s "${DEST}/SHA256SUMS" ||
    fail "SHA256SUMS was not created"

echo "==> Verifying newly-created repository archive..."

sudo tar -tzf "${DEST}/repo/k3s-repository.tar.gz" >/dev/null ||
    fail "repository archive validation failed"

echo "==> Verifying newly-created checksums..."

sudo bash -c '
    set -e
    cd "$1"
    sha256sum -c SHA256SUMS >/dev/null
' _ "$DEST" ||
    fail "new backup checksum verification failed"

# ---------------------------------------------------------------------------
# Publish bundle
# ---------------------------------------------------------------------------

echo "==> Updating latest symlink..."

sudo ln -sfn \
    "${HOST}/${STAMP}" \
    "${MOUNT}/cluster/latest"

LATEST_RESOLVED="$(
    readlink -f "${MOUNT}/cluster/latest" 2>/dev/null || true
)"

[[ "$LATEST_RESOLVED" == "$DEST" ]] ||
    fail "latest symlink does not resolve to new backup bundle"

# At this point the bundle is complete and published.
BACKUP_COMPLETE=1

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

prune_cluster_bundles

# ---------------------------------------------------------------------------
# Remove temporary etcd snapshot
# ---------------------------------------------------------------------------

echo "==> Removing copied on-demand etcd snapshot from control node..."

if ! ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$CONTROL_IP" \
    "sudo k3s etcd-snapshot delete '${SNAPSHOT}'" >/dev/null 2>&1; then

    echo "WARNING: unable to delete control-node snapshot ${SNAPSHOT}."
    echo "WARNING: backup on Unraid is intact."
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------

echo
echo "============================================"
echo " BACKUP COMPLETE"
echo "============================================"
echo "Destination: $DEST"
echo "Repository:  $REPO"
echo "Longhorn:    AVAILABLE"
echo "etcd:        $SNAPSHOT"
echo
echo "RESULT: BACKUP PASSED"
