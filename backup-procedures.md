# K3s Backup Procedures

This runbook covers creating, checking, and verifying backups for the existing
production cluster. Backups use three complementary layers; all are required for
a complete recovery point.

## Backup layers

| Layer | Protects | Destination | Primary command |
| --- | --- | --- | --- |
| Velero CSI Data Mover | Independent application data and Kubernetes resources | Dedicated RustFS `k3s-velero` bucket | `protected-apps-daily` schedule |
| Longhorn backups | Persistent application data | Configured Longhorn NFS backup target | Longhorn `backup-nightly` job |
| Cluster recovery bundle | Repository, Kubernetes state, Helm inventory, and etcd | Configured cluster-backup NFS export | `./backup/backup.sh` |

The cluster recovery bundle records storage metadata but does not replace either
application-data path. Velero/RustFS is independent from Longhorn/NFS; verify all
three layers before relying on a recovery point. See
[Velero backup procedures](velero-backup-procedures.md) for installation, restore
testing, and troubleshooting.

## Recommended backup order

1. Confirm the cluster, Longhorn NFS target, and Velero RustFS location are healthy.
2. Trigger or confirm a completed Velero backup for `protected-apps-daily`.
3. Trigger or confirm fresh Longhorn backups for protected workloads.
4. Check protected-workload backup coverage with `dr-status.sh`.
5. Create the cluster recovery bundle with `backup/backup.sh`.
6. Verify the bundle with `backup/verify-backup.sh`.
7. Run `dr-status.sh` again and require a DR-ready result.

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
- `helm`, `ssh`, `tar`, `sha256sum`, and `flock`
- passwordless SSH key authentication to the Kubernetes control-plane nodes
- passwordless `sudo` on the selected control-plane node for K3s and NFS tasks
- network access to the configured NAS exports

The ThinkPad does not need local `sudo`. It stages each bundle under a private
temporary directory, then uses the first control-plane node as a narrowly
scoped storage proxy to publish and verify the root-owned NFS copy. Temporary
staging data is removed after success or failure.

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

The verifier accesses the cluster-backup export through the same control-plane
storage proxy and checks:

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

`backup/verify-backup.sh` prints the resolved remote path. Inspect it through a
control-plane node when manual inspection is required:

```bash
ssh <CONTROL_PLANE_IP> sudo readlink -f /mnt/k3s-backup/cluster/latest
ssh <CONTROL_PLANE_IP> sudo cat /mnt/k3s-backup/cluster/latest/BACKUP-MANIFEST.txt
ssh <CONTROL_PLANE_IP> sudo find /mnt/k3s-backup/cluster/latest -maxdepth 2 -type f
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
ssh -o BatchMode=yes <CONTROL_PLANE_IP> sudo -n true
```

Typical causes are an unavailable NAS export, stale or failed Longhorn backups,
a non-Ready node, failed SSH/sudo access to the control plane, an expired bundle,
or a checksum mismatch.

## Scheduled operation

The repository contains user-systemd units with this intended order:

| Time | Unit | Action |
| --- | --- | --- |
| 01:17 America/Chicago | Velero `protected-apps-daily` | Move application snapshots to RustFS |
| 02:37 | Longhorn `backup-nightly` | Back up application volumes |
| 04:20 | Longhorn `system-backup-nightly` | Create Longhorn system backup |
| 04:30 plus random delay | `k3s-dr-backup.timer` | Create cluster recovery bundle |
| 05:15 plus random delay | `k3s-dr-verify.timer` | Verify the latest bundle |
| 05:30 plus random delay | `k3s-dr-monitor.timer` | Check DR health and notifications |

Check timer state with:

```bash
systemctl --user list-timers 'k3s-dr-*' --all
systemctl --user is-enabled k3s-dr-backup.timer k3s-dr-verify.timer k3s-dr-monitor.timer
systemctl --user is-active k3s-dr-backup.timer k3s-dr-verify.timer k3s-dr-monitor.timer
```

Install all three timers from the ThinkPad checkout:

```bash
cd ~/Work/k3s-homelab
./install-dr-timers.sh
```

The units use `%h/Work/k3s-homelab`, require no local sudo, and are persistent.
If the user manager was stopped at a scheduled time, systemd starts the missed
job when the user session returns. Enable user lingering once if backups must
run while logged out; a powered-off ThinkPad catches up after the next login.

The monitor validates the bundle itself and warns at 24 hours, before the
30-hour DR freshness limit. It also checks every protected Longhorn backup,
timer enablement, timer activity, and failed backup/verification services.

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
