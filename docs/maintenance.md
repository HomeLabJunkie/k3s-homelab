# Maintenance

[Back to the README](../README.md)

Looking after the nodes and the parts Argo CD does not manage: K3s, Cilium,
kube-vip, MetalLB and Longhorn. Everything else changes through a merged pull
request; see [How to](how-to.md).

Every command here starts read-only. Nothing changes until you add
`--apply` (or run plain `./deploy.sh`) and type the confirmation it asks for.

| Command | What it does | When |
| --- | --- | --- |
| `./repo-doctor.sh` | Read-only health check of the laptop, repository and cluster | Before any maintenance |
| `./maintain-cluster.sh` | Reconciles K3s on every node, one at a time | Routine maintenance |
| `./maintain-node.sh TARGET` | The same for one node | Troubleshooting one node |
| `./update-os.sh` | Rolling Debian/Ubuntu package updates, rebooting when needed | Routine OS patching |
| `./deploy.sh` | Reconciles the cluster, Argo CD's bootstrap and Longhorn | Node, Longhorn or deploy-created Secret changes |
| `./deploy.sh --bootstrap` | Builds a new cluster | Only for a new or rebuilt cluster |
| `./workstation-readiness.sh` | Checks a laptop can run and recover the cluster | Before retiring or replacing a laptop or the DR host |

## Rules

- Run the read-only check first, every time.
- One node at a time, never in parallel. This includes ad-hoc Ansible: the
  `playbooks/apt-update.yaml` and `reboot.yml` playbooks are already
  `serial: 1`.
- If a node fails, stop. Never skip it and carry on with the next one.
- Never take down two control-plane nodes at once: etcd needs two of the three
  healthy.
- Never use `--bootstrap` or the bootstrap playbooks on an existing cluster.
- Don't shorten the recovery waits on production.
- Keep the logs under `logs/` until you have read the run's result.
- Use `--yes` (skip the typed confirmation) only for an approved unattended
  run.

## Before you start

```bash
cd ~/Work/k3s-homelab
git pull --ff-only
./repo-doctor.sh
```

`repo-doctor.sh` checks the branch is clean and up to date with GitHub, the
Ansible toolchain and collections, `./deploy.sh --preflight-only`, the nodes,
Cilium, kube-vip and Longhorn, every manifest (through
`scripts/validate-manifests.sh`), secret hygiene, and `./dr-status.sh`. It
never changes anything. Exit `0` is healthy, `2` healthy with warnings, `1`
needs attention. `--quick` skips the preflight, manifests and DR.

The scripts put the repository's `.venv` first on `PATH` themselves, so you
don't need to activate it.

## Maintain the whole cluster

```bash
./maintain-cluster.sh            # check mode, changes nothing
./maintain-cluster.sh --apply    # type: APPLY CLUSTER
```

Read the check run first. It must end with `ROLLING CLUSTER MAINTENANCE: PASS`
and list every worker and control-plane node with `PASS`. The log is at
`logs/maintenance/maintain-cluster-YYYYMMDD-HHMMSS.log`.

The apply run hands each node to `maintain-node.sh`, workers first, then the
control plane. For each node it:

1. repeats check mode and confirms the cluster and Velero backups are fresh;
2. cordons and drains the node, honouring disruption budgets;
3. reconciles K3s with Ansible, restarting it only if its configuration
   changed;
4. checks the API (`/readyz`), the node's `Ready` condition, Cilium on the
   node and, on a control-plane node, kube-vip;
5. uncordons the node and waits up to 30 minutes for every Longhorn volume to
   be healthy again (Longhorn stops a cordoned node's replicas, so they
   rebuild only once it is back in service);
6. runs the quick repository doctor.

It stops at the first failure.

## Maintain one node

```bash
./maintain-node.sh 192.168.1.212            # check mode
./maintain-node.sh 192.168.1.212 --apply    # type: APPLY 192.168.1.212
```

The target must match exactly one host in the inventory's `master` or `node`
group. The script works out which kind it is and runs the right playbook and
checks. Success ends with `POST-MAINTENANCE VALIDATION: PASS` and
`SINGLE-NODE MAINTENANCE COMPLETE`.

To run the control-plane playbook directly, add `--check` first:

```bash
ansible-playbook -i inventory/k3s-ansible/hosts.ini \
  maintenance/reconcile-k3s-server.yml -e target=<CONTROL_PLANE_IP> --check
```

It refuses a target that is not an existing etcd member.

## If a node fails

Where it failed decides what state the node is left in:

- **The drain failed:** nothing changed, and the node is uncordoned.
- **The node's own checks failed after reconciling:** it stays cordoned.
- **Longhorn didn't recover in time:** the node passed its own checks, so it
  stays in service and its replicas keep rebuilding.

Then:

1. Note the node, the failed check, the exit code and the log path.
2. Look at the cluster:

   ```bash
   kubectl get --raw=/readyz
   kubectl get nodes -o wide
   kubectl -n kube-system get pods -l k8s-app=cilium -o wide
   kubectl -n kube-system get pods -l name=kube-vip-ds -o wide
   kubectl -n longhorn-system get volumes.longhorn.io
   ```

3. Fix the cause. For a bad K3s binary or kernel, go back to the previous
   package or kernel through the package manager or bootloader.
4. Run `./maintain-node.sh <NODE>` until it passes, then `--apply` it.
5. Run the full `./maintain-cluster.sh` check again before resuming.

## Update the OS packages

`maintain-*` reconciles K3s; it does not update packages. `update-os.sh` does:

```bash
./update-os.sh            # preview, changes nothing
./update-os.sh --apply    # type: UPDATE OS
```

The preview uses each node's existing package lists. Apply refreshes them
first, so it may find more. Nodes need `python3-apt`. Add `--ask-become-pass`
if sudo needs a password on the nodes.

Apply goes workers first, one node at a time. A node with no updates and no
pending reboot is reported `UP-TO-DATE` and left alone. For each other node it
checks backups are fresh, drains it, installs the updates (never removing a
package), reboots only if `/var/run/reboot-required` exists, waits for K3s,
the nodes, Cilium and kube-vip, uncordons it, and waits for Longhorn and the
system controllers before the next node. Each recovery wait allows an hour
(`--health-timeout SECONDS`); the reboot allows 15 minutes.

It stays within the current release: no distribution upgrade and no K3s
version change. On Ubuntu it reports whether a new release is available
(`AVAILABLE`, `NONE`, `DISABLED` or `UNKNOWN`) without installing it.

The report is in `logs/os-updates/<timestamp>/`: `summary.txt`, `summary.json`,
`run.log`, and a folder per node with its plan and package versions before and
after.

**If it fails:** later nodes are marked `SKIP` and the failed node stays
cordoned. There is no automatic package rollback. Read the log, fix the node,
check the cluster, then `kubectl uncordon <NODE>` yourself. A cordoned node
blocks the next run from starting.

## deploy.sh

After the cluster and Longhorn, `deploy.sh` installs nothing itself: Argo CD
deploys everything else from `main`, its own chart included. A chart or
setting change needs a merged pull request, not a `deploy.sh` run. Run
`deploy.sh` to build a cluster, to change the nodes or Longhorn, or after
changing a Secret it creates itself.

**Existing cluster (the default).**

```bash
./deploy.sh --preflight-only   # ends: DEPLOYMENT PREFLIGHT PASSED / No cluster changes were made.
./deploy.sh
```

This runs `maintenance/reconcile-existing-cluster.yml`: control-plane nodes
one at a time, then workers, restarting K3s only where its configuration
changed and waiting for each node to be ready. It never runs `--cluster-init`
against an existing etcd member. Then it checks the kubeconfig through
kube-vip, installs Argo CD if the cluster has none, installs or checks
Longhorn, and waits for every Argo CD application and certificate.

**New cluster (explicit only).**

```bash
./deploy.sh --bootstrap --preflight-only
./deploy.sh --bootstrap
```

This runs `site.yml`: prepare the nodes, install the K3s servers and agents,
and fetch the kubeconfig. [Disaster recovery](disaster-recovery.md) covers a
rebuild from start to finish.

**What the preflight checks.** Before Ansible touches anything, `deploy.sh`:

- runs `k3s-sync check` and stops if this laptop's `.secrets.enc`,
  `cluster.env` or checkout is behind GitHub (`SKIP_SYNC_CHECK=true`
  overrides it; it warns and carries on if GitHub is unreachable);
- loads `config/cluster.env` and requires every critical value, including a
  real, usable `KUBE_VIP` address (documentation ranges such as
  `192.0.2.0/24` are rejected);
- checks the Ansible syntax and the rendered server arguments
  (`--tls-san=<KUBE_VIP>`, `--node-ip=<NODE_IP>`, and no `--disable-agent` or
  `--disable-kube-proxy`).

**Toolchain.** `deploy.sh` refuses to run outside the versions in
`config/toolchain.env`:

```text
ansible-core >= 2.21.5 and < 2.22.0
Python       >= 3.11.0 and < 3.15.0
```

`requirements.txt` is the exact pip lock and `requirements.in` limits
ansible-core to 2.21.x; `scripts/check-requirements-toolchain-sync.sh` keeps
the two in step in CI. Ansible collections are pinned in
`collections/requirements.yml` and installed into `.ansible/collections/`
automatically when missing or wrong.

The inventory settings are in `inventory/k3s-ansible/group_vars/all.yml`;
the real `hosts.ini` is local and not in git.

## Other read-only checks

```bash
./workflow-check.sh             # all four entry points: existing, bootstrap, maintenance, dr
./scripts/validate-manifests.sh # every manifest, against the cluster's own CRDs
```

`validate-manifests.sh` uses `kubeconform` in strict mode against the
cluster's Kubernetes version and installed CRDs, so a misspelt field or a
value the installed Longhorn, Traefik or cert-manager does not accept shows up
before anything is applied. `--offline` reuses the schemas cached in
`~/.cache/k3s-homelab/manifest-schemas`. CI cannot run it (no cluster).

## Retiring or replacing a laptop

Set up a new laptop with [Laptop setup](laptop-setup.md).
Before retiring one, or the DR host, run this on the laptop that will remain:

```bash
./workstation-readiness.sh
```

It runs the quick doctor, the deploy preflight, maintenance check mode, the
production backup check, `./dr-status.sh`, and a plan-only DR rehearsal
against the `k3s-dr` SSH alias. It never passes `--apply`, `--bootstrap` or
`--execute`, and needs no local sudo: the backup check reaches the NAS
through a control-plane node. Logs go to `logs/readiness/`.

Retire nothing unless it ends with `RESULT: WORKSTATION READY`. `--no-maintenance`,
`--no-backup` and `--no-dr` skip a stage for troubleshooting, but a report
with skips is not approval.

## After changing the maintenance scripts

```bash
./tests/test-maintain-node-validation.sh
./tests/test-maintain-cluster.sh
./tests/test-workstation-readiness.sh
```

Each ends with `0 failed`; CI runs the lint. Then run `./maintain-cluster.sh` in check mode
against the real cluster before any `--apply`.
