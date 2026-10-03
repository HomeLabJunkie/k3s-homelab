# Backup and disaster recovery

[Back to the README](../README.md)

What is protected, how it is backed up, and how a recovery is rehearsed. The
day-to-day commands and verification criteria are in
[`backup-procedures.md`](../backup-procedures.md); the full recovery procedure is
[`recovery/DR-RUNBOOK.md`](../recovery/DR-RUNBOOK.md).

## Protected persistent workloads

The DR configuration in `recovery/apps.conf` currently protects eight persistent workloads:

| Application | Namespace | Persistent data |
| --- | --- | --- |
| Trilium | `trilium` | `trilium-data` |
| Vaultwarden | `vaultwarden` | `vaultwarden-data` |
| Authelia | `authelia` | `authelia-data` |
| Portainer | `portainer` | `portainer` |
| Grafana | `monitoring` | `monitoring-grafana` |
| Loki | `logging` | `storage-loki-0` |
| Prometheus | `monitoring` | Prometheus StatefulSet PVC |
| Alertmanager | `monitoring` | Alertmanager StatefulSet PVC |

The tested restore set currently totals approximately 175 GiB of provisioned persistent storage.

## Backup design

There are three complementary backup layers.

### 1. Cluster Recovery Bundle

Run:

```bash
cd ~/Work/k3s-homelab
./backup/backup.sh
```

The cluster bundle contains:

- repository archive
- Kubernetes node state
- namespaces
- StorageClasses
- PVs and PVCs
- ingress resources
- PVC-to-volume mapping
- Longhorn volumes
- Longhorn backups
- Longhorn BackupVolumes
- Longhorn backup-target state
- Longhorn recurring jobs
- Longhorn system backups when available
- Helm release inventory
- an on-demand K3s etcd snapshot
- backup manifest
- SHA256 checksums

Bundles are stored on the configured NFS cluster-backup export and a `latest` symlink identifies the newest recovery bundle.

### 2. Longhorn Application Backups

Application data is backed up through Longhorn to the configured SMB/CIFS backup target. Cluster recovery bundles use the same NAS through its NFSv3 export.

The current DR process requires every protected Longhorn PVC to have a fresh
completed backup within the configured DR freshness threshold.

To request an immediate protected-volume backup using the same Longhorn
recurring-job mechanism used in production:

```bash
JOB="manual-backup-nightly-$(date +%Y%m%d-%H%M%S)"

kubectl -n longhorn-system create job   --from=cronjob/backup-nightly   "$JOB"

kubectl -n longhorn-system wait   --for=condition=complete   --timeout=3h   job/"$JOB"
```

After the job completes, run `./dr-status.sh` and require all protected
workloads to report fresh backups.

### 3. Velero application backups

Velero is a second, independent application-data path: it moves Longhorn CSI
snapshots to the Garage `k3s-velero` bucket every night. The schedule covers
the protected namespaces except `logging` (Loki), which is backed up by
Longhorn only. See [Velero backup procedures](../velero-backup-procedures.md).

### Verify Backups

Before relying on a recovery point:

```bash
./backup/verify-backup.sh
```

Verification includes:

- maximum cluster-bundle age
- SHA256 validation
- repository archive readability
- etcd snapshot presence
- PVC map presence
- Longhorn backup-target availability
- existence of completed Longhorn backups

Expected result:

```text
BACKUP VERIFICATION PASSED
```

## Disaster recovery

The repository contains a tested DR framework under `recovery/`.

Primary documentation:

```text
recovery/DR-RUNBOOK.md
```

The DR process has been validated end-to-end against a dedicated K3s DR host.

### DR Readiness Gate

Before planning or executing a rehearsal, run the read-only readiness dashboard:

```bash
./dr-status.sh
```

`dr-status.sh` performs no restore, binding, validation-workload, or cleanup
actions. It checks:

- local repository state and protected application inventory
- production Kubernetes API and node readiness
- verified cluster recovery-bundle freshness
- Longhorn backup-target availability
- completed Longhorn backup visibility
- fresh backup coverage for all protected workloads
- total protected restore capacity
- an additional configurable restore-capacity headroom requirement
- passwordless SSH connectivity to the DR host
- the protected DR preflight helper
- DR Longhorn capacity against the current restore requirement

Exit/result states:

```text
RESULT: DR READY
RESULT: DR READY WITH WARNINGS
RESULT: DR NOT READY
```

The normal DR operating flow is now:

```text
./dr-status.sh
        |
        v
RESULT: DR READY
        |
        v
./recovery/dr-rehearsal.sh
        |
        v
review generated plan
        |
        v
./recovery/dr-rehearsal.sh --execute
```

### Safe Planning

Run:

```bash
./recovery/dr-rehearsal.sh
```

Default mode is plan/preflight only and does not restore data.

It verifies/generates:

```text
DR SSH
  ↓
production API
  ↓
backup inventory
  ↓
DR preflight
  ↓
restore manifest
  ↓
validation manifest
  ↓
DR-side restore validation
  ↓
STOP
```

### Full Rehearsal

Run:

```bash
./recovery/dr-rehearsal.sh --execute
```

Full validated flow:

```text
Production backup inventory
        |
        v
DR preflight
        |
        v
Generate + validate current restore plan
        |
        v
RESTORE confirmation
        |
        v
Sequential / resumable Longhorn restore
        |
        v
BIND confirmation
        |
        v
Static DR PV/PVC bindings
        |
        v
Server-side validation-manifest dry run
        |
        v
Isolated validation workloads
        |
        v
Application + historical-data validation
        |
        v
CLEANUP confirmation
        |
        v
Guarded cleanup
        |
        v
Final clean-state preflight
```

The individual destructive safety confirmations are intentionally retained:

```text
RESTORE
BIND
CLEANUP
```

The orchestrator never auto-types these confirmations.

If application validation fails, DR state is preserved for troubleshooting and cleanup does not run automatically.

### Validated results

The full automated rehearsal has been run end-to-end against the DR host. The
dated readiness and rehearsal results are in the [changelog](CHANGELOG.md).

See [`recovery/DR-RUNBOOK.md`](../recovery/DR-RUNBOOK.md) for the complete procedure and recovery criteria.
