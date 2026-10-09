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
| Backup storage | Garage S3 on Unraid plus NFS and SMB on a separate NAS |
| DR | Dedicated K3s DR host + automated rehearsal tooling |

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

## Everyday commands

Run everything from `~/Work/k3s-homelab`. Each command that changes the cluster
has a read-only check to run first.

| I want to... | Run | Changes the cluster? |
| --- | --- | --- |
| Check overall health | `./repo-doctor.sh` (`--quick` skips preflight, manifests and DR) | No |
| Check a deployment would be safe | `./deploy.sh --preflight-only` | No |
| Validate manifests before applying | `./scripts/validate-manifests.sh` | No |
| Deploy or converge the cluster | `./deploy.sh` | Yes |
| Check one node | `./maintain-node.sh <NODE_IP>` | No |
| Reconcile one node | `./maintain-node.sh <NODE_IP> --apply` | Yes |
| Check all nodes, one at a time | `./maintain-cluster.sh` | No |
| Reconcile all nodes, one at a time | `./maintain-cluster.sh --apply` | Yes |
| Preview OS package updates | `./update-os.sh` | No |
| Apply OS package updates | `./update-os.sh --apply` | Yes, reboots nodes |
| Create a cluster recovery bundle | `./backup/backup.sh` | No |
| Verify the latest backup | `./backup/verify-backup.sh` | No |
| Check DR readiness | `./dr-status.sh` | No |
| Plan a DR rehearsal | `./recovery/dr-rehearsal.sh` | No |
| Run a full DR rehearsal | `./recovery/dr-rehearsal.sh --execute` | DR host only |
| Validate a new operator laptop | `./workstation-readiness.sh` | No |

Plain `./deploy.sh` reconciles the **existing** cluster. Building a new cluster
is always explicit: `./deploy.sh --bootstrap`. Never use bootstrap mode on an
established cluster.

## Documentation

| Topic | Read |
| --- | --- |
| Plain-English tour of the cluster | [How Our Home Cluster Works](docs/CLUSTER-STORY.md) |
| How deployment and maintenance work, preflight checks, toolchain | [Deployment and maintenance](docs/deployment.md) |
| Step-by-step maintenance and OS updates | [Maintenance cheat sheet](cheat-sheet.md) |
| Networking, Traefik, certificates, Cloudflare, Longhorn | [Platform components](docs/platform.md) |
| Login portal, two-factor, Grafana single sign-on | [Authelia](docs/authelia.md) |
| Rancher, Trilium, Vaultwarden, the website | [Applications](docs/applications.md) |
| Prometheus, Grafana, alerts, Loki | [Monitoring and logging](docs/observability.md) |
| What is protected, backup layers, DR rehearsal | [Backup and disaster recovery](docs/backup-and-dr.md) |
| Backup commands, schedules, troubleshooting | [Backup procedures](backup-procedures.md) |
| Velero and Garage | [Velero backup procedures](velero-backup-procedures.md) |
| Full recovery procedure | [DR runbook](recovery/DR-RUNBOOK.md) |
| `cluster.env`, `.secrets.enc`, expected secret values | [Configuration and secrets](docs/configuration.md) |
| Setting up a new operator laptop | [Operator laptop setup](operator-laptop-setup.md) |
| Where files live | [Repository layout](docs/repository-layout.md) |
| What changed and when | [Changelog](docs/CHANGELOG.md) |

## Safety rules

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

## Project Origins

This repository was originally based on and inspired by work from:

- `k3s-io/k3s-ansible`
- `geerlingguy/turing-pi-cluster`
- `212850a/k3s-ansible`

The current repository contains substantial additional homelab-specific deployment, observability, storage, backup, and recovery automation.

## License

See [`LICENSE`](LICENSE).
