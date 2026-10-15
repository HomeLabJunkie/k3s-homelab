# Backups

[Back to the README](../README.md)

What is backed up, where it goes, how to check it, and how to get one
application's data back. Rebuilding the whole cluster is in
[Disaster recovery](disaster-recovery.md).

## What is backed up

Three independent layers. A complete recovery point needs all three fresh.

| Layer | What it holds | Where it goes | When |
| --- | --- | --- | --- |
| **Longhorn backups** | Every Longhorn volume's data | NAS (`BACKUP_NAS_IP`), SMB share `LONGHORN_BACKUP_SHARE` | 02:37 UTC daily, 14 kept |
| **Velero** | The protected apps' volumes and their Kubernetes objects, a second copy | Garage bucket `k3s-velero` on Unraid (`UNRAID_IP`) | 01:47 Chicago daily, 7 days kept |
| **Cluster recovery bundle** | This repository with `.secrets.enc` and `config/cluster.env`, an etcd snapshot, and an export of the cluster's state and Longhorn's records | NAS, NFS export `CLUSTER_BACKUP_EXPORT`, `cluster/<laptop>/<time>`, newest at `cluster/latest` | 04:30 Chicago daily, 14 kept |

Longhorn also takes a local snapshot of every volume every six hours (12
kept) and a nightly system backup of its own settings (7 kept). Applications
themselves are not backed up: Argo CD redeploys them from git.

Longhorn's nightly job covers every volume in its `default` group, which a
new volume joins automatically. Velero covers the namespaces listed in
`apps/velero/manifests/velero-schedules.yaml`.

### Protected applications

`recovery/apps.conf` lists the applications whose data the checks and
`recovery/restore.sh` care about:

| App | Namespace | Volume | Swapped in on production |
| --- | --- | --- | --- |
| Trilium | `trilium` | `trilium-data` | 2026-10-13 |
| Vaultwarden | `vaultwarden` | `vaultwarden-data` | not yet |
| Authelia | `authelia` | `authelia-data` | not yet |
| Grafana | `monitoring` | `monitoring-grafana` | not yet |
| Prometheus | `monitoring` | StatefulSet volume | 2026-10-14 |
| Alertmanager | `monitoring` | StatefulSet volume | 2026-10-13 |
| Loki | `logging` | `storage-loki-0` | 2026-10-14 |

All seven were restored and read back on the DR host in the full rehearsal
of 2026-08-21. "Swapped in" means `restore.sh --promote-app` and
`--rollback-app` ran against the live app.

Loki is not in the Velero schedule: its snapshot copy failed now and then
(September and October 2026, cause unknown) and marked every nightly backup
`PartiallyFailed`. Longhorn still backs it up. Put `logging` back in the
schedule once that is understood.

## Schedule

The bundle, its checks and the canaries are user systemd timers on `dev`,
the laptop that is always on. They do not run on the other laptop.

| Time (Chicago) | What |
| --- | --- |
| 01:47 | Velero `protected-apps-daily` |
| 02:37 UTC | Longhorn `backup-nightly` |
| 04:20 UTC | Longhorn `system-backup-nightly` |
| 04:30 | `k3s-dr-backup.timer`: recovery bundle |
| 05:15 | `k3s-dr-verify.timer`: verify the bundle |
| 05:30 | `k3s-dr-monitor.timer`: check everything, email on a problem |
| Sunday 06:30 | `k3s-dr-restore-canary.timer`: a throwaway volume through Velero and back |
| Sunday 07:30 | `k3s-dr-longhorn-restore-canary.timer`: restore the smallest protected volume from Longhorn |
| 1st of the month | `k3s-dr-smtp-test.timer`: a test email, to prove alerts arrive |

```bash
systemctl --user list-timers 'k3s-dr-*'      # on dev
./install-dr-timers.sh                       # installs or repairs all six
```

## Check the backups

```bash
./dr-status.sh                 # everything; read-only
./backup/verify-backup.sh      # the latest recovery bundle
./backup/verify-velero.sh      # Velero's location, schedule and last backup
```

`dr-status.sh` ends with one of:

| Exit | Result | Meaning |
| --- | --- | --- |
| 0 | `DR READY` | Bundle verified and every protected app has a backup under 30 hours old |
| 2 | `DR READY WITH WARNINGS` | Read each warning before relying on it |
| 1 | `DR NOT READY` | Something in the chain is missing or stale |

It also checks the DR host when that is switched on; with
`DR_HOST_ON_DEMAND=true` a switched-off host is noted and skipped.

`verify-backup.sh` checks the bundle's checksums, age, repository archive,
etcd snapshot, volume map, the Longhorn backup target, and free space on the
NAS (at least 10% and 100 GiB). The monitor emails a warning at 24 hours and
a critical at 30.

In Grafana, "Homelab - Backups (Velero)" shows Velero's backups, their
duration and the data moved.

To relax a limit for one run (it changes the check, not the backup):

```bash
MAX_APP_BACKUP_AGE_HOURS=36 ./dr-status.sh
MAX_BACKUP_AGE_HOURS=36 ./backup/verify-backup.sh
BACKUP_KEEP_COUNT=21 ./backup/backup.sh
```

## Take a backup now

Before a risky change, or after a recovery:

```bash
./backup/backup.sh                                      # recovery bundle

JOB="manual-backup-$(date +%Y%m%d-%H%M%S)"              # Longhorn, every volume
kubectl -n longhorn-system create job --from=cronjob/backup-nightly "$JOB"
kubectl -n longhorn-system wait --for=condition=complete --timeout=3h job/"$JOB"

velero backup create --from-schedule protected-apps-daily --wait   # Velero

./dr-status.sh
```

`backup.sh` refuses to run if a node is not Ready, the Longhorn target is
unavailable or another backup holds the lock. It reaches the NAS through the
first control-plane node, so the laptop needs no sudo. It updates
`cluster/latest` only once the bundle is complete and verified, and ends with
`BACKUP PASSED`.

## Restore one application

`recovery/restore.sh` restores an app's latest Longhorn backup beside the live
data, lets you look at it, and only then swaps it in. Each step is separate.

```bash
recovery/restore.sh --plan trilium           # live volume, the backup it would use, steps
recovery/restore.sh --restore-app trilium    # restore into trilium-restore-test; live app untouched
kubectl -n trilium exec -it trilium-restore-inspect -- sh   # look at the restored files
recovery/restore.sh --promote-app trilium --confirm         # swap it in
recovery/restore.sh --rollback-app trilium --confirm        # undo the swap, or
recovery/restore.sh --accept-app trilium --confirm          # keep it
recovery/restore.sh --cleanup-test trilium                  # remove what is no longer used
```

- `--restore-app` takes a few minutes for a small volume; Prometheus's 24 GB
  took 23 minutes.
- `--promote-app` stops the app, makes the restored volume take over the
  live claim's name, starts the app and runs a health check. Argo CD is
  paused only during the swap. The volume the app used before is kept
  (`Retain`), so `--rollback-app` can put it back.
- `--accept-app` closes a swap you keep, so the DR checks stop reporting it,
  and prints how to delete the old volume. After that, `--cleanup-test`
  deletes the old volume too. The next restore goes into
  `trilium-restore-test-b`, since `trilium-restore-test` is now live; the two
  names alternate.
- State is saved under `recovery/state/<app>/`, so `--promotion-status APP`
  shows where it got to.
- To restore without promoting, copy what you need out of the inspect pod,
  then run `--cleanup-test`.

### Choosing the backup

By default `--restore-app` uses the newest backup of the live volume. If the
live volume has none, as on a rebuilt cluster, it uses the newest backup of
the volume that held the same claim before. `--list-backups APP` shows every
volume with backups of the app's claim, and `--from-volume VOLUME` picks one:

```bash
recovery/restore.sh --list-backups trilium
recovery/restore.sh --restore-app trilium --from-volume pvc-73903032-e5f6-4176-95f6-e57a24a4d558
```

The nightly backups record which claim they came from. Backups taken by hand
and Longhorn's own system backups do not; `--list-backups` lists those
separately, by volume, for volumes no longer in the cluster, and the recovery
bundle's `cluster-state/pvc-volume-map.txt` names their claims.

### From Velero instead

When Longhorn's copy is unusable, restore the namespace's volume claims from
Velero into a new namespace and look at them there:

```bash
velero backup get
velero restore create --from-backup <backup> \
  --include-namespaces trilium --namespace-mappings trilium:trilium-velero \
  --include-resources persistentvolumeclaims
```

Restore only the claims, never Deployments, Services or routes, so nothing
in the copy takes traffic or sends mail. `scripts/test-velero-backup.sh`
does the whole round trip with a throwaway volume.

## The recovery bundle

```text
cluster/<laptop>/<YYYYMMDD-HHMMSS>/
  BACKUP-MANIFEST.txt   SHA256SUMS
  repo/k3s-repository.tar.gz    this repository, without git history
  repo/k3s-secrets.enc          .secrets.enc
  etcd/<snapshot>
  cluster-state/                nodes, namespaces, volumes, volume map, Longhorn, Helm
```

Files are readable only by their owner on the NAS, because the etcd snapshot holds
every Secret. The cluster runs with `--secrets-encryption`, so Secrets are
encrypted inside the snapshot too; reading them needs the `K3S_TOKEN` the
cluster was built with, which is in `.secrets.enc`. Snapshots from before
2026-10-09 hold Secrets unencrypted.

```bash
recovery/restore.sh --preflight      # find and verify the latest bundle
recovery/restore.sh --restore-repo   # unpack the repository to ~/k3s-restored
recovery/restore.sh --show-manifest
```

These mount the NAS on the laptop and need sudo.

Bundles are encrypted to the laptop age key. After the key is replaced, a
bundle made before then opens only with the old key, which is why the old
key is kept in Bitwarden for two weeks. `scripts/test-secrets-recovery.sh`
checks the latest bundle opens with the current key; run it after any key
change and every quarter.

## Velero details

- Velero copies Longhorn CSI snapshots to Garage with its Kopia data mover,
  one copy per node at a time. Each copy goes through a temporary one-replica
  volume (`longhorn-velero-temp`) and may take up to 90 minutes to prepare.
- Garage: `http://<UNRAID_IP>:3900`, bucket `k3s-velero`, region `garage`,
  path-style addressing, a `velero-k3s` key that can reach only that bucket.
  Its keys and the repository password are in `.secrets.enc`.
- Argo CD deploys it in three applications: `snapshot-controller`,
  `backup-config` (Longhorn's recurring jobs and snapshot class) and `velero`.
- Never run the AWS plugin v1.14.2; it corrupts data on non-AWS storage.
  After merging a Velero or plugin upgrade, run
  `scripts/test-velero-backup.sh` before relying on it.

## Move Longhorn backups to another share

Change `BACKUP_NAS_IP` or `LONGHORN_BACKUP_SHARE` in `config/cluster.env`,
run `scripts/render-argocd-values.sh`, and push the configuration repository.
Every volume's backups switch at once, and nothing tests the address first:
with a wrong one the target turns unavailable at Longhorn's next check, within
five minutes. Confirm and take a backup:

```bash
kubectl -n longhorn-system get backuptargets.longhorn.io default \
  -o jsonpath='{.status.available}{"\n"}'
```

Backups on the old share stay there, and Longhorn lists only the share it
points at.

## When a check fails

```bash
kubectl -n longhorn-system get backuptarget default -o wide
kubectl -n longhorn-system get backups.longhorn.io --sort-by=.status.backupCreatedAt | tail
kubectl -n velero get backups,datauploads
journalctl --user -u k3s-dr-backup.service --since today      # on dev
```

The usual causes: the NAS or Unraid is down or full, a node is not Ready,
SSH to the first control-plane node fails, or a Velero copy timed out. Do not
repoint `cluster/latest` by hand; fix the cause and run `backup.sh` again.
