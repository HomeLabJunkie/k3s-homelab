# K3s Backup Procedures

This runbook covers creating, checking, and verifying backups for the existing
production cluster. Backups use two complementary layers; both are required for
a complete recovery point.

## Backup layers

| Layer | Protects | Destination | Primary command |
| --- | --- | --- | --- |
| Longhorn backups | Persistent application data | Configured Longhorn NFS backup target | Longhorn `backup-nightly` job |
| Cluster recovery bundle | Repository, Kubernetes state, Helm inventory, and etcd | Configured cluster-backup NFS export | `./backup/backup.sh` |

The cluster recovery bundle records Longhorn metadata but does not replace the
Longhorn application-data backups. Verify both layers before relying on a
recovery point.

## Recommended backup order

1. Confirm the cluster and Longhorn backup target are healthy.
2. Trigger or confirm fresh Longhorn backups for protected workloads.
3. Check protected-workload backup coverage with `dr-status.sh`.
4. Create the cluster recovery bundle with `backup/backup.sh`.
5. Verify the bundle with `backup/verify-backup.sh`.
6. Run `dr-status.sh` again and require a DR-ready result.

## Prerequisites

Work from the repository virtual environment:

```bash
cd ~/Work/k3s-homelab
echo "$VIRTUAL_ENV"
command -v kubectl
```

Confirm these local values are correct in `config/cluster.env`:

```text
UNRAID_IP
CLUSTER_BACKUP_EXPORT
LONGHORN_BACKUP_EXPORT
```

The backup host also needs:

- working cluster-admin `kubectl` access
- `helm`, `ssh`, `tar`, `sha256sum`, `flock`, and NFS client tools
- passwordless SSH key authentication to the Kubernetes control-plane nodes
- `sudo` authorization for the NFS mount and root-owned backup files
- network access to the configured NAS exports

The backup script refuses to run when the Kubernetes API is unavailable, any
node is not Ready, the Longhorn target is unavailable, another backup process
holds the lock, or a required command is missing.

## 1. Preflight the cluster and backup target

```bash
kubectl get --raw=/readyz
kubectl get nodes -o wide
kubectl -n longhorn-system get backuptarget default -o wide
kubectl -n longhorn-system get recurringjobs.longhorn.io
```

Required state:

- `/readyz` returns `ok`
- every Kubernetes node is `Ready`
- Longhorn BackupTarget `default` reports `AVAILABLE=true`
- the expected Longhorn recurring jobs exist

Current recurring-job policy:

| Job | Schedule | Retention | Purpose |
| --- | --- | --- | --- |
| `snapshot-6hour` | Minute 17, every 6 hours | 12 | Local Longhorn snapshots |
| `backup-nightly` | Daily at 02:37 | 14 | Longhorn volume backups |
| `system-backup-nightly` | Daily at 04:20 | 7 | Longhorn system backups |

## 2. Create or confirm Longhorn application backups

Longhorn normally creates application backups through the `backup-nightly`
recurring job. To request an immediate run:

```bash
JOB="manual-backup-nightly-$(date +%Y%m%d-%H%M%S)"

kubectl -n longhorn-system create job \
  --from=cronjob/backup-nightly \
  "$JOB"

kubectl -n longhorn-system wait \
  --for=condition=complete \
  --timeout=3h \
  job/"$JOB"
```

Inspect the job if it does not complete:

```bash
kubectl -n longhorn-system describe job "$JOB"
kubectl -n longhorn-system logs job/"$JOB" --all-containers
```

Check completed Longhorn backups:

```bash
kubectl -n longhorn-system get backups.longhorn.io
kubectl -n longhorn-system get backupvolumes.longhorn.io
```

Then verify that every workload listed in `recovery/apps.conf` has a fresh
backup:

```bash
./dr-status.sh
```

The protected-workload section must report zero stale and missing backups:

```text
Stale backups:       0
Missing backups:     0
```

By default, `dr-status.sh` considers cluster bundles and protected application
backups fresh for 30 hours. It returns:

| Exit code | Result |
| --- | --- |
| `0` | `RESULT: DR READY` |
| `1` | `RESULT: DR NOT READY` |
| `2` | `RESULT: DR READY WITH WARNINGS` |

Do not proceed as though the recovery point is complete when protected
workloads are stale or missing.

## 3. Create the cluster recovery bundle

Run:

```bash
./backup/backup.sh
```

The script:

1. Validates Kubernetes and Longhorn health.
2. Mounts the configured cluster-backup NFS export when necessary.
3. Archives the repository while excluding Git history and runtime logs.
4. Captures Kubernetes nodes, namespaces, storage, ingress, Longhorn, and Helm
   state.
5. Requests an on-demand K3s etcd snapshot from the first control-plane node.
6. Copies the etcd snapshot into the recovery bundle.
7. Creates `BACKUP-MANIFEST.txt` and `SHA256SUMS`.
8. Verifies the repository archive and every checksum.
9. Updates the `cluster/latest` symlink only after the bundle is complete.
10. Keeps the newest 14 cluster bundles by default.

Success ends with:

```text
RESULT: BACKUP PASSED
```

The bundle path is:

```text
<cluster-backup-mount>/cluster/<backup-host>/YYYYMMDD-HHMMSS/
```

Its main contents are:

```text
BACKUP-MANIFEST.txt
SHA256SUMS
repo/k3s-repository.tar.gz
etcd/<snapshot-file>
cluster-state/
```

If the run fails, the script removes the incomplete destination and does not
update `cluster/latest`. A completed bundle on the NAS remains intact even if
cleanup of the temporary control-plane snapshot later reports a warning.

## 4. Verify the latest cluster bundle

Run verification immediately after every manual backup and as a separate
scheduled check:

```bash
./backup/verify-backup.sh
```

The verifier mounts the cluster-backup export if needed and checks:

- the `cluster/latest` symlink resolves to a bundle
- `BACKUP-MANIFEST.txt` exists and contains `created_at`
- bundle age is no more than 30 hours by default
- every SHA256 checksum matches
- the repository archive can be listed by `tar`
- a nonempty etcd snapshot exists
- the PVC-to-volume map exists
- the Longhorn backup target is available
- at least one completed Longhorn backup is visible

Success ends with:

```text
BACKUP VERIFICATION PASSED
```

Treat any nonzero exit status as a failed verification. Do not repair the
`latest` symlink manually until the cause is understood and a complete bundle
has been verified.

## 5. Run the complete DR readiness check

After Longhorn backups and the cluster bundle both pass:

```bash
./dr-status.sh
```

This read-only dashboard additionally checks:

- repository and protected-workload inventory
- production API and node readiness
- cluster-bundle verification and freshness
- Longhorn target and completed backup visibility
- fresh backup coverage for every protected PVC
- restore capacity plus configured headroom
- passwordless SSH to the DR host
- DR-host preflight and Longhorn capacity

The preferred final state is:

```text
RESULT: DR READY
```

Review every warning before accepting `DR READY WITH WARNINGS`. Any
`DR NOT READY` result means the backup/restore chain is not currently ready.

## Manual inspection and troubleshooting

### Inspect the current bundle

`backup/verify-backup.sh` prints the resolved latest path. After it mounts the
export, the equivalent checks are:

```bash
readlink -f /mnt/k3s-backup/cluster/latest
sudo cat /mnt/k3s-backup/cluster/latest/BACKUP-MANIFEST.txt
sudo find /mnt/k3s-backup/cluster/latest -maxdepth 2 -type f
```

Use the verifier for checksum validation instead of checking only that files
exist.

### Inspect recent backup output

For a manual run, retain its terminal output. For systemd user services:

```bash
systemctl --user status k3s-dr-backup.service --no-pager
systemctl --user status k3s-dr-verify.service --no-pager
journalctl --user -u k3s-dr-backup.service --since today
journalctl --user -u k3s-dr-verify.service --since today
```

### Common failure checks

```bash
kubectl get --raw=/readyz
kubectl get nodes
kubectl -n longhorn-system get backuptarget default -o yaml
kubectl -n longhorn-system get backups.longhorn.io
mountpoint /mnt/k3s-backup
ssh -o BatchMode=yes <CONTROL_PLANE_IP> true
```

Typical causes are an unavailable NAS export, stale or failed Longhorn backups,
a non-Ready node, failed SSH/sudo access to the control plane, an expired bundle,
or a checksum mismatch.

## Scheduled operation

The repository contains user-systemd units with this intended order:

| Time | Unit | Action |
| --- | --- | --- |
| 02:37 | Longhorn `backup-nightly` | Back up application volumes |
| 04:20 | Longhorn `system-backup-nightly` | Create Longhorn system backup |
| 04:30 plus random delay | `k3s-dr-backup.timer` | Create cluster recovery bundle |
| 05:15 plus random delay | `k3s-dr-verify.timer` | Verify the latest bundle |
| 05:30 plus random delay | `k3s-dr-monitor.timer` | Check DR health and notifications |

Check timer state with:

```bash
systemctl --user list-timers 'k3s-dr-*' --all
systemctl --user is-enabled k3s-dr-backup.timer k3s-dr-verify.timer
systemctl --user is-active k3s-dr-backup.timer k3s-dr-verify.timer
```

The current unit and installer files assume a checkout under `%h/k3s` (and the
monitor unit currently references `%h/k3s-git`). If the repository is checked
out elsewhere, such as `~/Work/k3s-homelab`, do not enable the timers until
their paths are updated and reviewed. Manual backup and verification remain the
canonical procedure in that situation.

Scheduled execution also requires non-interactive, narrowly scoped sudo for the
NFS and backup operations. `install-dr-timers.sh` refuses to enable timers when
`sudo -n true` fails. Never place a sudo password in a unit file or repository.

## Retention and freshness overrides

The defaults can be overridden for a single command when necessary:

```bash
BACKUP_KEEP_COUNT=21 ./backup/backup.sh
MAX_BACKUP_AGE_HOURS=36 ./backup/verify-backup.sh
MAX_APP_BACKUP_AGE_HOURS=36 ./dr-status.sh
```

Defaults:

- cluster recovery bundles retained: 14
- maximum cluster-bundle age: 30 hours
- maximum protected application-backup age: 30 hours
- Longhorn nightly volume backups retained: 14
- Longhorn nightly system backups retained: 7

Use overrides deliberately. Increasing an age limit does not make an old backup
safer; it only changes the readiness threshold.

## Restore documentation

Backup verification proves that the source artifacts are present, fresh, and
internally consistent. Restore readiness also depends on the DR host and tested
restore workflow. Before any restore or rehearsal, read:

```text
recovery/DR-RUNBOOK.md
```

Start with the non-destructive readiness and planning commands. Do not run an
executing restore or cleanup command solely from this backup runbook.
