# K3s Homelab Disaster Recovery Runbook

## Purpose

This runbook documents the tested disaster-recovery procedure for the
k3s-homelab cluster.

The recovery process uses:

- K3s etcd snapshots for cluster-state recovery
- Git repository backups for manifests and configuration
- Longhorn backups stored on the NAS for persistent application data
- A clean K3s DR node for recovery testing
- Application-level validation after storage restoration

A restore is NOT considered successful merely because a Longhorn volume
restores successfully.

Recovery is considered successful only after the application can start and
the recovered data can be read at the application level.


# 1. Recovery Success Levels

## Level 1 - Cluster Recovery

The Kubernetes control plane must be functional.

Validate:

- K3s API responds
- Node is Ready
- etcd is healthy
- Cilium is healthy
- CoreDNS is healthy
- kubectl works reliably


## Level 2 - Storage Recovery

Longhorn must be functional.

Validate:

- Longhorn manager is running
- Longhorn node is Ready
- Longhorn disk is Ready and Schedulable
- Backup target is Available
- BackupVolume objects have synchronized
- Required backups are visible
- Sufficient disk capacity exists for the restore


## Level 3 - Application Recovery

Each restored application must be started against its recovered data.

Validate the application itself.

Examples:

- Trilium: notes visible in UI
- Vaultwarden: application starts and database is readable
- Portainer: authentication and UI work
- Grafana: database health is OK
- Prometheus: TSDB loads and historical data can be queried
- Alertmanager: restored state loads and readiness succeeds
- Loki: historical logs can be queried

Only after Level 3 validation should an application be marked recovered.


# 2. Backup Locations

## Cluster Backup

Cluster backups are stored on the NAS.

Typical mount:

    /mnt/k3s-backup

Cluster backups contain:

- Git repository archive
- K3s etcd snapshot
- Kubernetes cluster-state exports
- PVC-to-Longhorn-volume mapping
- Longhorn resource exports
- backup manifest
- SHA256 checksums


## Longhorn Backup Target

Production Longhorn backup target:

    nfs://192.168.1.9:/mnt/user/K3S-Longhorn

Do NOT delete or modify the Longhorn backup target during DR testing.


# 3. Production Backup Verification

Before relying on a backup, run:

    cd ~/k3s-git
    ./backup/verify-backup.sh

Expected final result:

    ============================================
     BACKUP VERIFICATION PASSED
    ============================================

The verification should confirm:

- backup age is acceptable
- SHA256 checksums pass
- Git repository archive is readable
- etcd snapshot exists
- PVC volume map exists
- Longhorn backup target is available
- completed Longhorn backups exist


# 3A. Post-Recovery Production Protection Checkpoint

After production cluster recovery or major control-plane repair, do not stop
at "nodes are Ready." Create a new protected recovery point and return the DR
dashboard to `DR READY`.

## 1. Verify the recovered production cluster

Require:

```bash
kubectl get nodes
kubectl get --raw=/readyz
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system get pods -l name=kube-vip-ds
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,NODE:.status.currentNodeID'
```

Expected production state:

- all six Kubernetes nodes `Ready`
- Kubernetes API `/readyz` returns `ok`
- all Cilium agents Running/Ready
- all kube-vip control-plane pods Running/Ready
- all protected Longhorn volumes `healthy`

Do not create the final post-recovery backup set while a protected Longhorn
volume is still rebuilding or degraded. Wait for it to become healthy.

## 2. Create a fresh cluster recovery bundle

Run:

```bash
cd ~/k3s-git
./backup/backup.sh
```

A successful run ends with `BACKUP COMPLETE` and records:

- a new timestamped cluster bundle
- Longhorn backup-target availability
- an on-demand K3s etcd snapshot

The `k3s etcd-snapshot` subcommand may print warnings about server-only values
from `/etc/rancher/k3s/config.yaml`; the recovery bundle is successful only
when the snapshot command reports that the requested snapshot was saved and
the backup script reaches `BACKUP COMPLETE`.

## 3. Refresh protected Longhorn workload backups

The production protected volumes are members of the Longhorn `default`
recurring-job group. To request an immediate backup set using the existing
`backup-nightly` CronJob:

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

The job is complete only after Kubernetes reports the Job condition
`Complete`. Longhorn may need a short additional interval to synchronize the
backup target.

## 4. Require DR READY

Run:

```bash
cd ~/k3s-git
./dr-status.sh
```

Required result:

```text
Protected workloads: 7
Fresh backups:       7
Stale backups:       0
Missing backups:     0

RESULT: DR READY
```

A recovered production cluster is not considered fully protected until both
the cluster recovery bundle and protected Longhorn workload backups are fresh.

## Validated post-recovery checkpoint - 2026-08-22

Following control-plane recovery and deployment hardening, production
validation confirmed:

```text
Production nodes:       6/6 Ready
Cilium agents:          6/6 healthy
kube-vip pods:          3/3 healthy
Longhorn volumes:       7/7 healthy
Protected backups:      7/7 fresh
Stale backups:          0
Missing backups:        0
DR preflight:           14 PASS / 0 WARN / 0 FAIL
DR capacity available:  358 GiB
Required with headroom: 210 GiB
Result:                  DR READY
```



# 4. DR Node Preflight

Check the DR node before restoring data.

    sudo k3s kubectl get nodes -o wide

The DR node must report:

    Ready

Check filesystem capacity:

    df -h /
    df -h /var/lib/longhorn

Check Longhorn node:

    sudo k3s kubectl -n longhorn-system get \
      nodes.longhorn.io k3s-dr-test -o wide

Check Longhorn disk:

    sudo k3s kubectl -n longhorn-system get \
      nodes.longhorn.io k3s-dr-test -o json |
    jq -r '
      .status.diskStatus
      | to_entries[]
      | [
          "disk=" + .key,
          "path=" + .value.diskPath,
          "maximum=" +
            ((.value.storageMaximum / 1073741824) | floor | tostring) +
            " GiB",
          "available=" +
            ((.value.storageAvailable / 1073741824) | floor | tostring) +
            " GiB",
          "scheduled=" +
            ((.value.storageScheduled / 1073741824) | floor | tostring) +
            " GiB"
        ]
      | .[]
    '

Confirm disk conditions:

    sudo k3s kubectl -n longhorn-system get \
      nodes.longhorn.io k3s-dr-test -o json |
    jq -r '
      .status.diskStatus
      | to_entries[]
      | .value.conditions[]
      | "\(.type)=\(.status) reason=\(.reason) message=\(.message)"
    '

Required:

    Ready=True
    Schedulable=True


# 5. Longhorn Backup Target

Check the backup target:

    sudo k3s kubectl -n longhorn-system get \
      backuptarget default -o wide

Required:

    AVAILABLE=true

If a newly created production backup is not visible on the DR cluster,
do NOT assume the backup failed.

The DR Longhorn controller may not have synchronized the backup target yet.

Check visible backups:

    sudo k3s kubectl -n longhorn-system get \
      backups.longhorn.io -o wide

Wait for synchronization before attempting the restore.

A restore referencing a backup that Longhorn has not synchronized will fail
with an error similar to:

    failed to get backup <backup-name>:
    backup.longhorn.io "<backup-name>" not found


# 6. Selecting a Backup

Never hard-code backup names from previous DR tests.

Always select a current Completed backup.

Example:

    VOLUME="<production-longhorn-volume>"

    sudo k3s kubectl -n longhorn-system get \
      backups.longhorn.io -o json |
    jq -r --arg V "$VOLUME" '
      .items[]
      | select(
          .status.volumeName==$V and
          .status.state=="Completed"
        )
      | [
          .metadata.name,
          .status.snapshotCreatedAt,
          .status.volumeSize,
          .status.url
        ]
      | @tsv
    ' |
    sort -k2

Select the newest appropriate completed backup.


# 7. Restoring a Longhorn Volume

Example only:

    apiVersion: longhorn.io/v1beta2
    kind: Volume
    metadata:
      name: APPLICATION-dr-realdata
      namespace: longhorn-system
    spec:
      size: "SIZE_IN_BYTES"
      fromBackup: "LONGHORN_BACKUP_URL"
      numberOfReplicas: 1
      frontend: blockdev
      dataEngine: v1

Apply:

    sudo k3s kubectl apply -f restore-volume.yaml

Monitor:

    sudo k3s kubectl -n longhorn-system get volume \
      APPLICATION-dr-realdata \
      -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,RESTORE:.status.restoreRequired'

Do not proceed until the restore has completed.


# 8. Restore Load / API Stability

Large Longhorn restores can temporarily create significant CPU, disk and
Kubernetes API load.

During testing, starting multiple large restores simultaneously caused
temporary errors such as:

    the server is currently unable to handle the request

This did NOT indicate permanent cluster failure.

Monitor:

    uptime

and:

    sudo k3s kubectl get --raw='/readyz'

Recommended practice:

- restore large volumes in controlled batches
- avoid starting every large restore simultaneously
- allow Longhorn restore activity to settle
- confirm the Kubernetes API is healthy before continuing

For a small DR node, sequential restores are preferred.

During the full automated rehearsal on 2026-08-21, the 50 GiB Prometheus
restore caused temporary Kubernetes API readiness failures while Longhorn
continued restoring normally. The hardened restore helper now:

- tolerates transient API unavailability for a bounded grace period
- resumes monitoring an existing matching restore volume
- skips matching restore volumes that already completed
- aborts if an existing restore volume does not match the generated manifest

A temporary `/readyz` failure during a heavy restore is therefore not by
itself evidence that the restore failed.

Before deleting or recreating a volume after an interrupted run, inspect:

    sudo k3s kubectl -n longhorn-system get volume       <restore-volume>       -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,RESTORE:.status.restoreRequired,NODE:.status.currentNodeID'

A completed restored volume should settle at:

    STATE=detached
    RESTORE=false


# 9. Application Recovery Tests

## Trilium

Persistent data contains:

    document.db

After restoration, start Trilium against the recovered volume.

Validate:

- pod Running
- volume attached and healthy
- Trilium UI reachable
- notes visible
- expected notes/content present

Successful DR test:

    PASS


## Vaultwarden

Persistent data contains:

    db.sqlite3
    db.sqlite3-shm
    db.sqlite3-wal
    rsa_key.pem

Validate:

- restored database exists
- Vaultwarden starts
- /alive responds
- application can access the database

Vaultwarden may require HTTPS for normal browser functionality.

A browser HTTPS restriction is not by itself evidence that the restored
database failed.

Successful DR test:

    PASS


## Portainer

Persistent data contains:

    portainer.db
    portainer.key
    portainer.pub

Validate:

- restored database exists
- Portainer starts
- /api/status responds
- authentication succeeds
- UI loads

Some Kubernetes objects shown by Portainer are live cluster resources and
are not necessarily stored inside portainer.db.

Therefore, absence of original production namespaces/applications on an
isolated DR cluster does not by itself mean the Portainer database restore
failed.

Successful DR test:

    PASS


# 10. Observability Recovery

The observability stack consists of:

- Grafana
- Prometheus
- Alertmanager
- Loki

Production storage should be quiesced before taking a deliberate DR
validation backup when possible.


## Grafana

Production data mount:

    /var/lib/grafana

Important data includes:

    grafana.db
    plugins/

Start the same Grafana version against the restored volume.

Health check:

    wget -qO- http://127.0.0.1:3000/api/health

Expected:

    "database": "ok"

Validated version:

    Grafana 13.1.1

Result:

    PASS


## Prometheus

Production data mount:

    /prometheus

The kube-prometheus-stack StatefulSet uses a subPath:

    prometheus-db

When creating a standalone DR validation pod, ensure the restored directory
layout matches the production mount semantics.

Validated image:

    quay.io/prometheus/prometheus:v3.13.1-distroless

Successful startup should show:

    Found healthy block
    WAL replay completed
    TSDB started
    Server is ready to receive web requests.

Readiness endpoint:

    /-/ready

Expected:

    Prometheus Server is Ready.

Historical PromQL should also be tested.

Do NOT use an instant query evaluated at the current time as the sole
historical-data test. A restored Prometheus TSDB stops receiving samples at
the backup point, so a query such as:

    count({__name__!=""})

can legitimately return an empty vector several hours after the backup even
when the historical TSDB is intact.

The automated DR validator therefore uses a historical range query and
requires actual samples to be returned from the restored time range.

Do NOT consider Prometheus recovered solely because the process starts.

Result:

    PASS


## Alertmanager

Production data mount:

    /alertmanager

The StatefulSet uses subPath:

    alertmanager-db

Validated image:

    quay.io/prometheus/alertmanager:v0.33.1

Readiness endpoint:

    /-/ready

Expected:

    OK

Result:

    PASS


## Loki

Production data mount:

    /var/loki

Validated image:

    docker.io/grafana/loki:3.7.6

Loki configuration must match production closely.

Important production settings include:

    path_prefix: /var/loki
    replication_factor: 1
    filesystem storage
    TSDB schema v13
    HTTP port 3100
    gRPC port 9095
    memberlist port 7946

A standalone DR Loki instance may require a temporary memberlist service
matching the restored/test configuration.

Readiness:

    curl http://loki-dr-web:3100/ready

Expected:

    HTTP/1.1 200 OK

    ready

Validate restored labels:

    curl \
      http://loki-dr-web:3100/loki/api/v1/label/namespace/values

During the validated recovery, restored namespaces included:

    cattle-system
    cattle-turtles-system
    kube-system
    logging
    longhorn-system
    monitoring

Finally perform a historical LogQL query:

    curl -G \
      http://loki-dr-web:3100/loki/api/v1/query_range \
      --data-urlencode 'query={namespace="longhorn-system"}' \
      --data-urlencode 'start=<START_TIME>' \
      --data-urlencode 'end=<END_TIME>' \
      --data-urlencode 'limit=10' \
      --data-urlencode 'direction=backward'

The DR test returned actual historical logs from the original production
cluster and original k3s nodes.

Result:

    PASS


# 11. Validated Application Matrix

| Application  | Storage Restore | Application Start | Historical/User Data | Result |
|--------------|-----------------|-------------------|----------------------|--------|
| Trilium      | PASS            | PASS              | PASS                 | PASS   |
| Vaultwarden  | PASS            | PASS              | PASS                 | PASS   |
| Portainer    | PASS            | PASS              | PASS*                | PASS   |
| Grafana      | PASS            | PASS              | PASS                 | PASS   |
| Prometheus   | PASS            | PASS              | PASS                 | PASS   |
| Alertmanager | PASS            | PASS              | PASS                 | PASS   |
| Loki         | PASS            | PASS              | PASS                 | PASS   |

*Portainer's live Kubernetes inventory depends on the cluster Portainer is
connected to and is not expected to reproduce the original production
cluster inventory on an isolated DR test cluster.


# 12. DR Cleanup

After validation, delete temporary resources in this order:

1. DR application/test pods
2. wait for Longhorn volumes to detach
3. temporary Services
4. temporary ConfigMaps
5. DR PVCs
6. retained DR PVs
7. temporary restored Longhorn volumes

Do NOT delete:

- Longhorn backup target
- Longhorn Backup objects
- NAS backup data
- production Git repository backup
- etcd snapshots

Final cleanup verification:

    sudo k3s kubectl get pods -A |
      grep -E 'grafana-dr|prometheus-dr|alertmanager-dr|loki-dr'

    sudo k3s kubectl get pvc -A |
      grep -E 'grafana-dr|prometheus-dr|alertmanager-dr|loki-dr'

    sudo k3s kubectl get pv |
      grep -E 'grafana-dr|prometheus-dr|alertmanager-dr|loki-dr'

    sudo k3s kubectl get svc -A |
      grep -E 'grafana-dr|prometheus-dr|alertmanager-dr|loki-dr'

    sudo k3s kubectl get configmap -A |
      grep -E 'grafana-dr|prometheus-dr|alertmanager-dr|loki-dr'

    sudo k3s kubectl -n longhorn-system get volumes.longhorn.io |
      grep -E 'grafana-dr|prometheus-dr|alertmanager-dr|loki-dr'

A completely cleaned observability validation should return no matching
resources.


# 13. Important Lessons From DR Validation

## Backup existence is not enough

A Longhorn backup marked Completed on production may not immediately appear
on the DR cluster.

Wait for backup-target synchronization.


## Volume restoration is not application recovery

Always start the application against the restored data.


## Match production versions

Use the same application image/version when validating recovered data.


## Match production filesystem layout

Pay attention to Kubernetes subPath mounts.

Prometheus and Alertmanager in particular use subdirectories inside their
PVCs.


## SQLite applications should preferably be quiesced

For applications such as:

- Trilium
- Vaultwarden
- Portainer
- Grafana

stopping or quiescing the writer before a deliberate backup gives the
cleanest recovery point.


## Observability data is recoverable

The validated DR test proved recovery of:

- Grafana database
- Prometheus TSDB blocks and WAL
- Alertmanager persistent state
- Loki TSDB/index/chunks and historical logs


# 14. DR Test Record

Validated:

    2026-08-20

DR host:

    k3s-dr-test

DR host address during validation:

    192.168.1.126

Production cluster:

    k3s-homelab

Longhorn backup target:

    nfs://192.168.1.9:/mnt/user/K3S-Longhorn

Validated applications:

    Trilium
    Vaultwarden
    Portainer
    Grafana
    Prometheus
    Alertmanager
    Loki

Overall result:

    DISASTER RECOVERY VALIDATION PASSED


## Full Automated Lifecycle Rehearsal

Validated:

    2026-08-21

The complete automated lifecycle was exercised using current Longhorn
backups:

    plan
      ↓
    sequential/resumable Longhorn restore
      ↓
    static PV/PVC binding
      ↓
    isolated validation workloads
      ↓
    application validation
      ↓
    guarded cleanup
      ↓
    final preflight

Restore set:

    7 Longhorn volumes
    175.0 GiB total

The large Prometheus restore generated transient API pressure. The restore
helper recovered through the API grace/retry behavior and completed all
seven restores.

Application validation result:

    PASS: 20
    WARN: 0
    FAIL: 0

Post-cleanup preflight result:

    PASS: 14
    WARN: 0
    FAIL: 0

Overall result:

    FULL AUTOMATED DR LIFECYCLE VALIDATION PASSED



## Successful One-Command Orchestrated Rehearsal

Validated:

    2026-08-21

Coordinator:

    ./recovery/dr-rehearsal.sh --execute

The final orchestrated rehearsal completed every stage successfully:

    Production Kubernetes API:         PASS
    Production backup inventory:       PASS
    DR preflight:                      PASS
    Restore manifest generation:       PASS
    Validation manifest generation:    PASS
    Restore manifest validation:       PASS
    Longhorn restore:                  PASS
    PV/PVC binding:                    PASS
    Validation workloads:              PASS
    Application/data validation:       PASS
    DR cleanup:                        PASS
    Final clean-state preflight:       PASS

Final result:

    RESULT: FULL DR REHEARSAL PASSED

The application validator returned:

    PASS: 20
    WARN: 0
    FAIL: 0

The final post-cleanup preflight returned:

    PASS: 14
    WARN: 0
    FAIL: 0

The final rehearsal also validated restart/idempotency behavior:

- all 7 matching completed Longhorn restore volumes were classified
  `SKIP-COMPLETE`
- existing correct PV/PVC bindings were accepted as `unchanged`
- the resume-aware restore validator verified matching backup URLs and sizes
- a mismatched existing restore volume remains a hard failure
- validation resources passed a server-side dry run before application
- privileged validation apply was executed only through the protected
  `dr-apply-validation.sh` helper
- guarded cleanup removed validation resources, DR PVCs/PVs and restored
  Longhorn volumes
- Longhorn backups and the backup target remained intact
- no leftover DR resources remained after cleanup

Validated protected workload set:

    Loki
    Alertmanager
    Grafana
    Prometheus
    Portainer
    Trilium
    Vaultwarden

Total restored capacity:

    175.0 GiB

This is the current end-to-end proof that the protected workloads can be
restored from production Longhorn backups, mounted through isolated DR
bindings, started with matching application versions, validated at the
application/data level, and removed cleanly afterward.



# 15. DR Readiness Dashboard

Before generating a recovery plan or executing a rehearsal, run:

    cd ~/k3s-git
    ./dr-status.sh

`dr-status.sh` is a read-only readiness gate.

It does NOT:

- restore Longhorn volumes
- create PV/PVC bindings
- start validation workloads
- modify application data
- perform DR cleanup

It validates the conditions required to begin a recovery exercise.

## Readiness Checks

The dashboard checks:

1. Local repository state.
2. Protected application inventory from `recovery/apps.conf`.
3. Production Kubernetes API readiness.
4. All production Kubernetes nodes Ready.
5. Latest cluster recovery bundle passes `backup/verify-backup.sh`.
6. Cluster recovery bundle freshness.
7. Longhorn backup target Available.
8. Completed Longhorn backups visible.
9. Fresh backup coverage for every protected workload.
10. Current protected restore capacity.
11. Passwordless SSH connectivity to `k3s-dr`.
12. Protected DR preflight execution.
13. DR Longhorn capacity with configurable headroom.

Default thresholds:

    MAX_BACKUP_AGE_HOURS=30
    MAX_APP_BACKUP_AGE_HOURS=30
    CAPACITY_HEADROOM_PERCENT=20

These can be overridden through the environment when a different policy is
required.

## Readiness Results

Healthy:

    RESULT: DR READY

Usable but requiring operator review:

    RESULT: DR READY WITH WARNINGS

Unsafe to proceed:

    RESULT: DR NOT READY

Exit codes:

    0 = DR READY
    1 = DR NOT READY
    2 = DR READY WITH WARNINGS

Do not begin a planned DR rehearsal when the dashboard reports
`DR NOT READY` unless the failed condition is understood and explicitly
accepted as part of the test.

## Validated Readiness Result — 2026-08-21

The first validated readiness run reported:

    Protected workloads: 7
    Fresh backups:       7
    Stale backups:       0
    Missing backups:     0

    Restore capacity:    175.0 GiB
    20% headroom target: 210.0 GiB
    DR available:        358 GiB

    DR preflight:
      PASS: 14
      WARN: 0
      FAIL: 0

While `dr-status.sh` itself was still uncommitted during development, the
dashboard correctly returned:

    RESULT: DR READY WITH WARNINGS

The only warning was the intentionally modified local repository. After the
final dashboard is committed, the expected steady-state result is:

    RESULT: DR READY


## Post-Recovery Readiness Result - 2026-08-22

After production control-plane recovery, a fresh recovery bundle and fresh
Longhorn protected-workload backups were created. The steady-state dashboard
reported:

```text
Production Kubernetes API: PASS
Nodes Ready:               6/6
Cluster recovery bundle:   fresh / verified
Longhorn backup target:    AVAILABLE
Protected workloads:       7
Fresh backups:             7
Stale backups:             0
Missing backups:           0
DR preflight:              14 PASS / 0 WARN / 0 FAIL
Result:                    DR READY
```

This is the current known-good post-recovery protection checkpoint.


## Standard Operating Flow

    ./dr-status.sh
        ↓
    RESULT: DR READY
        ↓
    ./recovery/dr-rehearsal.sh
        ↓
    review generated manifests and restore plan
        ↓
    ./recovery/dr-rehearsal.sh --execute
        ↓
    RESTORE
        ↓
    BIND
        ↓
    application/data validation
        ↓
    CLEANUP
        ↓
    final clean-state preflight


# 16. Automated DR Planning Workflow

The preferred planning workflow is now:

    ./recovery/dr-plan.sh

This performs the following sequence:

    dr-preflight.sh
        ↓
    dr-find-backups.sh
        ↓
    dr-generate-restore.sh
        ↓
    dr-validate-generated.sh
        ↓
    STOP FOR HUMAN REVIEW

The planning workflow does NOT apply restore resources.

Expected final output:

    GENERATED RESTORE VALIDATION PASSED

    DR PLAN COMPLETE

    No restore resources were applied by dr-plan.sh.

Generated restore manifest:

    recovery/generated-latest-restore.yaml

The generated manifest is intentionally ignored by Git because it contains
point-in-time backup names and restore URLs that will become stale as newer
Longhorn backups are created.


## Restore Execution

Only after reviewing the generated manifest should a restore be executed.

The guarded restore helper is:

    recovery/dr-apply-restore.sh

Example execution on the DR host:

    sudo env \
      KUBECTL="k3s kubectl" \
      VALIDATOR="/tmp/dr-validate-generated.sh" \
      /tmp/dr-apply-restore.sh \
      --manifest /tmp/generated-latest-restore.yaml

The apply helper:

- reruns restore-manifest validation
- verifies the Kubernetes API
- verifies the DR node
- verifies all referenced Longhorn backups
- verifies available Longhorn capacity
- checks for restore-volume name collisions
- prints the full restore plan
- requires typing RESTORE exactly
- restores Longhorn volumes one at a time
- waits for each restore before proceeding
- checks Kubernetes API health during restores
- stops immediately on failure or timeout
- never automatically deletes a failed restore
- does not create PVs, PVCs, or application pods

Sequential restoration is intentional.

During DR testing, restoring multiple large Longhorn volumes simultaneously
caused enough load to temporarily make the Kubernetes API and etcd
unavailable.

The sequential restore helper avoids repeating that behavior.


## Current DR Helper Set

    dr-status.sh
    recovery/DR-RUNBOOK.md
    recovery/dr-preflight.sh
    recovery/dr-find-backups.sh
    recovery/dr-generate-restore.sh
    recovery/dr-validate-generated.sh
    recovery/dr-plan.sh
    recovery/dr-apply-restore.sh
    recovery/dr-bind-restores.sh
    recovery/dr-generate-validation.sh
    recovery/dr-apply-validation.sh
    recovery/dr-validate-apps.sh
    recovery/dr-cleanup.sh
    recovery/dr-rehearsal.sh


## Normal DR Workflow

Readiness:

    cd ~/k3s-git
    ./dr-status.sh

Require:

    RESULT: DR READY

Planning:

    ./recovery/dr-plan.sh

Review:

    less recovery/generated-latest-restore.yaml

Execution:

    Copy the generated manifest, validator, and apply helper to the DR host.

    Run dr-apply-restore.sh explicitly.

Application recovery:

    Bind restored Longhorn volumes to temporary PV/PVC resources.

    Start applications using restored data.

    Perform application-level validation according to this runbook.

Cleanup:

    Remove temporary application resources.

    Remove test PVCs and PVs.

    Remove temporary restored Longhorn volumes.

Final verification:

    ./recovery/dr-preflight.sh

A completed DR test should finish with:

    PASS
    WARN: 0
    FAIL: 0

# 17. Full Automated DR Lifecycle

The complete validated DR lifecycle is:

    plan
      ↓
    restore Longhorn volumes
      ↓
    bind restored volumes to static PV/PVC resources
      ↓
    generate isolated validation workloads
      ↓
    apply validation workloads
      ↓
    run application validation
      ↓
    cleanup

Primary helpers:

    recovery/dr-plan.sh
    recovery/dr-preflight.sh
    recovery/dr-find-backups.sh
    recovery/dr-generate-restore.sh
    recovery/dr-validate-generated.sh
    recovery/dr-apply-restore.sh
    recovery/dr-bind-restores.sh
    recovery/dr-generate-validation.sh
    recovery/dr-apply-validation.sh
    recovery/dr-validate-apps.sh
    recovery/dr-cleanup.sh
    recovery/dr-rehearsal.sh

Generated point-in-time manifests are intentionally ignored by Git.


## Binding Restored Volumes

After the Longhorn restore volumes have completed successfully, generate
static PV/PVC bindings:

    ./recovery/dr-bind-restores.sh \
      --manifest recovery/generated-latest-restore.yaml \
      --output recovery/generated-latest-bindings.yaml

The generated binding manifest maps the restored Longhorn volumes to
isolated DR PVCs.

Validated mappings include:

    dr-restore-logging-loki             -> logging/loki-dr
    dr-restore-monitoring-alertmanager  -> monitoring/alertmanager-dr
    dr-restore-monitoring-grafana       -> monitoring/grafana-dr
    dr-restore-monitoring-prometheus    -> monitoring/prometheus-dr
    dr-restore-portainer                -> portainer/portainer-dr
    dr-restore-trilium                  -> trilium/trilium-dr
    dr-restore-vaultwarden              -> vaultwarden/vaultwarden-dr

The generated PVs use:

    persistentVolumeReclaimPolicy: Retain

This is intentional. Deleting a DR PVC must not automatically destroy its
restored Longhorn volume.

The binding helper is non-destructive by default and only generates the
manifest.

Applying bindings requires:

    --apply

and an explicit confirmation by typing:

    BIND

The restored Longhorn volumes must already exist before bindings are
applied.


## Validation Workload Generation

Generate isolated application validation workloads with:

    ./recovery/dr-generate-validation.sh \
      --output recovery/generated-latest-validation.yaml

The generator captures the production application image versions at
generation time.

Validated images during the 2026-08-20 DR test were:

    Trilium        triliumnext/trilium:v0.104.1
    Vaultwarden    vaultwarden/server:1.37.1
    Portainer      portainer/portainer-ce:2.39.5-alpine
    Grafana        docker.io/grafana/grafana:13.1.1
    Prometheus     quay.io/prometheus/prometheus:v3.13.1-distroless
    Alertmanager   quay.io/prometheus/alertmanager:v0.33.1
    Loki           docker.io/grafana/loki:3.7.6

The generated manifest contains isolated DR validation Pods, Services and
required ConfigMaps.

Validation generation does NOT apply Kubernetes resources.

Review the generated manifest before applying it:

    less recovery/generated-latest-validation.yaml



## Protected Validation Workload Apply Helper

The reviewed validation manifest is applied through the protected helper:

    /usr/local/libexec/k3s-dr/dr-apply-validation.sh

This helper:

- requires an explicit validation manifest path
- verifies Kubernetes API readiness
- performs a server-side dry run first
- stops if the dry run fails
- applies only the supplied validation manifest
- does not restore Longhorn volumes
- does not create PV/PVC bindings
- does not perform cleanup

Validated execution from the operator workstation:

    ssh k3s-dr '
      sudo -n \
        /usr/local/libexec/k3s-dr/dr-apply-validation.sh \
        /tmp/generated-latest-validation.yaml
    '

General passwordless access to:

    sudo k3s kubectl

is intentionally NOT granted. Privileged Kubernetes actions remain limited
to the reviewed, root-owned DR helpers.

## Application Validation Helper

After the validation workloads are running, the repository copy is:

    recovery/dr-validate-apps.sh

The protected DR-host installation is:

    /usr/local/libexec/k3s-dr/dr-validate-apps.sh

From the operator workstation, the validated non-interactive command is:

    ssh k3s-dr '
      sudo -n /usr/local/libexec/k3s-dr/dr-validate-apps.sh
    '

    ssh k3s-dr '
      sudo -n \
        /usr/local/libexec/k3s-dr/dr-apply-validation.sh \
        /tmp/generated-latest-validation.yaml
    '

The validator performs read-only application and historical-data checks.

Expected validation targets:

    trilium/trilium-dr-validation
    vaultwarden/vaultwarden-dr-validation
    portainer/portainer-dr-validation
    monitoring/grafana-dr-validation
    monitoring/prometheus-dr-validation
    monitoring/alertmanager-dr-validation
    logging/loki-dr-validation

Application-level checks include:

    Trilium
      web endpoint
      restored document.db

    Vaultwarden
      /alive
      restored db.sqlite3

    Portainer
      /api/status
      restored portainer.db

    Grafana
      /api/health
      database=ok

    Prometheus
      /-/ready
      historical range query with restored TSDB samples

    Alertmanager
      /-/ready

    Loki
      /ready
      restored namespace/index visibility
      historical log visibility

The validator may create temporary curl pods for isolated HTTP checks and
removes those temporary check pods afterward.

It does not modify restored application data and does not create or delete
the DR application workloads themselves.

Application validation remains mandatory. A successful Longhorn restore by
itself is not sufficient to declare recovery successful.


## Guarded Cleanup Helper

After application validation is complete, use:

    recovery/dr-cleanup.sh

Validated non-interactive execution from the operator workstation:

    ssh k3s-dr '
      sudo -n /usr/local/libexec/k3s-dr/dr-cleanup.sh
    '

The cleanup helper first inventories known DR resources and displays what it
intends to remove.

It requires typing:

    CLEANUP

exactly before deletion begins.

Entering anything else aborts cleanup without deleting resources.

The validated cleanup order is:

    validation Pods/Services/ConfigMaps
      ↓
    DR PVCs
      ↓
    wait for Longhorn detach
      ↓
    retained DR PVs
      ↓
    dr-restore-* Longhorn volumes

The cleanup helper is designed to remove only known DR
validation/binding/restore resources.

It does NOT delete:

    Longhorn backups
    Longhorn BackupVolume objects
    Longhorn backup target
    NAS backup data
    production Git repository backups
    K3s etcd snapshots

After cleanup, rerun:

    ./recovery/dr-preflight.sh

A clean DR environment should report no leftover DR test resources and end
with:

    PASS
    WARN: 0
    FAIL: 0



## Full Rehearsal Orchestrator

The top-level rehearsal coordinator is:

    recovery/dr-rehearsal.sh

Default mode is non-destructive:

    ./recovery/dr-rehearsal.sh

Plan-only mode performs:

    passwordless DR SSH verification
      ↓
    production Kubernetes API verification
      ↓
    production backup inventory
      ↓
    DR preflight
      ↓
    restore manifest generation
      ↓
    validation manifest generation
      ↓
    copy generated manifests to DR
      ↓
    restore manifest validation
      ↓
    STOP

No restore, binding, validation workload, or cleanup resources are applied in
the default mode.

Full execution is:

    ./recovery/dr-rehearsal.sh --execute

Execution mode coordinates the validated helpers and keeps their individual
safety gates intact.

The operator must still type:

    RESTORE
    BIND
    CLEANUP

The orchestrator does not auto-answer those prompts.

If application/data validation fails, the orchestrator stops and intentionally
preserves the DR environment for troubleshooting. Cleanup is NOT started after
failed application validation.

Each run writes a timestamped log under:

    recovery/logs/

Example:

    recovery/logs/dr-rehearsal-YYYYMMDD-HHMMSS.log


# 18. Recommended End-to-End Procedure

For a new DR exercise, use the following order.

For a complete automated rehearsal after reviewing the planning output, the
preferred coordinator is:

    ./recovery/dr-rehearsal.sh --execute

The detailed steps below remain useful for manual recovery, troubleshooting,
and understanding each safety boundary.

## Step 0 - Check DR Readiness

    cd ~/k3s-git
    ./dr-status.sh

Preferred result:

    RESULT: DR READY

If the result is `DR READY WITH WARNINGS`, review every warning before
continuing.

If the result is `DR NOT READY`, do not proceed until the failed condition is
understood and corrected or explicitly accepted for the exercise.

## Step 1 - Verify Production Backup

    cd ~/k3s-git
    ./backup/verify-backup.sh

Do not proceed unless the intended recovery point is valid.


## Step 2 - Preflight the DR Cluster

Preferred execution from the operator workstation:

    ssh k3s-dr '
      sudo -n /usr/local/libexec/k3s-dr/dr-preflight.sh
    '

Required final state:

    WARN: 0
    FAIL: 0

Resolve leftover DR resources before beginning a new restore.


## Step 3 - Build the Recovery Plan

Run:

    ./recovery/dr-plan.sh

This discovers the latest completed Longhorn backups, generates the restore
manifest and validates it without applying restore resources.

Review:

    recovery/generated-latest-restore.yaml


## Step 4 - Restore Longhorn Volumes

Transfer the required generated manifest and helpers to the DR host and run:

    dr-apply-restore.sh --manifest generated-latest-restore.yaml

The operator must type:

    RESTORE

The volumes are restored sequentially to reduce load on Longhorn, etcd and
the Kubernetes API.

Do not continue until all required restore volumes have completed.


## Step 5 - Bind Restored Storage

Generate:

    ./recovery/dr-bind-restores.sh \
      --manifest recovery/generated-latest-restore.yaml \
      --output recovery/generated-latest-bindings.yaml

Review the PV/PVC mappings.

When a real validation is intended, apply through the guarded binding
workflow and type:

    BIND


## Step 6 - Generate Validation Workloads

Run:

    ./recovery/dr-generate-validation.sh \
      --output recovery/generated-latest-validation.yaml

Review the generated workload manifest before applying it.


## Step 7 - Start Isolated Validation Workloads

Apply the reviewed validation manifest to the DR cluster.

These workloads must remain isolated from production traffic and use the DR
PVCs created from the restored Longhorn volumes.

Do not redirect production DNS, ingress or clients to DR validation
workloads during a recovery test.


## Step 8 - Validate Applications and Historical Data

Run:

    ./recovery/dr-validate-apps.sh

Then perform any required UI-level checks described earlier in this runbook.

A recovery is successful only when the restored application data is
actually readable and usable.


## Step 9 - Record the DR Result

Record at minimum:

    recovery date
    selected backup timestamps
    restored applications
    failed or skipped checks
    application-level validation results
    cleanup result

Do not mark the exercise successful if only storage-level validation was
performed.


## Step 10 - Cleanup

Run:

    ./recovery/dr-cleanup.sh

Review the inventory carefully and type:

    CLEANUP

only when the listed resources are confirmed to be DR resources.


## Step 11 - Final Preflight

Run the preflight helper again.

The desired final condition is the same clean state that existed before the
DR exercise:

    no DR validation pods
    no DR PVCs
    no DR PVs
    no DR services
    no DR ConfigMaps
    no dr-restore-* Longhorn volumes

Longhorn backups on the NAS must remain intact.


# 19. DR Toolkit Reference

Current DR toolkit:

    dr-status.sh
    recovery/DR-RUNBOOK.md
    recovery/dr-preflight.sh
    recovery/dr-find-backups.sh
    recovery/dr-generate-restore.sh
    recovery/dr-validate-generated.sh
    recovery/dr-plan.sh
    recovery/dr-apply-restore.sh
    recovery/dr-bind-restores.sh
    recovery/dr-generate-validation.sh
    recovery/dr-apply-validation.sh
    recovery/dr-validate-apps.sh
    recovery/dr-cleanup.sh
    recovery/dr-rehearsal.sh

Generated files:

    recovery/generated-latest-restore.yaml
    recovery/generated-latest-bindings.yaml
    recovery/generated-latest-validation.yaml

Generated manifests contain point-in-time recovery information and should
not be treated as permanent recovery configuration.

The helper scripts and this runbook are the durable DR tooling. The
manifests should be regenerated for each recovery exercise so that current
backups, current volume sizes and current application images are used.



# 20. Protected DR Host Execution

DR-side helpers that require privileged K3s access are installed in:

    /usr/local/libexec/k3s-dr/

Installed protected helpers:

    dr-preflight.sh
    dr-apply-restore.sh
    dr-bind-restores.sh
    dr-apply-validation.sh
    dr-cleanup.sh
    dr-validate-apps.sh
    dr-validate-generated.sh

Required ownership and permissions:

    root:root 755

The operator account must not be able to modify these privileged scripts.


## Passwordless SSH From the Operator Workstation

The workstation uses public-key authentication and the SSH alias:

    Host k3s-dr
        HostName <DR_HOST_ADDRESS>
        User jeff
        IdentityFile ~/.ssh/id_ed25519
        IdentitiesOnly yes
        ServerAliveInterval 30
        ServerAliveCountMax 3

This permits:

    ssh k3s-dr

without an SSH password prompt.


## Restricted Passwordless Sudo

Do NOT configure:

    NOPASSWD: ALL

Do NOT allow passwordless execution of operator-writable scripts in `/tmp`.

Passwordless sudo is restricted to the protected, root-owned DR helpers
under `/usr/local/libexec/k3s-dr/`.

Use `sudo -n` for non-interactive checks. If sudo policy is incorrect, the
command fails immediately rather than prompting for a password.

Examples:

    ssh k3s-dr '
      sudo -n /usr/local/libexec/k3s-dr/dr-preflight.sh
    '

    ssh k3s-dr '
      sudo -n /usr/local/libexec/k3s-dr/dr-validate-apps.sh
    '

    ssh k3s-dr '
      sudo -n /usr/local/libexec/k3s-dr/dr-cleanup.sh
    '

The 2026-08-21 rehearsal confirmed passwordless SSH plus restricted
passwordless sudo worked without granting unrestricted root access.



## Resume / Idempotency Requirement

The final orchestrated rehearsal proved that DR automation must tolerate
interruption and safe reruns.

Matching completed Longhorn volumes must be recognized as:

    SKIP-COMPLETE

Matching in-progress restores may be resumed.

Existing PV/PVC bindings that already match the generated DR mapping may be
accepted as unchanged.

Existing restore volumes with a different backup URL or volume size must
remain a hard failure.


## Privileged Orchestration Boundary

Passwordless SSH and sudo are used only with explicitly approved, root-owned
helpers.

Do not broaden the sudo policy to:

    NOPASSWD: ALL

and do not grant general passwordless:

    k3s kubectl

access.

The final automated rehearsal uses the protected helper:

    dr-apply-validation.sh

for server-side validation and application of the generated validation
manifest.


# 21. Final Recovery Standard

The DR process is considered successful only when all applicable levels are
satisfied:

    Level 1 - Cluster Recovery
      Kubernetes control plane and core services are healthy.

    Level 2 - Storage Recovery
      Required Longhorn backups restore successfully and restored storage is
      accessible through the expected DR PV/PVC mappings.

    Level 3 - Application Recovery
      Applications start against restored data and application-level or
      historical-data validation succeeds.

The required standard is therefore:

    BACKUP EXISTS
        is not enough.

    VOLUME RESTORED
        is not enough.

    POD RUNNING
        is not enough.

    APPLICATION DATA VALIDATED
        is the recovery criterion.

After a DR test, cleanup must return the DR environment to a known clean
state without deleting the protected Longhorn backups or NAS backup data.
