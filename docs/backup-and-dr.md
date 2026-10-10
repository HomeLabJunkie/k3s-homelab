# Backup and disaster recovery

[Back to the README](../README.md)

What is protected, how it is backed up, and how a recovery is rehearsed. The
day-to-day commands and verification criteria are in
[`backup-procedures.md`](../backup-procedures.md); the full recovery procedure is
[`recovery/DR-RUNBOOK.md`](../recovery/DR-RUNBOOK.md).

## Protected persistent workloads

The DR configuration in `recovery/apps.conf` currently protects seven persistent workloads:

| Application | Namespace | Persistent data |
| --- | --- | --- |
| Trilium | `trilium` | `trilium-data` |
| Vaultwarden | `vaultwarden` | `vaultwarden-data` |
| Authelia | `authelia` | `authelia-data` |
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

Bundles are published readable only by their owner on the NAS, because the
etcd snapshot holds every Kubernetes Secret.

#### Secrets encryption at rest

The servers run with `--secrets-encryption` (set in `extra_server_args` in
`inventory/k3s-ansible/group_vars/all.yml`), so Secrets are stored encrypted
in etcd with K3s's default AES-CBC provider, and they are encrypted inside
every etcd snapshot too. ConfigMaps and other resources are not encrypted.

```bash
ssh <control-plane-node> sudo k3s secrets-encrypt status
```

should report `Encryption Status: Enabled` and `All hashes match` on each
server.

What this means for recovery:

- The encryption key lives on each server in
  `/var/lib/rancher/k3s/server/cred/encryption-config.json`. K3s also keeps it
  in the cluster's bootstrap data inside etcd, protected by the cluster token.
- Restoring an etcd snapshot onto new servers therefore needs the same
  `K3S_TOKEN` the cluster was built with. It is kept in `.secrets.enc`, which
  every bundle carries. Without that token the Secrets in a snapshot cannot
  be read.
- Snapshots taken before 2026-10-09 still hold Secrets unencrypted.
- To rotate the key, run `sudo k3s secrets-encrypt rotate-keys` on one server,
  wait for `reencrypt_finished`, then restart K3s on each server in turn. See
  the [K3s documentation](https://docs.k3s.io/cli/secrets-encrypt); a wrong
  rotation procedure can corrupt the cluster.

#### Testing an etcd snapshot restore

`recovery/dr-rehearsal.sh` restores Longhorn volumes; it does not restore the
etcd snapshot. That is tested separately, in a container that cannot reach
the LAN and runs no workloads, so kube-vip, MetalLB and cloudflared never
start against the real addresses or tunnel. Tested on 2026-10-09 against the
first snapshot taken after encryption was enabled: all 180 Secrets were
readable, and 179 matched production by hash (the other had since been
replaced in production).

With the snapshot copied out of a bundle to `$W/snapshot` and an env file
`$W/env` (mode 0600) holding `K3S_TOKEN=<the cluster token>`:

```bash
IMG=rancher/k3s:v1.36.5-k3s1   # match the cluster's K3s version
ARGS="--disable-agent --secrets-encryption --flannel-backend=none \
  --disable-network-policy --disable servicelb --disable traefik"

docker network create --internal etcd-restore-test
docker volume create etcd-restore-data
GW="$(docker network inspect etcd-restore-test -f '{{(index .IPAM.Config 0).Gateway}}')"

# K3s needs a default route to start; on an internal network it leads nowhere.
docker run --rm --privileged --network etcd-restore-test \
  --tmpfs /run --tmpfs /var/run --env-file "$W/env" \
  -v "$W":/restore:ro -v etcd-restore-data:/var/lib/rancher/k3s \
  --entrypoint sh "$IMG" -c "ip route add default via $GW && exec k3s server \
    --cluster-reset --cluster-reset-restore-path=/restore/snapshot $ARGS"

docker run -d --name etcd-restore --privileged --network etcd-restore-test \
  --tmpfs /run --tmpfs /var/run --env-file "$W/env" \
  -v etcd-restore-data:/var/lib/rancher/k3s \
  --entrypoint sh "$IMG" -c "ip route add default via $GW && exec k3s server $ARGS"

docker exec etcd-restore kubectl get --raw=/readyz
docker exec etcd-restore kubectl get secrets -A
```

Afterwards remove the container, volume, network and the files in `$W`.

- Without a token the restore stops with `please pass --token to complete the
  restoration`; with the wrong one it stops with `bootstrap data already found
  and encrypted with different token`.
- `k3s secrets-encrypt status` fails in this test cluster because it has no
  node of its own. Readable Secrets are the evidence.
- The test covers the control plane and Secrets only. No workloads start, so
  it says nothing about applications running on the restored state.
- A real recovery uses the same `--cluster-reset` and
  `--cluster-reset-restore-path` flags on a server, with the same token.

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

### The DR host

Rehearsals restore into `k3s-dr`, a single-node K3s cluster with Cilium and
Longhorn that points at the production Longhorn backup target. It is a VM
(8 vCPUs, 32 GB, 500 GB disk) on the `ubuntu-hp` server, under KVM/libvirt,
with its disk on the `tank` ZFS pool. `ubuntu-hp` is powered on only for
rehearsals.

```bash
./recovery/dr-host-power.sh status   # server power state, DR host reachability
./recovery/dr-host-power.sh on       # power on through the iLO, wait for SSH
./recovery/dr-host-power.sh off      # shut down the VMs and the server
```

The script reads `DR_HYPERVISOR_HOST` and `DR_ILO_HOST` from
`config/cluster.env`, and the iLO login from `~/.config/ilo-ubuntu-hp` (mode
0600, username on line 1, password on line 2). The VM starts automatically
when the server boots.

`recovery/dr-host-build.sh` builds the DR host on a fresh Ubuntu machine, or
converges an existing one. It reads the K3s, Cilium and Longhorn versions and
the Longhorn backup target from production, so the DR host matches the
cluster it has to recover, and installs the DR helpers under
`/usr/local/libexec/k3s-dr/`. It needs passwordless sudo on the host;
`--lock-sudo` then restricts passwordless sudo to the helpers. To regain
general sudo afterwards, set a password from the server with
`virsh set-user-password k3s-dr jeff <password>`.

`ubuntu-hp` also holds a copy of the NAS backup share in `tank/backup/k3s`,
refreshed by `/usr/local/sbin/k3s-backup-replicate` each time the server
boots and snapshotted after each run. It is only as fresh as the last time
the server was on. The script is `recovery/k3s-backup-replicate.sh`, installed
by hand on the server with its settings in `/etc/k3s-backup-replicate.env` and
run by the `k3s-backup-replicate.service` unit. It mounts the NAS read-only,
and refuses to run against an empty share so a failed mount cannot empty the
copy.

With `DR_HOST_ON_DEMAND=true`, `dr-status.sh` treats an unreachable DR host
as powered off: it prints a note, skips the DR preflight and capacity checks,
and can still report `DR READY`. That result then says nothing about the DR
host itself, which is only checked when it is on.

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
- passwordless SSH connectivity to the DR host (skipped with a note when
  `DR_HOST_ON_DEMAND=true` and the host is powered off)
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
Sequential / resumable Longhorn restore
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
Guarded cleanup
        |
        v
Final clean-state preflight
```

`--execute` runs unattended. The restore, bind and cleanup helpers each ask
for a typed confirmation (`RESTORE`, `BIND`, `CLEANUP`) when run by hand, but
the orchestrator passes `--yes` to all three, so one command runs the whole
rehearsal, including the cleanup. Everything it changes is on the DR host.

If application validation fails, DR state is preserved for troubleshooting and cleanup does not run automatically.

### Validated results

The full automated rehearsal has been run end-to-end against the DR host. The
dated readiness and rehearsal results are in the [changelog](CHANGELOG.md).

See [`recovery/DR-RUNBOOK.md`](../recovery/DR-RUNBOOK.md) for the complete procedure and recovery criteria.
