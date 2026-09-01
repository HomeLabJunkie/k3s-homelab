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

REPO="${REPO:-$ROOT_DIR}"
REPO="$(readlink -f "$REPO")"
NAS="${NAS:-${UNRAID_IP:-192.0.2.9}}"
EXPORT="${EXPORT:-${CLUSTER_BACKUP_EXPORT:-/mnt/user/K3S-Backup}}"
HOST="$(hostname -s)"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${STORAGE_MOUNT}/cluster/${HOST}/${STAMP}"
BACKUP_KEEP_COUNT="${BACKUP_KEEP_COUNT:-14}"
LOCK_FILE="${LOCK_FILE:-/tmp/k3s-dr-backup.lock}"

STAGE_ROOT=""
STAGE_DEST=""
REMOTE_DEST_CREATED=0
BACKUP_COMPLETE=0
SNAPSHOT=""
CONTROL_IP=""

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

on_error() {
    local rc=$? line="${BASH_LINENO[0]:-unknown}"
    echo >&2
    echo "ERROR: backup failed at line ${line} with exit code ${rc}" >&2
    echo "ERROR: latest backup symlink was not updated." >&2
    return "$rc"
}

cleanup() {
    local rc=$?
    if (( rc != 0 || BACKUP_COMPLETE == 0 )) &&
       (( REMOTE_DEST_CREATED == 1 )) &&
       [[ "$DEST" == "${STORAGE_MOUNT}/cluster/${HOST}/"* ]]; then
        echo "==> Removing incomplete remote backup bundle:"
        echo "    $DEST"
        storage_sudo rm -rf -- "$DEST" || true
    fi
    storage_unmount
    if [[ -n "$STAGE_ROOT" && "$STAGE_ROOT" == /tmp/k3s-dr-backup.* ]]; then
        rm -rf -- "$STAGE_ROOT"
    fi
    return "$rc"
}

trap on_error ERR
trap cleanup EXIT

prune_cluster_bundles() {
    local bundle_root="${STORAGE_MOUNT}/cluster/${HOST}" old
    local -a bundles=()
    [[ "$BACKUP_KEEP_COUNT" =~ ^[0-9]+$ ]] ||
        fail "BACKUP_KEEP_COUNT must be a non-negative integer"
    (( BACKUP_KEEP_COUNT > 0 )) || return 0

    mapfile -t bundles < <(
        storage_sudo find "$bundle_root" -mindepth 1 -maxdepth 1 -type d \
            -name '20????????-??????' -printf '%f\n' 2>/dev/null | sort -r
    )
    (( ${#bundles[@]} > BACKUP_KEEP_COUNT )) || return 0

    echo "==> Pruning old cluster bundles; keeping newest ${BACKUP_KEEP_COUNT}..."
    for old in "${bundles[@]:BACKUP_KEEP_COUNT}"; do
        [[ "$old" =~ ^20[0-9]{6}-[0-9]{6}$ ]] ||
            fail "refusing to prune unexpected bundle name: $old"
        echo "    deleting ${old}"
        storage_sudo rm -rf -- "${bundle_root}/${old}"
    done
}

echo "============================================"
echo " K3S CLUSTER RECOVERY BACKUP"
echo "============================================"
echo
echo "Host:       $HOST"
echo "Repository: $REPO"
echo "NAS:        ${NAS}:${EXPORT}"
echo "Proxy:      auto-selected control-plane node"
echo

[[ -d "$REPO/.git" ]] || fail "repository path is not a Git working tree: $REPO"
for command in kubectl helm ssh tar sha256sum flock find readlink mktemp python3; do
    require_command "$command"
done

exec 9>"$LOCK_FILE"
flock -n 9 || fail "another backup.sh instance is already running"

echo "==> Checking Kubernetes..."
kubectl get --raw='/readyz' >/dev/null || fail "Kubernetes API is not ready"
kubectl get nodes >/dev/null || fail "unable to query Kubernetes nodes"
NOT_READY="$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print}')"
if [[ -n "$NOT_READY" ]]; then
    echo "$NOT_READY" >&2
    fail "one or more Kubernetes nodes are not Ready"
fi

echo "==> Checking Longhorn backup target..."
AVAILABLE="$(kubectl -n longhorn-system get backuptarget default -o jsonpath='{.status.available}')"
[[ "$AVAILABLE" == true ]] || fail "Longhorn backup target is unavailable"

CONTROL_NODE="$(
    kubectl get nodes -l node-role.kubernetes.io/control-plane \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | head -1
)"
[[ -n "$CONTROL_NODE" ]] || fail "no control-plane node found"
CONTROL_IP="$(
    kubectl get node "$CONTROL_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
)"
[[ -n "$CONTROL_IP" ]] || fail "could not determine control-plane InternalIP"

STORAGE_SSH_HOST="${STORAGE_SSH_HOST:-$CONTROL_IP}"
storage_init || fail "unable to initialize remote backup storage"
echo "    node: $CONTROL_NODE ($CONTROL_IP)"

STAGE_ROOT="$(mktemp -d /tmp/k3s-dr-backup.XXXXXX)"
STAGE_DEST="${STAGE_ROOT}/${STAMP}"
mkdir -p "$STAGE_DEST/repo" "$STAGE_DEST/cluster-state" "$STAGE_DEST/etcd"
chmod 700 "$STAGE_ROOT"

echo "==> Staging repository backup locally..."
REPO_PARENT="$(dirname "$REPO")"
REPO_NAME="$(basename "$REPO")"
tar --exclude='.git' --exclude='logs' --exclude='*.tmp' \
    --exclude='recovery/state/*/archive' -C "$REPO_PARENT" \
    -czf "$STAGE_DEST/repo/k3s-repository.tar.gz" "$REPO_NAME"
[[ -s "$STAGE_DEST/repo/k3s-repository.tar.gz" ]] ||
    fail "repository archive was not created"

echo "==> Saving cluster state..."
kubectl get nodes -o yaml >"$STAGE_DEST/cluster-state/nodes.yaml"
kubectl get namespaces -o yaml >"$STAGE_DEST/cluster-state/namespaces.yaml"
kubectl get storageclass -o yaml >"$STAGE_DEST/cluster-state/storageclasses.yaml"
kubectl get pv -o yaml >"$STAGE_DEST/cluster-state/persistentvolumes.yaml"
kubectl get pvc -A -o yaml >"$STAGE_DEST/cluster-state/persistentvolumeclaims.yaml"
kubectl get ingress -A -o yaml >"$STAGE_DEST/cluster-state/ingresses.yaml"
kubectl get pvc -A \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,VOLUME:.spec.volumeName,SC:.spec.storageClassName,STATUS:.status.phase' \
    >"$STAGE_DEST/cluster-state/pvc-volume-map.txt"
kubectl -n longhorn-system get volumes.longhorn.io -o yaml >"$STAGE_DEST/cluster-state/longhorn-volumes.yaml"
kubectl -n longhorn-system get backups.longhorn.io -o yaml >"$STAGE_DEST/cluster-state/longhorn-backups.yaml"
kubectl -n longhorn-system get backupvolumes.longhorn.io -o yaml >"$STAGE_DEST/cluster-state/longhorn-backupvolumes.yaml"
kubectl -n longhorn-system get backuptarget default -o yaml >"$STAGE_DEST/cluster-state/longhorn-backuptarget.yaml"
kubectl -n longhorn-system get recurringjobs.longhorn.io -o yaml >"$STAGE_DEST/cluster-state/longhorn-recurringjobs.yaml"
kubectl -n longhorn-system get systembackups.longhorn.io -o yaml \
    >"$STAGE_DEST/cluster-state/longhorn-systembackups.yaml" 2>/dev/null || true
helm list -A -o yaml >"$STAGE_DEST/cluster-state/helm-releases.yaml"

echo "==> Requesting K3s etcd snapshot..."
ssh "${STORAGE_SSH_OPTIONS[@]}" "$CONTROL_IP" \
    "sudo -n k3s etcd-snapshot save --name manual-${STAMP}"
SNAPSHOT="$(
    ssh "${STORAGE_SSH_OPTIONS[@]}" "$CONTROL_IP" \
        "sudo -n find /var/lib/rancher/k3s/server/db/snapshots -maxdepth 1 -type f -name 'manual-${STAMP}*' -printf '%f\\n'" |
    head -1
)"
[[ "$SNAPSHOT" =~ ^manual-${STAMP}[-A-Za-z0-9._]*$ ]] ||
    fail "etcd snapshot was not found or had an unexpected name"
echo "    snapshot: $SNAPSHOT"
ssh "${STORAGE_SSH_OPTIONS[@]}" "$CONTROL_IP" \
    "sudo -n cat '/var/lib/rancher/k3s/server/db/snapshots/${SNAPSHOT}'" \
    >"$STAGE_DEST/etcd/$SNAPSHOT"
[[ -s "$STAGE_DEST/etcd/$SNAPSHOT" ]] || fail "copied etcd snapshot is empty"

echo "==> Creating backup manifest..."
KUBERNETES_VERSION="$(
    kubectl version -o json 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("serverVersion",{}).get("gitVersion","unknown"))' \
        2>/dev/null || echo unknown
)"
LONGHORN_TARGET="$(kubectl -n longhorn-system get backuptarget default -o jsonpath='{.spec.backupTargetURL}')"
cat >"$STAGE_DEST/BACKUP-MANIFEST.txt" <<EOF
created_at=$(date -Iseconds)
host=${HOST}
repository=${REPO}
repository_name=${REPO_NAME}
kubernetes_server=${KUBERNETES_VERSION}
longhorn_target=${LONGHORN_TARGET}
control_node=${CONTROL_NODE}
control_ip=${CONTROL_IP}
etcd_snapshot=${SNAPSHOT}
backup_keep_count=${BACKUP_KEEP_COUNT}
storage_proxy=${STORAGE_SSH_HOST}
EOF

echo "==> Creating and verifying checksums..."
(
    cd "$STAGE_DEST"
    find . -type f ! -name SHA256SUMS -exec sha256sum {} \; >SHA256SUMS
    tar -tzf repo/k3s-repository.tar.gz >/dev/null
    sha256sum -c SHA256SUMS >/dev/null
)

echo "==> Publishing completed bundle to Unraid through ${STORAGE_SSH_HOST}..."
storage_mount
storage_sudo mkdir -p "$DEST"
REMOTE_DEST_CREATED=1
tar -C "$STAGE_DEST" -cf - . | storage_sudo tar -C "$DEST" -xf -
storage_root_script "$DEST" <<'REMOTE'
set -Eeuo pipefail
destination="$1"
cd "$destination"
tar -tzf repo/k3s-repository.tar.gz >/dev/null
sha256sum -c SHA256SUMS >/dev/null
test -s BACKUP-MANIFEST.txt
test -s cluster-state/pvc-volume-map.txt
find etcd -maxdepth 1 -type f -size +0c -print -quit | grep -q .
REMOTE

storage_sudo ln -sfn "${HOST}/${STAMP}" "${STORAGE_MOUNT}/cluster/latest"
LATEST_RESOLVED="$(storage_sudo readlink -f "${STORAGE_MOUNT}/cluster/latest")"
[[ "$LATEST_RESOLVED" == "$DEST" ]] || fail "latest symlink does not resolve to new bundle"

BACKUP_COMPLETE=1
prune_cluster_bundles

echo "==> Removing copied on-demand etcd snapshot from control node..."
if ! ssh "${STORAGE_SSH_OPTIONS[@]}" "$CONTROL_IP" \
    "sudo -n k3s etcd-snapshot delete '${SNAPSHOT}'" >/dev/null 2>&1; then
    echo "WARNING: unable to delete control-node snapshot ${SNAPSHOT}."
    echo "WARNING: backup on Unraid is intact."
fi

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
