# Velero RustFS Backup Procedures

Velero provides a second, independent application-data backup path. It uses
Longhorn CSI snapshots, Velero's built-in Kopia data mover, and the dedicated
RustFS bucket `k3s-velero`. The existing Longhorn NFS backup target remains the
primary Longhorn backup path and is not changed by this setup.

## Pinned components

| Component | Version |
| --- | --- |
| CSI snapshot controller and CRDs | v8.6.0 |
| Velero | v1.18.2 |
| Velero Helm chart | 12.1.0 |
| Velero AWS object-store plugin | v1.14.2 |

The snapshot controller version matches the `csi-snapshotter` sidecar shipped
by Longhorn 1.12.1.

## Storage and credentials

- Endpoint: `https://192.168.1.250:30292`
- Bucket: `k3s-velero`
- Region: `us-east-1`
- Addressing: S3 path style
- TLS: verified with the RustFS CA copied from the existing Longhorn secret
- RustFS identity: dedicated service account restricted to `k3s-velero`
- Local secrets: `VELERO_RUSTFS_ACCESS_KEY`, `VELERO_RUSTFS_SECRET_KEY`, and
  `VELERO_REPOSITORY_PASSWORD` in `.secrets.enc`

Do not reuse `longhorn-data` for Velero. Longhorn expects to control the object
layout and lifecycle in its own bucket.

## Install or reconcile

```bash
cd ~/Work/k3s-homelab
./scripts/install-velero-backup.sh
kubectl apply -f manifests/backup/velero-schedules.yaml
```

The installer is idempotent. It installs the snapshot API, creates Kubernetes
secrets from SOPS at runtime, installs Velero, and waits for the RustFS backup
location and every node agent to become ready. It does not enable the schedule;
that remains an explicit manifest step.

## Schedule and retention

`protected-apps-daily` runs daily at 01:17 `America/Chicago`, protects the
namespaces represented
in `recovery/apps.conf`, moves CSI snapshot data to RustFS, and retains each
backup for 14 days. Data-mover concurrency is one per node to limit storage and
network pressure. Temporary full-copy snapshot volumes use the dedicated
`longhorn-velero-temp` storage class with one replica; production volumes keep
their normal replica count. The first seed backup can take substantially longer
than later Kopia backups.

The existing Longhorn NFS jobs remain unchanged:

- `backup-nightly` at `37 2 * * *`, retaining 14 backups
- `system-backup-nightly` at `20 4 * * *`, retaining 7 backups

## Verify health and freshness

```bash
./backup/verify-velero.sh
./dr-status.sh
kubectl -n velero get backupstoragelocation,schedules,backups
kubectl -n velero get datauploads,datadownloads
kubectl -n velero get pods
```

The verifier requires:

- RustFS backup location `Available`
- schedule `Enabled`
- a completed scheduled backup no older than 30 hours
- all Velero node agents Ready

The same checks are included in `dr-status.sh` and `monitoring/dr-monitor.sh`.
The monitor warns at 24 hours and becomes critical at 30 hours.

## Disposable end-to-end test

```bash
./scripts/test-velero-backup.sh
```

The test creates a 64 MiB Longhorn PVC, writes a unique marker, backs it up to
RustFS, deletes the source namespace, restores to a different namespace, checks
the marker, and removes both test namespaces. The completed canary backup is
retained for its configured TTL unless deleted explicitly.

## Isolated application restore pattern

For application testing, map the source namespace to a new namespace and restore
only `persistentvolumeclaims`. Create a separate read-only inspection pod after
the restore. Do not restore Deployments, Services, Ingresses, or Jobs into the
validation namespace; that prevents duplicate traffic and external side effects.

Never treat a successful upload alone as restore proof. Keep periodic isolated
PVC restores and verify known application artifacts without printing their
contents.
