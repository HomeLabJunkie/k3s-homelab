# Laptop setup

[Back to the README](../README.md)

Setting up a laptop to run the cluster when another laptop already does. If
every laptop is lost, follow
[Set up a laptop from nothing](disaster-recovery.md#set-up-a-laptop-from-nothing)
instead: it takes the private files from the recovery bundle.

There are two laptops: `dev` is always on and runs the scheduled backup and
DR jobs; any other laptop runs none of them.

## 1. Tools

The dotfiles repository lists every tool and installs them with the rest of
the laptop's packages:

```bash
cd ~/dotfiles && ./bootstrap.sh --packages
```

The cluster tools in that list are `kubectl`, `helm`, `argocd`, `kubectx`
(and `kubens`), `cilium-cli`, `velero`, `trivy`, `k9s`, `kubeconform`,
`github-cli`, `sops`, `age`, `direnv`, `jq` and `go-yq`. `deploy.sh` also
needs `argon2`, which is in the list too.

The dotfiles also define an `argocd` shell function that uses kubectl's
access (`--core`), so `argocd app list` works without an Argo CD login.

## 2. Keys

Copy these from the other laptop over SSH, or from Bitwarden, never through
chat, email or git. Directories are mode `700`, files `600`.

| File | What it is |
| --- | --- |
| `~/.config/sops/age/keys.txt` | Opens `.secrets.enc` and the config repo's Secrets. Also in Bitwarden ("SOPS AGE KEY"). |
| `~/.ssh/k3s_homelab_ed25519` | SSH to the six nodes and the DR host |
| `~/.ssh/config` entries | The six node addresses, `k3s-dr`, `ubuntu-hp` |
| A GitHub SSH key | Clone and push the three repositories; then `gh auth login` |
| `~/.kube/config` | Cluster access through the kube-vip address |

## 3. Repositories

```bash
cd ~/Work
git clone git@github.com:HomeLabJunkie/k3s-homelab.git
git clone git@github.com:HomeLabJunkie/k3s-homelab-config.git
git clone git@github.com:HomeLabJunkie/k3s-homelab-private.git

cd k3s-homelab
python -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
./scripts/ensure-ansible-collections.sh
direnv allow
```

The `.envrc` puts `.venv` first on `PATH` when you enter the directory and
shows whether this laptop's private files are behind. It needs
`eval "$(direnv hook bash)"` in `~/.bashrc`, which the dotfiles already have.

## 4. Private files

The files Git ignores travel between laptops through the private repository:

```bash
~/Work/k3s-homelab-private/k3s-sync install
k3s-sync pull
./scripts/prepare-env.sh      # writes inventory/k3s-ansible/hosts.ini from cluster.env
```

`k3s-sync` carries `.secrets.enc`, `.secrets.test.enc`, `config/cluster.env`
and the website and search app sources. Its `GUIDE.md` covers the daily
habit: `k3s-sync pull` when you sit down, `k3s-sync push` when you get up.
`deploy.sh` refuses to run while this laptop is behind.

## 5. Check

```bash
kubectl get nodes
argocd app list
./repo-doctor.sh --quick
./deploy.sh --preflight-only
systemctl --user list-timers 'k3s-dr-*'
```

The last command should list nothing on any laptop except `dev`, which runs
`./install-dr-timers.sh` once. Before this laptop takes over from another, run
`./workstation-readiness.sh`; see
[Retiring or replacing a laptop](maintenance.md#retiring-or-replacing-a-laptop).
