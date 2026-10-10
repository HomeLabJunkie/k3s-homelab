#!/usr/bin/env bash
set -Eeuo pipefail

# Runs on the DR hypervisor, as root. Copies the NAS backup share into a ZFS
# dataset and snapshots it, so there is a second copy of the cluster bundles
# and Longhorn backups, with history. The NAS is mounted read-only.
#
# Settings come from /etc/k3s-backup-replicate.env:
#   NAS_EXPORT    <nas-address>:<export path>
#   NFS_VERSION   NFS protocol version of that export. Default: 3
#   DATASET       ZFS dataset to replicate into. Default: tank/backup/k3s
#   EXCLUDES      Space-separated top-level names to leave out.
#   KEEP          Snapshots to keep. Default: 14

# shellcheck disable=SC1091
source /etc/k3s-backup-replicate.env
: "${NAS_EXPORT:?NAS_EXPORT is not set}"
NFS_VERSION="${NFS_VERSION:-3}"
DATASET="${DATASET:-tank/backup/k3s}"
EXCLUDES="${EXCLUDES:-}"
KEEP="${KEEP:-14}"
MOUNT=/mnt/nas-k3s-backup

[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: KEEP must be a positive integer" >&2; exit 1; }
destination="$(zfs get -H -o value mountpoint "$DATASET")"
[[ "$destination" == /* ]] || { echo "ERROR: $DATASET has no mountpoint" >&2; exit 1; }

exec 9>/run/k3s-backup-replicate.lock
flock -n 9 || { echo "another replication is already running"; exit 0; }

mkdir -p "$MOUNT"
if ! mountpoint -q "$MOUNT"; then
  mount -t nfs -o "ro,vers=${NFS_VERSION},proto=tcp" "$NAS_EXPORT" "$MOUNT"
fi
trap 'umount "$MOUNT" 2>/dev/null || true' EXIT

# An empty source would make --delete wipe the copy.
[[ -n "$(find "$MOUNT" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
  { echo "ERROR: $NAS_EXPORT is empty; refusing to replicate" >&2; exit 1; }

exclude_args=()
for name in $EXCLUDES; do
  exclude_args+=("--exclude=/$name")
done

ionice -c3 nice rsync -aH --numeric-ids --delete --info=stats1 \
  "${exclude_args[@]}" "$MOUNT/" "$destination/data/"

zfs snapshot "${DATASET}@replica-$(date -u +%Y%m%d-%H%M%S)"
mapfile -t snapshots < <(zfs list -H -t snapshot -o name -s creation "$DATASET" | grep '@replica-')
if (( ${#snapshots[@]} > KEEP )); then
  for snapshot in "${snapshots[@]:0:${#snapshots[@]}-KEEP}"; do
    zfs destroy "$snapshot"
  done
fi
echo "replication complete: $(zfs list -H -o used "$DATASET") used, ${#snapshots[@]} replica snapshot(s) before pruning"
