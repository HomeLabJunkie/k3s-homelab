# k3s-homelab

Automated build, application deployment, observability, backup, and disaster-recovery tooling for a highly available K3s homelab cluster.

This repository has evolved well beyond the original K3s/Traefik/Longhorn bootstrap. It now manages the cluster from initial Ansible provisioning through application deployment, persistent storage, monitoring/logging, verified backups, and a tested end-to-end DR rehearsal.

For the recommended maintenance commands and order of operations, see the
[K3s maintenance cheat sheet](cheat-sheet.md).

For backup creation, verification, scheduling, and troubleshooting, see the
[K3s backup procedures](backup-procedures.md).

## Current Architecture

The production cluster is currently operated as a six-node K3s cluster:

- 3 K3s server/control-plane/etcd nodes
- 3 K3s agent/worker nodes
- Ubuntu 26.04 LTS
- K3s `v1.35.8+k3s1`

Core platform:

| Layer | Current implementation |
| --- | --- |
| Kubernetes | K3s HA with embedded etcd |
| API HA | kube-vip |
| CNI | Cilium native routing |
| Network observability | Hubble relay + UI |
| Service load balancing | MetalLB Layer 2 |
| Ingress | Traefik |
| TLS | cert-manager + Let's Encrypt |
| External access | Cloudflare Tunnel |
| Persistent storage | Longhorn |
| Cluster management | Rancher |
| Secondary management | Portainer |
| Metrics | kube-prometheus-stack |
| Dashboards | Grafana |
| Logging | Loki + Grafana Alloy |
| Backup storage | NFS exports on NAS/Unraid |
| DR | Dedicated K3s DR host + automated rehearsal tooling |

Environment-specific addresses, domains, email addresses, backup exports, and VIP ranges belong in `config/cluster.env` and local inventory/secrets rather than in this README.

## Cluster Networking

K3s is installed with the built-in Flannel and Traefik components disabled so that networking and ingress are managed explicitly.

Current networking flow:

```text
Clients / Cloudflare
        |
        v
Cloudflare Tunnel / LAN
        |
        v
MetalLB service address
        |
        v
Traefik
        |
        v
Kubernetes Services / Pods
```

The Kubernetes API is exposed through a kube-vip virtual IP:

```text
kubectl / automation
        |
        v
kube-vip :6443
        |
        +---- K3s server 0
        +---- K3s server 1
        +---- K3s server 2
```

Cilium provides pod networking and Hubble provides network observability. MetalLB is configured in Layer 2 mode for service load-balancer addresses.

## Deployment Flow

The main deployment entry point is `deploy.sh`. Deployment now has two
intentionally separate lifecycle modes so an existing production cluster is
never sent through initial bootstrap logic by accident.

### Existing cluster - safe default

For normal production changes, first run the no-change preflight:

```bash
cd ~/Work/k3s-homelab
./deploy.sh --preflight-only
```

A successful preflight ends with:

```text
DEPLOYMENT PREFLIGHT PASSED
No cluster changes were made.
```

Then run the normal deployment:

```bash
./deploy.sh
```

Plain `./deploy.sh` defaults to **existing-cluster reconciliation** and uses:

```text
maintenance/reconcile-existing-cluster.yml
```

Existing-cluster reconciliation:

- validates every control-plane server as an existing embedded-etcd member
- reconciles control-plane servers one at a time
- never runs `k3s-init` or `--cluster-init` against an existing etcd member
- keeps secondary server services configured with a primary-server join URL
  and the local K3s server token file, allowing them to rejoin safely after an
  etcd snapshot restore
- uses the service-only `roles/k3s_server/tasks/reconcile.yml` path
- restarts K3s only when effective service configuration changes
- waits for local `/readyz` and Kubernetes Node `Ready` before continuing
- reconciles agents one at a time
- restarts an agent only when its systemd service configuration changed
- checks worker readiness through a healthy control-plane node

### Initial cluster bootstrap - explicit only

Initial provisioning of a new cluster must be requested explicitly:

```bash
./deploy.sh --bootstrap --preflight-only
./deploy.sh --bootstrap
```

`--bootstrap` selects `site.yml` and the bootstrap-oriented K3s roles. Do not
use bootstrap mode to reconcile an established production cluster.

### Single control-plane maintenance

To reconcile exactly one existing K3s server without running the rest of the
deployment:

```bash
ansible-playbook \
  -i inventory/k3s-ansible/hosts.ini \
  maintenance/reconcile-k3s-server.yml \
  -e target=<CONTROL_PLANE_IP>
```

The maintenance playbook refuses non-master targets, requires an existing
embedded-etcd member, and uses only the service reconciliation task file.

### Safe rolling cluster maintenance

Use the rolling wrapper to reconcile the full cluster one node at a time.
It discovers targets from the Ansible inventory, processes workers before
control-plane nodes, stops on the first failure, and writes a timestamped log
under `logs/maintenance/`.

Run its read-only check mode first:

```bash
./maintain-cluster.sh
```

Then apply after reviewing the checks:

```bash
./maintain-cluster.sh --apply
```

Type `APPLY CLUSTER` when prompted. Explicit unattended execution is available
as `./maintain-cluster.sh --apply --yes`.

Every node is delegated to `maintain-node.sh`, so inventory classification,
existing-node safeguards, Ansible check mode, and post-maintenance validation
remain mandatory. Post-maintenance validation covers Kubernetes API readiness,
the target Node `Ready` condition, Cilium on the target, kube-vip on
control-plane targets, and cluster-wide Longhorn volume health.

### Automation toolchain guard

Before loading Ansible collections, `deploy.sh` validates the host automation
toolchain against `config/toolchain.env`.

Supported ranges:

```text
ansible-core >= 2.20.1 and < 2.21.0
Python       >= 3.11.0 and < 3.15.0
```

This prevents a Homebrew or operating-system upgrade from silently moving
the repository onto an unvalidated Ansible major/minor series while still
allowing compatible 2.20.x patch updates.

`requirements.txt` remains the exact pip lock. `requirements.in` constrains
ansible-core to the supported 2.20.x series.

### Automatic Ansible dependency bootstrap

`deploy.sh` verifies the project-local Ansible collections before running any Ansible playbook. Exact versions are declared in `collections/requirements.yml` and installed under `.ansible/collections/`, which remains ignored by Git. Missing or mismatched dependencies are installed automatically with `ansible-galaxy`; matching dependencies are left untouched.

### Deployment preflight protections

Before Ansible can modify K3s, `deploy.sh`:

- loads and exports `config/cluster.env`
- requires all critical cluster environment values
- requires `KUBE_VIP` to be a valid usable IPv4 address
- rejects TEST-NET/documentation VIP values such as `192.0.2.0/24`
- validates the Ansible syntax for the selected lifecycle mode
- gathers control-plane facts and validates rendered node IPs
- verifies the rendered server arguments contain the expected
  `--tls-san=<KUBE_VIP>` and `--node-ip=<NODE_IP>`
- rejects rendered `--disable-agent` or `--disable-kube-proxy`
- makes no cluster changes when `--preflight-only` is used

High-level normal production flow:

```text
Load cluster.env + encrypted secrets
        |
        v
Validate KUBE_VIP + required configuration
        |
        v
Run deployment preflight
        |
        v
Existing cluster?
        |
        +---- normal/default ----> serial safe reconciliation
        |
        +---- --bootstrap -------> explicit initial provisioning
        |
        v
Prepare/verify Longhorn
        |
        v
Update/verify kubeconfig through kube-vip
        |
        v
Converge Helm/Kubernetes applications
        |
        v
Final health and storage verification
```

## Ansible Provisioning

`site.yml` is the bootstrap-oriented infrastructure deployment and is selected
only by `./deploy.sh --bootstrap`.

Bootstrap sequence:

1. Validate Ansible version.
2. Optionally prepare Proxmox LXC hosts.
3. Prepare K3s nodes.
4. Install K3s server nodes.
5. Install K3s agent nodes.
6. Perform post-server configuration.
7. Fetch the resulting kubeconfig to the repository directory.

For an established cluster, `deploy.sh` instead selects
`maintenance/reconcile-existing-cluster.yml`. Control-plane reconciliation
uses `roles/k3s_server/tasks/reconcile.yml`, and single-server maintenance uses
`maintenance/reconcile-k3s-server.yml`.

Important Ansible configuration is stored under:

```text
inventory/k3s-ansible/
├── group_vars/
│   └── all.yml
└── hosts.ini.template
```

The real `hosts.ini` is intentionally local/ignored.

## Platform Components

### Cilium and Hubble

Cilium is the active CNI.

The current configuration uses:

- native routing mode
- cluster CIDR `10.42.0.0/16`
- Hubble enabled
- kube-proxy-compatible K3s networking configuration
- Flannel disabled

### kube-vip

kube-vip provides the highly available Kubernetes API endpoint across the K3s server nodes.

The API VIP is loaded from:

```text
KUBE_VIP
```

in `config/cluster.env`.

`KUBE_VIP` has no documentation-address fallback in normal operation.
Deployment stops before Ansible if the value is missing, invalid, unusable, or
in the `192.0.2.0/24` TEST-NET range. The kube-vip manifest renders the
validated address explicitly rather than allowing an empty `address` value.

### MetalLB

MetalLB provides Kubernetes `LoadBalancer` service addresses.

Current mode:

```text
Layer 2
```

The pool is supplied through:

```text
METALLB_IP_RANGE
```

### Traefik

Traefik is installed separately with Helm rather than using the K3s bundled Traefik.

It handles application ingress and TLS-enabled service exposure.

### cert-manager

cert-manager issues and renews certificates using the configured Let's Encrypt `ClusterIssuer`.

Cloudflare API credentials are loaded from the encrypted/local secrets file and are not committed to the repository.

### Cloudflare Tunnel

A Cloudflare Tunnel provides external connectivity without exposing the Kubernetes nodes directly.

The tunnel token is injected into a Kubernetes Secret during deployment.

## Longhorn Storage

Longhorn is the default Kubernetes StorageClass.

All K3s nodes are prepared for dedicated Longhorn storage at:

```text
/var/lib/storage/longhorn
```

The deployment process:

1. Runs `longhorn-host-prep.yml` on the nodes.
2. Annotates each Kubernetes node with the Longhorn disk configuration.
3. Installs Longhorn with Helm.
4. Waits for managers, drivers, UI, and pods.
5. Verifies every node has the expected dedicated storage path.
6. Makes `longhorn` the default StorageClass.
7. Removes default status from `local-path`.

Persistent application data is intentionally stored on Longhorn so it can be protected through Longhorn backup and restored independently during DR.

## Applications and Management Services

### Rancher

Rancher is installed by Helm in `cattle-system`.

The deployment includes:

- TLS certificate from cert-manager
- Traefik ingress
- two Rancher replicas
- bootstrap/admin credential configuration
- server URL configuration

### Portainer

Portainer CE provides a second management interface.

Its data is stored on a Longhorn PVC and is included in the protected DR application set.

### Trilium

Trilium is deployed with persistent Longhorn storage.

Protected PVC:

```text
trilium/trilium-data
```

### Vaultwarden

Vaultwarden is deployed with persistent Longhorn storage.

Protected PVC:

```text
vaultwarden/vaultwarden-data
```

The admin token and initial invitation address come from local encrypted secrets.

General sign-up/invitation behavior is controlled by the deployment manifest rather than documented with real credentials here.

## Monitoring

The monitoring stack uses `kube-prometheus-stack`.

Components include:

- Prometheus
- Alertmanager
- Grafana
- kube-state-metrics
- node-exporter
- Prometheus Operator
- Longhorn ServiceMonitor
- homelab baseline alert rules
- custom Grafana dashboards

Persistent monitoring data is stored on Longhorn.

Protected monitoring PVCs include:

- Grafana
- Prometheus
- Alertmanager

The deployment explicitly verifies that monitoring PVCs are Bound using the `longhorn` StorageClass.

## Logging

Cluster logging uses:

- Loki
- Grafana Alloy
- Grafana Loki datasource
- logging-focused Grafana dashboards

Loki storage is Longhorn-backed and is part of the tested DR recovery set.

Alloy collects Kubernetes logs and sends them to Loki.

## Protected Persistent Workloads

The DR configuration in `recovery/apps.conf` currently protects seven persistent workloads:

| Application | Namespace | Persistent data |
| --- | --- | --- |
| Trilium | `trilium` | `trilium-data` |
| Vaultwarden | `vaultwarden` | `vaultwarden-data` |
| Portainer | `portainer` | `portainer` |
| Grafana | `monitoring` | `monitoring-grafana` |
| Loki | `logging` | `storage-loki-0` |
| Prometheus | `monitoring` | Prometheus StatefulSet PVC |
| Alertmanager | `monitoring` | Alertmanager StatefulSet PVC |

The tested restore set currently totals approximately 175 GiB of provisioned persistent storage.

## Backup Design

Operational commands and verification criteria are documented in
[`backup-procedures.md`](backup-procedures.md).

There are two complementary backup layers.

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

Application data is backed up through Longhorn to the configured NFS Longhorn backup target.

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

## Disaster Recovery

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

The post-recovery readiness run on 2026-08-22 confirmed:

```text
Production nodes:    6/6 Ready
Protected workloads: 7
Fresh backups:       7
Stale backups:       0
Missing backups:     0
Restore capacity:    175.0 GiB
20% headroom target: 210.0 GiB
DR available:        358 GiB
DR preflight:        14 PASS / 0 WARN / 0 FAIL
Result:               DR READY
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

### Validated DR Result

The full automated rehearsal completed successfully on 2026-08-21.

Application/data validation:

```text
PASS: 20
WARN: 0
FAIL: 0
```

Post-cleanup DR preflight:

```text
PASS: 14
WARN: 0
FAIL: 0
```

Final result:

```text
RESULT: FULL DR REHEARSAL PASSED
```

The rehearsal proved:

- all seven current Longhorn restore volumes can be recovered
- large restores can safely resume after transient API pressure
- matching completed restores are detected as `SKIP-COMPLETE`
- correct existing PV/PVC bindings are idempotent
- Prometheus historical TSDB data is queryable
- Loki restored historical/index data is visible
- application databases are non-empty and readable
- cleanup returns the DR host to a clean baseline
- Longhorn backups remain untouched

See [`recovery/DR-RUNBOOK.md`](recovery/DR-RUNBOOK.md) for the complete procedure and recovery criteria.

## Repository Layout

```text
.
├── README.md
├── deploy.sh                       # End-to-end production deployment
├── dr-status.sh                    # Read-only DR readiness dashboard
├── site.yml                        # Explicit initial/bootstrap provisioning
├── maintenance/
│   ├── reconcile-existing-cluster.yml # Safe normal cluster reconciliation
│   └── reconcile-k3s-server.yml       # Safe single-server reconciliation
├── ansible.cfg
├── inventory/
│   ├── k3s-ansible/
│   │   ├── group_vars/
│   │   └── hosts.ini.template
│   └── sample/
├── roles/                          # K3s / host Ansible roles
├── config/
│   ├── cluster.env.example         # Non-secret environment template
│   └── email.env.example
├── apps/
│   ├── longhorn/
│   └── trilium/
├── backup/
│   ├── backup.sh
│   └── verify-backup.sh
├── recovery/
│   ├── DR-RUNBOOK.md
│   ├── apps.conf
│   ├── dr-preflight.sh
│   ├── dr-find-backups.sh
│   ├── dr-generate-restore.sh
│   ├── dr-validate-generated.sh
│   ├── dr-plan.sh
│   ├── dr-apply-restore.sh
│   ├── dr-bind-restores.sh
│   ├── dr-generate-validation.sh
│   ├── dr-apply-validation.sh
│   ├── dr-validate-apps.sh
│   ├── dr-cleanup.sh
│   └── dr-rehearsal.sh
├── .sops.yaml
└── .github/
```

Additional manifests and Helm values at the repository root define Traefik, Longhorn, monitoring, logging, Portainer, Trilium, Vaultwarden, Cloudflare, certificates, dashboards, and ingress behavior used by `deploy.sh`.

## Configuration and Secrets

Copy the public environment template:

```bash
cp config/cluster.env.example config/cluster.env
```

Populate local values for:

- base domain
- administrative email
- kube-vip address
- node addresses
- MetalLB range
- Cloudflare origin address
- NAS address
- NFS backup exports

Sensitive values should be kept in the encrypted/local secrets workflow and not committed in plaintext.

`deploy.sh` supports:

```text
.secrets.enc   # preferred, SOPS-encrypted
.secrets       # local fallback
```

Expected sensitive values include:

- Rancher bootstrap/admin credentials
- Cloudflare API/tunnel credentials
- Vaultwarden admin token
- initial Vaultwarden account address
- Vaultwarden SMTP username and password
- Vaultwarden Yubico secret key, when Yubico OTP is enabled
- Grafana admin password

The tracked Vaultwarden values template references Kubernetes Secrets and must
not contain credential values directly. `deploy.sh` creates or updates
`vaultwarden-admin` and `vaultwarden-integrations` from the corresponding
values in `.secrets.enc`.

## Repository Doctor

Use `repo-doctor.sh` as the read-only front-door health check before cluster
maintenance:

```bash
cd ~/Work/k3s-homelab
./repo-doctor.sh
```

It checks:

- Git branch, working-tree cleanliness, and `origin/main` synchronization
- supported Ansible/Python toolchain
- exact project-local Ansible collection versions and isolation
- `./deploy.sh --preflight-only`
- Kubernetes API and node readiness
- Cilium, kube-vip, and Longhorn volume health
- basic local secret/tracked-file hygiene
- the complete `./dr-status.sh` disaster-recovery readiness dashboard

For a faster local/cluster check that skips deployment preflight and DR:

```bash
./repo-doctor.sh --quick
```

Exit codes are `0` for healthy, `1` when attention is required, and `2` for
healthy with warnings. The command is read-only and never reconciles,
bootstraps, restores, or restarts the cluster.

## Operator Workstation Readiness

Before retiring or replacing an operator workstation or DR host, run the
complete ThinkPad/operator handoff check:

```bash
cd ~/Work/k3s-homelab
./workstation-readiness.sh
```

It runs, in order:

- the quick repository doctor
- deployment preflight
- rolling cluster maintenance in check mode
- production backup verification
- the DR readiness dashboard
- a plan-only DR rehearsal against the `k3s-dr` SSH alias

The wrapper never passes `--apply`, `--bootstrap`, or `--execute`. Backup
verification accesses the configured NFS export through a control-plane storage
proxy, and the DR plan-only rehearsal writes generated manifests and copies
validation input to the DR host, but neither operation changes production
workloads or restores data. No local sudo prompt is required.

Successful handoff ends with `RESULT: WORKSTATION READY`. Exit code `1` means
the workstation or DR path is not ready; exit code `2` means ready with
warnings. Logs are stored under `logs/readiness/`.

When intentionally testing without the replacement DR host, use `--no-dr` and
treat the resulting report only as operator-workstation validation—not as
complete retirement approval.

## Canonical Operating Model

Use these entry points consistently:

```bash
# 1. Routine health check
./repo-doctor.sh

# Complete operator-workstation / DR handoff validation
./workstation-readiness.sh

# 2. Validate all lifecycle entry points without changing the cluster
./workflow-check.sh

# 3. Normal existing-cluster reconciliation
./deploy.sh --preflight-only
./deploy.sh

# 4. Initial/new-cluster bootstrap - explicit only
./deploy.sh --bootstrap --preflight-only
./deploy.sh --bootstrap

# 5. One control-plane server maintenance
ansible-playbook \
  -i inventory/k3s-ansible/hosts.ini \
  maintenance/reconcile-k3s-server.yml \
  -e target=<CONTROL_PLANE_IP> \
  --check

# Remove --check only after the maintenance check succeeds.

# 6. Disaster-recovery readiness
./dr-status.sh
```

The lifecycle rule is simple: **existing cluster is the default; bootstrap is
always explicit**. Single-server maintenance uses the dedicated maintenance
playbook, and DR readiness is checked independently through `dr-status.sh`.

`workflow-check.sh` validates all four lifecycle entry points without making
cluster changes. Individual modes are also available:

```bash
./workflow-check.sh existing
./workflow-check.sh bootstrap
./workflow-check.sh maintenance
./workflow-check.sh dr
```

## Safe Single-Node Maintenance

Use `maintain-node.sh` instead of remembering separate control-plane and worker
Ansible commands.

The safe default is check mode only:

```bash
./maintain-node.sh 192.168.1.212
./maintain-node.sh 192.168.1.214
```

The wrapper determines whether the target is a control-plane server or worker,
selects the correct dedicated maintenance playbook, verifies the existing-node
safeguards, and runs Ansible `--check`.

To perform the live reconciliation after check mode passes:

```bash
./maintain-node.sh 192.168.1.212 --apply
```

Live mode requires typing `APPLY <TARGET>` before Ansible changes the node. For
explicit non-interactive maintenance:

```bash
./maintain-node.sh 192.168.1.214 --apply --yes
```

After live maintenance the wrapper requires the Kubernetes API and target node
to return healthy, verifies Cilium on the node, verifies kube-vip for a
control-plane target, and runs the quick repository doctor.

## Common Operations

### Preflight normal production reconciliation

```bash
cd ~/Work/k3s-homelab
./deploy.sh --preflight-only
```

### Deploy / converge an existing production cluster

```bash
./deploy.sh
```

### Bootstrap a new cluster

Bootstrap is explicit and should not be used for normal production
reconciliation:

```bash
./deploy.sh --bootstrap --preflight-only
./deploy.sh --bootstrap
```

### Reconcile one control-plane server

```bash
ansible-playbook   -i inventory/k3s-ansible/hosts.ini   maintenance/reconcile-k3s-server.yml   -e target=<CONTROL_PLANE_IP>
```

### Verify production nodes

```bash
kubectl get nodes -o wide
```

### Verify Longhorn

```bash
kubectl -n longhorn-system get nodes.longhorn.io
kubectl -n longhorn-system get backuptarget default -o wide
```

### Create a cluster recovery bundle

```bash
./backup/backup.sh
```


### Verify the latest backup

```bash
./backup/verify-backup.sh
```

### Check DR readiness

```bash
./dr-status.sh
```

Expected healthy result:

```text
RESULT: DR READY
```

### Non-destructive DR plan

```bash
./recovery/dr-rehearsal.sh
```

### Full guarded DR rehearsal

```bash
./recovery/dr-rehearsal.sh --execute
```

### Read the detailed DR runbook

```bash
less recovery/DR-RUNBOOK.md
```

## Repository Safety Notes

This repository contains infrastructure automation with cluster-admin impact.

Before committing changes:

- never commit live tokens, passwords, private keys, or decrypted SOPS data
- keep real inventory and local environment files ignored
- run `./deploy.sh --preflight-only` before normal production deployment
- use plain `./deploy.sh` only for existing-cluster reconciliation
- require explicit `--bootstrap` for initial cluster provisioning
- never bypass `KUBE_VIP` validation or rendered-control-plane assertions
- keep control-plane and agent reconciliation serial
- review generated restore manifests before applying them
- preserve the DR safety gates
- avoid granting blanket passwordless sudo
- keep privileged DR helpers root-owned on the DR host

### Repository secret handling

The repository has been hardened so the K3s cluster token is no longer stored
as plaintext in tracked Ansible variables.

Current Ansible configuration reads:

```yaml
k3s_token: "{{ lookup('env', 'K3S_TOKEN') }}"
```

`K3S_TOKEN` is provided through the local encrypted secrets workflow.

Repository history was reset to a sanitized public root commit on 2026-08-26.
The public history contains no earlier private commits; an encrypted local
backup was retained by the repository owner. The sanitized tree was checked
with the repository scanner and Gitleaks before publication.

Continue to treat `.secrets.enc` as the authoritative encrypted local secret
store and never commit decrypted secret material.

## DR Readiness / Status

`dr-status.sh` is the standard first DR command. It is a read-only readiness
dashboard and is safe to run during normal production operation.

The detailed `recovery/` helpers and `recovery/DR-RUNBOOK.md` remain the
authoritative execution procedure.


## Project Origins

This repository was originally based on and inspired by work from:

- `k3s-io/k3s-ansible`
- `geerlingguy/turing-pi-cluster`
- `212850a/k3s-ansible`

The current repository contains substantial additional homelab-specific deployment, observability, storage, backup, and recovery automation.

## License

See [`LICENSE`](LICENSE).
