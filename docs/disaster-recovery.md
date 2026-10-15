# Disaster recovery

[Back to the README](../README.md)

What to do when something bigger than one application breaks, and how
recovery is rehearsed. Backups themselves, and restoring one app's data, are
in [Backups](backups.md).

| What happened | Go to |
| --- | --- |
| One app's data is wrong or lost | [Restore one application](backups.md#restore-one-application) |
| A bad change broke an app or Argo CD | [Undo a bad change](how-to.md#undo-a-bad-change) |
| Both laptops are gone | [Set up a laptop from nothing](#set-up-a-laptop-from-nothing) |
| The whole cluster is gone | [Rebuild the cluster](#rebuild-the-cluster) |
| Nothing is wrong; prove it would work | [Rehearsals](#rehearsals) |

A recovery counts only when the application starts and its data can be read
in the application. A restored volume or a running pod is not enough.

## Rebuild the cluster

For when the nodes are reinstalled or replaced and nothing of the old cluster
is left. The whole sequence, data included, has been tested on the test
cluster; the [changelog](CHANGELOG.md) has the results.

### 1. What you need

- A laptop with `kubectl`, `helm`, `sops`, `age` and the repository's Python
  environment (see [Laptop setup](laptop-setup.md)).
- The laptop age key, in `~/.config/sops/age/keys.txt`. The copy is in
  Bitwarden, record "SOPS AGE KEY".
- Both repositories cloned side by side: this one and `k3s-homelab-config`.
- The private files: `.secrets.enc`, `config/cluster.env` and
  `inventory/k3s-ansible/hosts.ini`. `k3s-sync pull` brings them from the
  other laptop; otherwise take them from the latest recovery bundle with
  `recovery/restore.sh --restore-repo` (needs the NAS and sudo).
- The NAS, with the Longhorn backups and recovery bundles, and Unraid for
  Velero.

### 2. Prepare the nodes

Each of the six nodes needs Ubuntu, the cluster SSH key, the address in
`hosts.ini`, and a second disk mounted as ext4 `/dev/sda1` on
`/var/lib/storage`, in `/etc/fstab`. `longhorn-host-prep.yml` stops without
that disk.

### 3. Run the bootstrap

```bash
./deploy.sh --bootstrap --preflight-only
./deploy.sh --bootstrap
```

About 25 minutes. Ansible builds K3s, Cilium, kube-vip and MetalLB; `deploy.sh`
installs Argo CD, gives it its two Secrets, and installs Longhorn. Argo CD
then deploys every application from git, and `deploy.sh` waits for all of
them and every certificate, then creates the first Vaultwarden invitation.

The Cloudflare tunnel token is in the configuration repository, so the
public hostnames reconnect by themselves; nothing changes in Cloudflare.
Ten certificates are requested, within Let's Encrypt's limit of five
identical certificates a week as long as the cluster is not rebuilt more than
five times in a week.

### 4. Log in to Argo CD

The first login uses the generated password in the
`argocd-initial-admin-secret` Secret. Read it in your own terminal, change it
in the UI (User Info, Update Password), store it in Bitwarden, then delete
that Secret.

### 5. Restore the data

The rebuilt apps start empty. Longhorn on the new cluster reads the old
backups from the NAS within a few minutes. For each app in
`recovery/apps.conf`, Vaultwarden and Trilium first:

```bash
recovery/restore.sh --list-backups vaultwarden     # the old volume, by claim
recovery/restore.sh --restore-app vaultwarden      # newest backup of the old volume
kubectl -n vaultwarden exec -it vaultwarden-restore-inspect -- sh   # look first
recovery/restore.sh --promote-app vaultwarden --confirm
recovery/restore.sh --accept-app vaultwarden --confirm
```

With no backups of its own, the new volume makes `--restore-app` fall back to
the old volume that held the same claim. Once the nightly backup has run on
the new cluster it has backups of the empty volume too, and those become the
default: then use `--from-volume` with the old volume from `--list-backups`.
Check each app in its own UI before accepting. See
[Restore one application](backups.md#restore-one-application).

Do not delete the backups on the NAS, and do not point the new cluster's
Longhorn at a different share.

### 6. Protect the new cluster

```bash
./backup/backup.sh
kubectl -n longhorn-system create job --from=cronjob/backup-nightly "manual-$(date +%s)"
./dr-status.sh          # until DR READY
```

The timers on `dev` keep running and pick up the new cluster by themselves.

### Another way: restore etcd

Restoring the bundle's etcd snapshot onto the new servers (K3s
`--cluster-reset --cluster-reset-restore-path`, with the same `K3S_TOKEN`)
brings back every Kubernetes object, including the volume claims under their
old names. It has been tested only in a sealed container, not on nodes; see
[Testing an etcd snapshot restore](#testing-an-etcd-snapshot-restore). The
volumes' data would still come from the Longhorn backups.

## Set up a laptop from nothing

1. Install the tools: [Laptop setup](laptop-setup.md).
   The dotfiles repository installs the cluster tools.
2. Put the age key from Bitwarden in `~/.config/sops/age/keys.txt` (mode
   600).
3. Clone `k3s-homelab`, `k3s-homelab-config` and `k3s-homelab-private`
   under `~/Work`.
4. Take the private files from the latest bundle:
   `recovery/restore.sh --restore-repo`, then copy `.secrets.enc`,
   `.secrets.test.enc`, `config/cluster.env` and
   `inventory/k3s-ansible/hosts.ini` into the clone. The optional
   `config/email.env` (mail settings for the DR alerts) is not in the
   bundle.
5. Copy `/etc/rancher/k3s/k3s.yaml` from a control-plane node to
   `~/.kube/config` (mode 600), with the server address changed to the
   kube-vip address, and check with `./dr-status.sh`.
6. On the laptop that will be always on, run `./install-dr-timers.sh`.

## Rehearsals

Two separate machines are used, both on the `ubuntu-hp` server, which is
switched on only for them:

- **The DR host**, `k3s-dr`: restores production's backups and checks the
  apps can read them. Nothing on production changes.
- **The test cluster**: six throwaway VMs on a sealed network, for proving a
  bootstrap or a full rebuild.

```bash
./recovery/dr-host-power.sh status | on | off
```

The script powers the server through its iLO, with the login in
`~/.config/ilo-ubuntu-hp` (or `DR_ILO_USERNAME`/`DR_ILO_PASSWORD` in
`.secrets.enc`).

### Rehearse a restore on the DR host

```bash
./dr-status.sh                          # must be DR READY
./recovery/dr-rehearsal.sh              # plan only: checks, restore and validation manifests
./recovery/dr-rehearsal.sh --execute    # the whole rehearsal, unattended
```

`--execute` restores the latest backup of every protected volume onto the DR
host one at a time, binds each to a claim, starts an isolated copy of each
app with no route to it, checks the data at application level (Trilium's
notes, Vaultwarden's database, Prometheus's history, Loki's logs and so on),
then removes everything it made. If a check fails it stops and leaves the
restored state for a look. The DR host needs room for every protected volume
plus 20%, which `dr-status.sh` checks.

The DR host is a VM (8 vCPUs, 32 GB, 500 GB) with K3s, Cilium and Longhorn
pointed at production's backup target. `recovery/dr-host-build.sh` builds or
converges it, matching production's versions, and installs the helpers it
runs under `/usr/local/libexec/k3s-dr/`, the only commands it may run with
passwordless sudo.

`ubuntu-hp` also keeps a copy of the NAS backup share in `tank/backup/k3s`,
refreshed each time it boots (`recovery/k3s-backup-replicate.sh`), so it is
only as fresh as the last time the server was on.

### Rehearse a rebuild on the test cluster

```bash
./recovery/dr-test-cluster.sh create      # network and seven VMs, about 3 minutes
./recovery/dr-test-cluster.sh bootstrap   # site.yml only: K3s, kube-vip, Cilium, MetalLB
./recovery/dr-test-cluster.sh status
./recovery/dr-test-cluster.sh destroy-nodes   # delete the nodes, keep the stand-in NAS and its backups
./recovery/dr-test-cluster.sh destroy
```

`destroy-nodes` then `create` gives brand-new nodes with the backups still on
the stand-in NAS, which is how a rebuild with data is rehearsed. Six nodes (three servers, three workers) and a stand-in NAS at `10.90.0.8`
sit on `10.90.0.0/24`. They reach the internet but nothing on the home
network, which `create` checks. Nothing from production is copied in.

A full `deploy.sh --bootstrap` against these VMs proves a rebuild with every
application. Never run it from the normal checkout: `deploy.sh` writes the
inventory into the repository and would point Ansible at the test nodes. Use
a separate clone:

1. Clone the repository somewhere private, for example
   `~/.local/state/k3s-homelab/deploy-test/repo`, and copy `.ansible/` into
   it.
2. Copy `envs/test/cluster.env` from the configuration repository to the
   clone's `config/cluster.env`. Its `ARGOCD_APPS_CONFIG_PATH=envs/test/`
   keeps Argo CD on the test settings; without it the test cluster would
   deploy production's Secrets, tunnel token included, and serve the real
   sites. To test a branch, set `ARGOCD_APPS_REVISION`.
3. Build the clone's `.secrets.enc` from `.secrets.test.enc`, which has the
   test cluster's own token, tunnel, Cloudflare token for the test zone, and
   `dummy` for the stand-in NAS login. Add four lines from production's file,
   `ARGOCD_CONFIG_REPO_KEY_B64`, `WEBSITE_DEPLOY_KEY_B64`,
   `VAULTWARDEN_SMTP_USERNAME` and `VAULTWARDEN_SMTP_PASSWORD` (Authelia will
   not start without a working mail login), and the test cluster's own
   `ARGOCD_SOPS_AGE_KEY`, kept encrypted in the configuration repository as
   `envs/test/argocd-sops-age-key.enc.yaml`. Then run
   `CONFIG_REPO=<path to k3s-homelab-config> scripts/render-argocd-secrets.sh`
   from the clone and push the configuration repository.
4. In the clone only, set `flannel_iface` and `cilium_iface` to `enp1s0` in
   `inventory/k3s-ansible/group_vars/all.yml`.
5. In a terminal of its own, open a SOCKS proxy: `ssh -N -D 127.0.0.1:1080
   ubuntu-hp`. In the working terminal export `HTTPS_PROXY`, `HTTP_PROXY`
   and `ALL_PROXY` as `socks5://127.0.0.1:1080` (not `socks5h`),
   `NO_PROXY=localhost,127.0.0.1`, `ANSIBLE_SSH_COMMON_ARGS` with the
   `ProxyJump` options `dr-test-cluster.sh` uses, `KUBECONFIG_TARGET` and
   `KUBECONFIG` to a file outside `~/.kube`, and `SKIP_SYNC_CHECK=true`.
6. From the clone: `./deploy.sh --preflight-only --bootstrap`, then
   `./deploy.sh --bootstrap`.

The test cluster uses Let's Encrypt's staging service, so its certificates
are untrusted but cost nothing against the real limits. To browse it:

```bash
chromium --user-data-dir=/tmp/k3s-test-browser \
  --proxy-server="socks5://127.0.0.1:1080" \
  --host-resolver-rules="MAP example.test 10.90.0.100, MAP *.example.test 10.90.0.100"
```

Afterwards run `dr-test-cluster.sh destroy` and delete the clone, which holds
real secrets.

### Testing an etcd snapshot restore

`dr-rehearsal.sh` restores volumes, not etcd. The etcd snapshot is tested in a
container that cannot reach the network and runs no workloads, so kube-vip,
MetalLB and cloudflared never start against the real addresses.

With the snapshot copied out of a bundle to `$W/snapshot` and `$W/env` (mode
600) holding `K3S_TOKEN=<the cluster token>`:

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
Without the token the restore stops with `please pass --token`; with the
wrong one, `bootstrap data already found and encrypted with different
token`.
