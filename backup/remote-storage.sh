#!/usr/bin/env bash

# Shared helpers for accessing the cluster-backup NFS export through a K3s
# control-plane node. The ThinkPad needs no local sudo access: it stages files
# locally and uses the node's existing passwordless administrative SSH channel
# only for the NFS mount and root-owned backup files.

STORAGE_SSH_HOST="${STORAGE_SSH_HOST:-}"
STORAGE_MOUNT="${STORAGE_MOUNT:-${MOUNT:-/mnt/k3s-backup}}"
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

storage_mount() {
    local state
    state="$(
        storage_root_script "$STORAGE_MOUNT" "$NAS" "$EXPORT" <<'REMOTE'
set -Eeuo pipefail
mount_point="$1"
nas="$2"
export_path="$3"
mkdir -p "$mount_point"
if mountpoint -q "$mount_point"; then
    printf '%s\n' existing
else
    mount -t nfs4 -o vers=4.2,proto=tcp "${nas}:${export_path}" "$mount_point"
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
