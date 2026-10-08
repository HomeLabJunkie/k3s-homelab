# Velero Garage Backup Procedures

Velero provides a second, independent application-data backup path. It uses
Longhorn CSI snapshots, Velero's built-in Kopia data mover, and the dedicated
Garage bucket `k3s-velero`. Longhorn application-volume backups use the
separate WD NAS SMB/CIFS target; cluster recovery bundles use that NAS through
its NFSv3 export.

## Pinned components

| Component | Version |
| --- | --- |
| CSI snapshot controller and CRDs | v8.6.0 |
| Velero | v1.18.4 |
| Velero Helm chart | 12.2.0 |
| Velero AWS object-store plugin | v1.14.4 |

The snapshot controller version matches the `csi-snapshotter` sidecar shipped
by Longhorn 1.12.1.

Never run AWS plugin v1.14.2: it corrupts metadata on non-AWS S3 backends by
adding unsupported checksum framing (`velero-io/velero#9951`). v1.14.3 and later
carry the fix, and the Garage location also explicitly disables optional
checksum calculation. `velero-values.yaml` holds the versions actually deployed;
Dependabot bumps them, so after merging a Velero or plugin bump, run the
installer and then the disposable restore test below before relying on it.

## Storage and credentials

- Endpoint: `http://<UNRAID_IP>:3900` (from `config/cluster.env`; injected by
  `scripts/install-velero-backup.sh`, override with `GARAGE_S3_URL`)
- Bucket: `k3s-velero`
- Region: `garage`
- Addressing: S3 path style
- Network: trusted LAN endpoint; no TLS termination is currently configured
- Garage identity: dedicated `velero-k3s` key restricted to `k3s-velero`
- Local secrets: `VELERO_GARAGE_ACCESS_KEY`, `VELERO_GARAGE_SECRET_KEY`, and
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
secrets from SOPS at runtime, installs Velero, and waits for the Garage backup
location and every node agent to become ready. It does not enable the schedule;
that remains an explicit manifest step.

## Schedule and retention

`protected-apps-daily` runs daily at 01:47 `America/Chicago`, protects the
namespaces represented
in `recovery/apps.conf` except `logging` (see the known issue below), moves CSI
snapshot data to Garage, and retains each
backup for 7 days. Data-mover concurrency is one per node to limit storage and
network pressure. Temporary full-copy snapshot volumes use the dedicated
`longhorn-velero-temp` storage class with one replica; production volumes keep
their normal replica count. The first seed backup can take substantially longer
than later Kopia backups.

Each temporary volume must finish copying before its upload starts. Node agents
wait up to 90 minutes for that (`--data-mover-prepare-timeout` in
`velero-values.yaml`). A DataUpload that still times out fails with `timeout on
preparing data upload` and leaves the backup `PartiallyFailed`.

Known issue: Loki's 50Gi volume (`logging/storage-loki-0`) intermittently failed
this way (Sep 28, Oct 1 and Oct 3 2026). The copy normally takes 4-8 minutes, so
the timeout is not the cause: on Oct 3 the Longhorn clone failed with
`connection reset by peer` 46 seconds in, Longhorn detached the temporary
volume, and the clone never completed. Moving the schedule off minute 17 and
raising the timeout did not prevent it, and the cause is not yet known.

Until it is, the `logging` namespace is not in the Velero schedule, so one bad
clone no longer marks every nightly backup `PartiallyFailed`. Loki's volume is
still backed up by Longhorn's `backup-nightly` job to the CIFS target, and Loki,
its gateway, the canary and Alloy are redeployed from this repository. Add
`logging` back to `manifests/backup/velero-schedules.yaml` once the clone
failures are understood.

The existing Longhorn jobs remain unchanged (Longhorn cron times are UTC):

- `snapshot-6hour` at `17 */6 * * *`, which is 01:17 Chicago time during
  daylight saving time; the Velero schedule stays off minute 17 so the two do
  not snapshot the same volumes at once
- `backup-nightly` at `37 2 * * *`, retaining 14 backups on the CIFS target
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

- Garage backup location `Available`
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
Garage, deletes the source namespace, restores to a different namespace, checks
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
