#!/usr/bin/env bash

# Shared helpers for accessing the cluster-backup NFS export through a K3s
# control-plane node. The ThinkPad needs no local sudo access: it stages files
# locally and uses the node's existing passwordless administrative SSH channel
# only for the NFS mount and root-owned backup files.

STORAGE_SSH_HOST="${STORAGE_SSH_HOST:-}"
STORAGE_MOUNT="${STORAGE_MOUNT:-${MOUNT:-/mnt/k3s-backup}}"
NFS_VERSION="${NFS_VERSION:-${BACKUP_NFS_VERSION:-4.2}}"
STORAGE_MOUNTED_BY_SCRIPT=0
STORAGE_SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=10)

storage_fail() {
    echo "ERROR: $*" >&2
    return 1
}

storage_validate_value() {
    local label="$1" value="$2" pattern="$3"
    [[ "$value" =~ $pattern ]] || storage_fail "unsafe ${label} value: ${value}"
}

storage_init() {
    local control_node

    if [[ -z "$STORAGE_SSH_HOST" ]]; then
        control_node="$(
            kubectl get nodes -l node-role.kubernetes.io/control-plane \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
            sort | head -1
        )"
        [[ -n "$control_node" ]] || storage_fail "no control-plane node found"
        STORAGE_SSH_HOST="$(
            kubectl get node "$control_node" \
                -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
        )"
    fi

    storage_validate_value "storage SSH host" "$STORAGE_SSH_HOST" '^[A-Za-z0-9._:-]+$'
    storage_validate_value "NAS host" "$NAS" '^[A-Za-z0-9._:-]+$'
    storage_validate_value "NFS export" "$EXPORT" '^/[A-Za-z0-9._/-]+$'
    storage_validate_value "storage mount" "$STORAGE_MOUNT" '^/[A-Za-z0-9._/-]+$'
    storage_validate_value "NFS version" "$NFS_VERSION" '^(3|4|4[.]0|4[.]1|4[.]2)$'

    ssh "${STORAGE_SSH_OPTIONS[@]}" "$STORAGE_SSH_HOST" \
        'sudo -n true' >/dev/null ||
        storage_fail "passwordless sudo is unavailable on storage proxy ${STORAGE_SSH_HOST}"
}

storage_command() {
    local command_string="" quoted arg
    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        command_string+="${command_string:+ }${quoted}"
    done
    ssh "${STORAGE_SSH_OPTIONS[@]}" "$STORAGE_SSH_HOST" "$command_string"
}

storage_sudo() {
    storage_command sudo -n -- "$@"
}

storage_root_script() {
    local command_string='sudo -n bash -s --' quoted arg
    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        command_string+=" ${quoted}"
    done
    ssh "${STORAGE_SSH_OPTIONS[@]}" "$STORAGE_SSH_HOST" "$command_string"
}

storage_replace_symlink() {
    local target="$1" link_path="$2"
    storage_root_script "$target" "$link_path" <<'REMOTE'
set -Eeuo pipefail
target="$1"
link_path="$2"
link_dir="$(dirname -- "$link_path")"
link_name="$(basename -- "$link_path")"
temporary_link="${link_dir}/.${link_name}.tmp.$$"
trap 'rm -f -- "$temporary_link"' EXIT
ln -s -- "$target" "$temporary_link"
mv -Tf -- "$temporary_link" "$link_path"
REMOTE
}

storage_restore_symlink_if_current() {
    local link_path="$1" expected_target="$2" previous_target="$3"
    storage_root_script "$link_path" "$expected_target" "$previous_target" <<'REMOTE'
set -Eeuo pipefail
link_path="$1"
expected_target="$2"
previous_target="$3"
current_target="$(readlink -- "$link_path" 2>/dev/null || true)"

# A different publisher won the race; its link must not be overwritten.
[[ "$current_target" == "$expected_target" ]] || exit 0

if [[ -z "$previous_target" ]]; then
    rm -f -- "$link_path"
    exit 0
fi

link_dir="$(dirname -- "$link_path")"
link_name="$(basename -- "$link_path")"
temporary_link="${link_dir}/.${link_name}.rollback.$$"
trap 'rm -f -- "$temporary_link"' EXIT
ln -s -- "$previous_target" "$temporary_link"
mv -Tf -- "$temporary_link" "$link_path"
REMOTE
}

storage_mount() {
    local state
    state="$(
        storage_root_script "$STORAGE_MOUNT" "$NAS" "$EXPORT" "$NFS_VERSION" <<'REMOTE'
set -Eeuo pipefail
mount_point="$1"
nas="$2"
export_path="$3"
nfs_version="$4"
mkdir -p "$mount_point"
if mountpoint -q "$mount_point"; then
    source="$(findmnt -n -o SOURCE --target "$mount_point")"
    [[ "$source" == "${nas}:${export_path}" ]] || {
        echo "ERROR: ${mount_point} is mounted from unexpected source ${source}" >&2
        exit 1
    }
    printf '%s\n' existing
else
    mount -t nfs -o "vers=${nfs_version},proto=tcp" "${nas}:${export_path}" "$mount_point"
    printf '%s\n' mounted
fi
REMOTE
    )"
    case "$state" in
        mounted) STORAGE_MOUNTED_BY_SCRIPT=1 ;;
        existing) STORAGE_MOUNTED_BY_SCRIPT=0 ;;
        *) storage_fail "unexpected mount result from ${STORAGE_SSH_HOST}: ${state}" ;;
    esac
}

storage_unmount() {
    if (( STORAGE_MOUNTED_BY_SCRIPT == 1 )); then
        storage_sudo umount "$STORAGE_MOUNT" || true
        STORAGE_MOUNTED_BY_SCRIPT=0
    fi
}
