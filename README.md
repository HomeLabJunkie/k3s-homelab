# k3s-homelab

Automated build, application deployment, observability, backup, and disaster-recovery tooling for a highly available K3s homelab cluster.

It manages the cluster from initial Ansible provisioning through application
deployment, persistent storage, monitoring and logging, verified backups, and a
tested end-to-end disaster-recovery rehearsal.

**New to all this?** Start with [How Our Home Cluster Works](docs/CLUSTER-STORY.md), a plain-English tour from six bare computers to the finished cluster.

## Architecture

The production cluster is currently operated as a six-node K3s cluster:

- 3 K3s server/control-plane/etcd nodes
- 3 K3s agent/worker nodes
- Ubuntu 26.04 LTS
- K3s `v1.36.5+k3s1`

Core platform:

| Layer | Current implementation |
| --- | --- |
| Kubernetes | K3s HA with embedded etcd |
| API HA | kube-vip |
| CNI | Cilium native routing |
| Network observability | Hubble relay + UI |
| Service load balancing | MetalLB Layer 2 |
| Ingress | Traefik |
| Admin UI login | Authelia (two-factor, Traefik forward-auth) |
| TLS | cert-manager + Let's Encrypt |
| External access | Cloudflare Tunnel |
| Persistent storage | Longhorn |
| Cluster management | Rancher |
| Metrics | kube-prometheus-stack |
| Dashboards | Grafana |
| Logging | Loki + Grafana Alloy |
| Security scanning | Trivy Operator |
| GitOps | Argo CD deploys everything from git except the cluster itself and Longhorn, which `deploy.sh` builds |
| Policy | Kyverno (enforced in the application namespaces, audit elsewhere) |
| Backup storage | Garage S3 on Unraid plus NFS and SMB on a separate NAS |
| DR | Recovery bundle, tested rebuild and restore, rehearsals on a separate server |

Environment-specific addresses, domains, email addresses, backup exports, and VIP ranges belong in `config/cluster.env` and local inventory/secrets rather than in this README.

```text
Clients / Cloudflare                kubectl / automation
        |                                   |
        v                                   v
Cloudflare Tunnel / LAN              kube-vip :6443
        |                                   |
        v                                   +---- K3s server 0
MetalLB service address                     +---- K3s server 1
        |                                   +---- K3s server 2
        v
Traefik --> Authelia (admin UIs)
        |
        v
Kubernetes Services / Pods
```

## Start here

Run everything from `~/Work/k3s-homelab`. Every command that changes the
cluster has a read-only check to run first.

```bash
./repo-doctor.sh           # health of the laptop, repository and cluster
argocd app list            # every application Synced and Healthy
./dr-status.sh             # backups fresh, DR ready
```

Argo CD deploys everything from this repository's `main` branch except K3s,
Cilium, kube-vip, MetalLB and Longhorn, so most changes are a merged pull
request; see [How to](docs/how-to.md). Plain `./deploy.sh` reconciles the
**existing** cluster; building a new one is always explicit:
`./deploy.sh --bootstrap`.

## Documentation

| Topic | Read |
| --- | --- |
| Plain-English tour of the cluster | [How Our Home Cluster Works](docs/CLUSTER-STORY.md) |
| Everyday tasks: add an app, change a setting or secret, upgrade, undo | [How to](docs/how-to.md) |
| Node maintenance, OS updates, deploy.sh, preflight checks | [Maintenance](docs/maintenance.md) |
| How Argo CD deploys everything, sync policy, chart updates | [Argo CD](docs/argocd.md) |
| Networking, Traefik, certificates, Cloudflare, Longhorn | [Platform components](docs/platform.md) |
| Login portal, two-factor, Grafana single sign-on | [Authelia](docs/authelia.md) |
| Rancher, Trilium, Vaultwarden, the website | [Applications](docs/applications.md) |
| Prometheus, Grafana, alerts, Loki | [Monitoring and logging](docs/observability.md) |
| What is backed up, checking backups, restoring one app | [Backups](docs/backups.md) |
| Rebuilding the cluster or a laptop, DR rehearsals | [Disaster recovery](docs/disaster-recovery.md) |
| `cluster.env`, `.secrets.enc`, expected secret values | [Configuration and secrets](docs/configuration.md) |
| Setting up another laptop | [Laptop setup](docs/laptop-setup.md) |
| Where files live | [Repository layout](docs/repository-layout.md) |
| What changed and when | [Changelog](docs/CHANGELOG.md) |

## Safety rules

- Never commit tokens, passwords, private keys or decrypted SOPS data; real
  inventory and environment files stay ignored.
- Run the read-only check before anything that changes the cluster.
- Never use `--bootstrap` on an existing cluster.
- Nodes are changed one at a time; never two control-plane nodes at once.
- Keep the DR safety gates and the `KUBE_VIP` and control-plane checks.

## Project Origins

This repository was originally based on and inspired by work from:

- `k3s-io/k3s-ansible`
- `geerlingguy/turing-pi-cluster`
- `212850a/k3s-ansible`

The current repository contains substantial additional homelab-specific deployment, observability, storage, backup, and recovery automation.

## License

See [`LICENSE`](LICENSE).
