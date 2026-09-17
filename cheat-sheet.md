# K3s Maintenance Cheat Sheet

Use this runbook for routine reconciliation of the existing production cluster.
These scripts never bootstrap a node. They default to read-only check mode and
require an explicit `--apply` before making changes.

## Which script to use

| Script | Purpose | Normal use |
| --- | --- | --- |
| `workstation-readiness.sh` | Validate the operator workstation, backups, and DR path | Before retiring or replacing the workstation/DR host |
| `update-os.sh` | Rolling OS package updates with conditional reboots and reports | Routine Debian/Ubuntu OS patching |
| `maintain-cluster.sh` | Safely reconcile the complete cluster | Preferred for routine maintenance |
| `maintain-node.sh` | Safely reconcile exactly one inventory node | Troubleshooting or targeted maintenance |
| `tests/test-workstation-readiness.sh` | Mock readiness success, warning, and failure | Run after editing the readiness wrapper |
| `tests/test-maintain-node-validation.sh` | Mock success and post-maintenance failures | Run after editing validation logic |
| `tests/test-maintain-cluster.sh` | Mock ordering and stop-on-failure behavior | Run after editing the rolling wrapper |

`maintain-cluster.sh` delegates every target to `maintain-node.sh`. Workers are
processed first, followed by control-plane nodes, and only one node is processed
at a time. The rolling run stops immediately if any node fails.

The standalone `playbooks/apt-update.yaml` and `reboot.yml` playbooks are also
strictly serial (`serial: 1`) and stop on the first failure. Do not run package
updates or reboots with an ad-hoc Ansible command that targets all six nodes in
parallel.

## Rolling OS package updates

`maintain-node.sh` and `maintain-cluster.sh` reconcile K3s; they do not upgrade
OS packages. Use the dedicated updater for Debian/Ubuntu package maintenance:

```bash
cd ~/Work/k3s-homelab
source .venv/bin/activate
./update-os.sh
./update-os.sh --apply
```

The default is a read-only remote preview using the nodes' existing APT indexes;
it writes local plans and logs. Apply refreshes the indexes, so available updates
may differ from the preview. Type `UPDATE OS` to confirm. Add
`--ask-become-pass` if sudo needs a password (each Ansible invocation prompts).
Explicit unattended runs can use `--apply --yes`.

The updater discovers inventory workers first, then control-plane nodes, and:

1. Checks inventory/node identity, roles, existing K3s service, API readiness,
   all Node Ready conditions, Cilium, kube-vip, Longhorn volumes, and system controllers.
2. In apply mode, refreshes APT indexes and assesses package work and pending
   reboots before cordoning. Nodes with neither are reported as `UP-TO-DATE` and
   skip backups, drain, upgrades, and recovery waits. If every node is up to date,
   the run reports that no maintenance is needed and exits successfully.
   A pending reboot still requires maintenance even when no packages need updating.
   For nodes needing maintenance, checks cluster/Velero backup freshness.
3. Cordons and drains one node, honoring disruption budgets. Drain deletes
   `emptyDir` data; unmanaged pods block the run rather than being forcibly removed.
4. Applies safe upgrades against the assessed indexes without package removals.
   Reboots only when `/var/run/reboot-required` exists and waits for SSH and K3s.
5. Waits for API, all nodes, Cilium and kube-vip; uncordons the target; then waits
   for Longhorn volumes and system controllers to recover before the next node.
6. Prints each node's result, exact package version changes, kernel/K3s versions,
   reboot status, held packages, and distro upgrade availability.

On Ubuntu, both preview and apply also run `do-release-upgrade --check-dist-upgrade-only`
with a 120-second limit, honoring the node's configured release-upgrade policy
(including LTS-only notifications). This may refresh release metadata caches but
never installs a distro upgrade or opts into development releases. The summary
reports `AVAILABLE` with the target release when supplied, `NONE`, `DISABLED`,
or `UNKNOWN` for missing tools, network errors, or timeouts. Other distributions
report `UNSUPPORTED`; release-check failures do not block routine package updates.
Raw results are retained in each node's `release-check.json`.

Reports are in `logs/os-updates/<timestamp>/`: `run.log`, `summary.txt`,
`summary.json`, and numbered node directories containing `plan.txt` and package
snapshots. Failed package operations attempt to capture partial changes. If the
node is unreachable, the report explicitly says actual changes are unavailable.

Any failure stops the run; later nodes are marked `SKIP`. A failed drained node
stays cordoned. If full recovery fails after uncordoning, the script attempts to
cordon it again. Inspect the log, repair the node, verify cluster health, then
manually `kubectl uncordon <NODE_NAME>` before starting another run. Previously
cordoned nodes block startup. There is no automatic package rollback.

Recovery waits default to 3600 seconds (one hour) per phase; override with
`--health-timeout <seconds>`. Reboot/SSH recovery has a separate 900-second timeout.
The workstation requires the project Ansible toolchain, Python, `kubectl` with
the production context, and backup verification access. Nodes need `python3-apt`
already installed. This performs package updates within the current distribution,
not distribution release upgrades or a K3s version upgrade.

## Workstation and DR-host handoff

Before powering off or replacing the current operator workstation or DR host,
run the complete read-only/plan-only handoff workflow from the ThinkPad:

```bash
cd ~/Work/k3s-homelab
./workstation-readiness.sh
```

Do not retire the existing DR host unless the report ends with:

```text
RESULT: WORKSTATION READY
```

The report covers the repository and toolchain, deployment preflight, rolling
maintenance check mode, production backup verification, `k3s-dr` connectivity
and preflight, and DR restore-plan validation. Logs are written to
`logs/readiness/`. Expect one sudo authentication request before the backup
verification stage if no sudo credential is currently cached.

Optional skips are available for targeted troubleshooting:

```bash
./workstation-readiness.sh --no-maintenance
./workstation-readiness.sh --no-backup
./workstation-readiness.sh --no-dr
```

A report produced with skipped checks is not sufficient approval to retire the
current DR host.

## Recommended full-cluster procedure

### 1. Prepare the repository

```bash
cd ~/Work/k3s-homelab
git pull --ff-only
git status --short
```

Confirm that the project virtual environment is active:

```bash
echo "$VIRTUAL_ENV"
command -v ansible
ansible --version
```

`ansible` should resolve from `~/Work/k3s-homelab/.venv/bin/`.

### 2. Run the read-only rolling check

```bash
./maintain-cluster.sh
```

This performs each node's inventory checks, existing-node safeguards, cluster
health checks, and Ansible check mode. It makes no node changes.

Proceed only when the run ends with:

```text
ROLLING CLUSTER MAINTENANCE: PASS
```

### 3. Review the plan and log

The wrapper prints the log path near the beginning and end of the run. Logs are
stored under:

```text
logs/maintenance/maintain-cluster-YYYYMMDD-HHMMSS.log
```

Confirm that every expected worker and control-plane node appears in the target
list and has a `PASS` result.

### 4. Apply the rolling maintenance

```bash
./maintain-cluster.sh --apply
```

At the prompt, type exactly:

```text
APPLY CLUSTER
```

The wrapper repeats check mode before applying each node. It then validates the
node and cluster before moving to the next target.

Before changing a node, the wrapper verifies fresh cluster and Velero backups,
cordons the node, and drains evictable workloads while honoring disruption
budgets. The node is uncordoned only after post-maintenance validation passes;
failures leave the rolling run stopped and attempt to restore schedulability.

### 5. Confirm the final result

The run is successful only when it ends with:

```text
ROLLING CLUSTER MAINTENANCE: PASS
```

Each applied node must pass:

- Kubernetes API `/readyz`
- target Kubernetes Node `Ready`
- Cilium pod health on the target node
- kube-vip pod health on control-plane targets
- all Longhorn volumes attached and healthy
- the quick repository doctor

### Failure and rollback handling

If drain, Ansible reconciliation, or post-maintenance validation fails, the
rolling run stops before touching another node. The wrapper attempts to
uncordon the failed node, but confirm with:

```bash
kubectl get nodes
kubectl describe node <NODE_NAME> | grep -E 'Unschedulable|Conditions:'
```

Do not continue the rolling run until the node is Ready, schedulable, and the
cluster health checks pass. For a bad K3s binary or kernel, restore the prior
package/kernel from the node's package manager or bootloader, rerun the
single-node check, and only then resume the cluster wrapper. Never roll back
two control-plane nodes at once; preserve at least two healthy etcd members.

## Single-node maintenance

Use the single-node wrapper when troubleshooting or intentionally changing only
one existing node.

### 1. Check the target without changes

```bash
./maintain-node.sh <TARGET>
```

`<TARGET>` must match exactly one host in either the inventory `node` or
`master` group.

### 2. Apply after check mode passes

```bash
./maintain-node.sh <TARGET> --apply
```

At the prompt, type exactly:

```text
APPLY <TARGET>
```

Success ends with `POST-MAINTENANCE VALIDATION: PASS` followed by
`SINGLE-NODE MAINTENANCE COMPLETE`.

## Unattended execution

Both wrappers support `--apply --yes`, but reserve it for an explicitly approved
automation run with captured logs:

```bash
./maintain-cluster.sh --apply --yes
./maintain-node.sh <TARGET> --apply --yes
```

For normal interactive maintenance, omit `--yes` and use the confirmation
prompt.

## If a run fails

1. Do not continue with later nodes manually.
2. Note the failed target, failed validation, exit status, and log path.
3. Check the current cluster state:

   ```bash
   kubectl get --raw=/readyz
   kubectl get nodes -o wide
   kubectl -n kube-system get pods -l k8s-app=cilium -o wide
   kubectl -n kube-system get pods -l name=kube-vip-ds -o wide
   kubectl -n longhorn-system get volumes.longhorn.io
   ```

4. Correct the underlying problem.
5. Rerun check mode for only the failed node:

   ```bash
   ./maintain-node.sh <FAILED_TARGET>
   ```

6. After that passes, apply the failed node interactively. Then restart the
   full rolling check before resuming cluster-wide maintenance.

A nonzero exit status means maintenance or validation failed. Capture it
immediately when troubleshooting:

```bash
echo $?
```

## Tests after changing maintenance scripts

Run the isolated safety tests before testing against the live cluster:

```bash
./tests/test-maintain-node-validation.sh
./tests/test-maintain-cluster.sh
./tests/test-workstation-readiness.sh
```

Expected result:

```text
Validation tests: 6 passed, 0 failed
Rolling wrapper tests: 2 passed, 0 failed
Workstation readiness tests: 3 passed, 0 failed
```

Then run shell and repository checks:

```bash
bash -n maintain-node.sh
bash -n maintain-cluster.sh
bash -n workstation-readiness.sh
pre-commit run --files \
  maintain-node.sh \
  maintain-cluster.sh \
  workstation-readiness.sh \
  tests/test-maintain-node-validation.sh \
  tests/test-maintain-cluster.sh \
  tests/test-workstation-readiness.sh
```

Finally, run `./maintain-cluster.sh` in check-only mode against the real
inventory before authorizing any live apply.

## Safety rules

- Use `maintain-cluster.sh` for normal full-cluster maintenance.
- Always run check mode before `--apply`.
- Never maintain multiple nodes in parallel.
- Never skip a failed node and continue with later targets.
- Do not use bootstrap playbooks for existing nodes.
- Do not shorten post-maintenance validation waits in production.
- Keep maintenance logs until the complete run has been reviewed.
