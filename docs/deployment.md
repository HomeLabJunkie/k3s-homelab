# Deployment and maintenance

[Back to the README](../README.md)

How `deploy.sh` and the maintenance wrappers change the cluster, and the
read-only checks to run first. For the step-by-step maintenance procedure, see
the [K3s maintenance cheat sheet](../cheat-sheet.md).

## Lifecycle modes

The main deployment entry point is `deploy.sh`. Deployment now has two
intentionally separate lifecycle modes so an existing production cluster is
never sent through initial bootstrap logic by accident.

The lifecycle rule is simple: **existing cluster is the default; bootstrap is
always explicit**.

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

## What deploy.sh does

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

### Preflight protections

Before Ansible can modify K3s, `deploy.sh`:

- runs `k3s-sync check` (from the private companion repo) and stops if this
  laptop's private files (`.secrets.enc`, `cluster.env`) or this checkout are
  behind GitHub, so stale secrets never reach the cluster. It warns and continues
  when GitHub is unreachable or `k3s-sync` isn't installed; `SKIP_SYNC_CHECK=true`
  overrides it on purpose.
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

### Automation toolchain guard

Before loading Ansible collections, `deploy.sh` validates the host automation
toolchain against `config/toolchain.env`.

Supported ranges:

```text
ansible-core >= 2.21.4 and < 2.22.0
Python       >= 3.11.0 and < 3.15.0
```

This prevents a Homebrew or operating-system upgrade from silently moving
the repository onto an unvalidated Ansible major/minor series while still
allowing compatible 2.21.x patch updates.

`requirements.txt` remains the exact pip lock. `requirements.in` constrains
ansible-core to the supported 2.21.x series. The `ANSIBLE_CORE_*` bounds in
`config/toolchain.env` are kept in lockstep with that constraint by
`scripts/check-requirements-toolchain-sync.sh`, which runs in CI.

### Automatic Ansible dependency bootstrap

`deploy.sh` verifies the project-local Ansible collections before running any Ansible playbook. Exact versions are declared in `collections/requirements.yml` and installed under `.ansible/collections/`, which remains ignored by Git. Missing or mismatched dependencies are installed automatically with `ansible-galaxy`; matching dependencies are left untouched.

## Ansible provisioning

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

## Maintaining nodes

### One node

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

### One control-plane server with Ansible directly

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

Add `--check` first, and remove it only after the maintenance check succeeds.

### The whole cluster, one node at a time

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

### Rolling OS package updates

Use `./update-os.sh` to preview Debian/Ubuntu OS package updates, then
`./update-os.sh --apply` to update workers before control-plane nodes, one at a
time. The updater drains each target, reboots when required, verifies K3s and
Kubernetes recovery, and records package/kernel changes in `logs/os-updates/`.
It stops on failure and leaves the affected drained node cordoned for recovery.
See [the OS update runbook](../cheat-sheet.md#rolling-os-package-updates) for setup,
health gates, reports, and failure handling.

## Read-only checks

### Repository doctor

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
- every Kubernetes manifest, through `scripts/validate-manifests.sh`
- basic local secret/tracked-file hygiene
- the complete `./dr-status.sh` disaster-recovery readiness dashboard

For a faster local/cluster check that skips deployment preflight, manifest
validation and DR:

```bash
./repo-doctor.sh --quick
```

Exit codes are `0` for healthy, `1` when attention is required, and `2` for
healthy with warnings. The command is read-only and never reconciles,
bootstraps, restores, or restarts the cluster.

### Quick kubectl checks

```bash
kubectl get nodes -o wide
kubectl -n longhorn-system get nodes.longhorn.io
kubectl -n longhorn-system get backuptarget default -o wide
```

### Lifecycle entry points

`workflow-check.sh` validates all four lifecycle entry points without making
cluster changes. Individual modes are also available:

```bash
./workflow-check.sh existing
./workflow-check.sh bootstrap
./workflow-check.sh maintenance
./workflow-check.sh dr
```

### Manifest validation

`scripts/validate-manifests.sh` checks every Kubernetes manifest in the
repository with `kubeconform`, including the rendered ones that Git ignores:

```bash
./scripts/validate-manifests.sh
./scripts/validate-manifests.sh --offline website.yaml
```

It validates in strict mode against the cluster's own Kubernetes version and
the CRDs installed in it, so a misspelt field or a value the installed
Longhorn, Traefik, cert-manager, Velero or Prometheus version does not accept
is reported before anything is applied. Each online run exports the cluster's
CRD schemas to `~/.cache/k3s-homelab/manifest-schemas`; `--offline` reuses
them without contacting the cluster. Helm values files and unrendered
templates are not manifests and are skipped. It needs `kubeconform` on the
laptop and is not part of CI, which has no cluster to read the CRDs from.
`repo-doctor.sh` runs it as part of the full check and skips it under
`--quick`, `--no-manifests`, or when `kubeconform` is not installed.

### Operator workstation readiness

For a new Omarchy laptop, follow [Operator laptop setup](../operator-laptop-setup.md)
to install the tools and provision local access before running these checks.

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
