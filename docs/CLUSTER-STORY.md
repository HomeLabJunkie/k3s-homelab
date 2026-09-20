# How Our Home Cluster Works

*A plain-English guide: from six separate computers to a home cloud that runs apps, protects its data, watches its own health, and can rebuild itself after a disaster.*

**Who this is for:** anyone. You don't need an IT background. Each step explains what was built, why it matters, and the name of the software involved, with an everyday comparison where it helps.

---

## The big picture

This project turns **six ordinary computers** into **one system** that behaves like a small private cloud. Instead of each computer running its own separate programs, the six work together: the system decides which computer runs what, moves work around if one fails, and keeps everything backed up.

That kind of system is called a **cluster**. This one is called **k3s-homelab**.

- **3 computers act as the "brains"** (the *control plane*). They make the decisions and keep the official record of what should be running.
- **3 computers are "workers."** They run the actual applications.
- Any one computer can fail and everything keeps running.

```text
   THE CLUSTER
   ┌───────────────────────────────────────────────────────┐
   │  Brains:    [ computer 1 ] [ computer 2 ] [ computer 3 ]   ← decide what runs where
   │  Workers:   [ computer 4 ] [ computer 5 ] [ computer 6 ]   ← run the apps
   └───────────────────────────────────────────────────────┘
```

Each computer has 8 processor cores, between 14 and 30 GB of memory, and about 240 GB of disk space.

---

## The 10 steps at a glance

| Step | What we set up | Why | Main software |
| --- | --- | --- | --- |
| **1** | The six computers and their operating system | A consistent, repeatable starting point | Ubuntu Linux, Ansible |
| **2** | The cluster itself | Turns six computers into one system | K3s (Kubernetes) |
| **3** | The network | Lets apps and computers talk to each other | Cilium, Hubble, MetalLB |
| **4** | Secure access from outside | One safe front door with HTTPS | Traefik, cert-manager, Cloudflare Tunnel |
| **5** | Storage | Data survives a failed computer | Longhorn |
| **6** | Management tools | See and control everything from a web page | Rancher, Portainer |
| **7** | The applications | The reason the cluster exists | Vaultwarden, Trilium, a website, fb-search |
| **8** | Monitoring and alerts | Notice problems early, and keep history | Prometheus, Grafana, Alertmanager, Loki |
| **9** | Backups and disaster recovery | Recover from the worst case | Longhorn backups, Velero, Garage, a spare computer |
| **10** | Maintenance | Update safely without downtime | Rolling update scripts |

---

## Step 1 — The computers and Linux

**What it is:** Six computers, each running the same operating system: **Ubuntu Linux 26.04 LTS**. Linux is a free operating system that runs most of the world's servers. "LTS" means long-term support, so it keeps receiving security updates for years.

**How they were set up:** With **Ansible**, a tool that configures many computers from one written set of instructions. Think of it as a recipe: you write the steps once (set the time zone, allow network traffic to pass through, load the networking components, reserve a disk area for storage) and Ansible applies them identically to all six.

**Why it matters:** identical machines are predictable. If one is replaced, it can be rebuilt from the same instructions instead of from memory.

## Step 2 — Making them one cluster (K3s)

**What it is:** **K3s** is a lightweight edition of **Kubernetes**, the software large companies use to run applications across many computers. You tell it what you want running, and it decides which computer runs it and restarts it if it stops.

**Brains and workers:** Three computers are *control plane* nodes. They share a small database called **etcd** that records the desired state of everything. The three brains make decisions by majority vote, so if one goes down, the other two still agree and the cluster keeps working. (With a single brain, one failure would stop everything.) The other three computers are *workers*.

**One address for the brains:** **kube-vip** provides a single shared address that always points at a healthy brain, so tools never need to know which brain is which.

## Step 3 — The network

Applications need to reach each other, and the outside world needs to reach the applications.

| Software | What it does |
| --- | --- |
| **Cilium** | The cluster's internal network. It connects every app to every other app and enforces who is allowed to talk to whom. We chose it over K3s's default because it is faster and has better visibility. |
| **Hubble** | A window into Cilium: shows which apps are talking to which, useful for troubleshooting. |
| **MetalLB** | Hands out real addresses on the home network to services that need to be reachable from outside the cluster. |

## Step 4 — Secure access from outside

Three pieces work together so people can reach your apps without exposing the computers themselves:

- **Traefik** is the "front door." All web traffic arrives at one place, and Traefik routes it to the right app based on the address (for example, the notes app versus the password manager). Two copies run, so it stays up if one fails.
- **cert-manager** with **Let's Encrypt** automatically obtains and renews the certificates that give websites the padlock (HTTPS). No one has to remember to renew them.
- **Cloudflare Tunnel** lets visitors from the internet reach the apps without opening a port on your home router. The cluster makes an *outbound* connection to Cloudflare, and visitors come in through that connection. Two tunnel connectors run for redundancy.

```text
Internet visitor ─► Cloudflare ─► private tunnel ─► Traefik ─► the right app
Home-network visitor ──────────────────────────────► Traefik ─► the right app
```

## Step 5 — Storage that survives failures (Longhorn)

By default, an app's data lives on whichever computer it happens to run on, which is a problem if that computer dies. **Longhorn** solves this by storing each app's data on **three different computers** at once.

- Every volume currently has **3 copies**, and all 7 are healthy.
- A **snapshot** (a point-in-time copy) is taken every **6 hours**, keeping the latest 12.
- A **backup** goes to a separate storage box on the network every night, keeping 14 nights (see Step 9).
- Apps that store data, such as the password manager, the notes app and the monitoring tools, use Longhorn automatically.

## Step 6 — Management tools

Two web-based control panels make the cluster easy to see and manage:

- **Rancher** is the main dashboard: all six computers, everything running on them, and their health in one place. Two copies run for redundancy.
- **Portainer** is a second, simpler dashboard, kept as an alternative view.
- **Longhorn** also has its own dashboard for the storage system.

## Step 7 — The applications

| Application | What it is |
| --- | --- |
| **Vaultwarden** | A private password manager, compatible with Bitwarden apps |
| **Trilium** | A note-taking and personal knowledge app |
| **The website** | A small web server (nginx), with two copies so it stays online |
| **fb-search** | A password-protected page where you enter an item and a city and get Facebook Marketplace listings from the last N days |
| **Grafana** | Dashboards for the cluster's health (Step 8) |

Each app has its own web address, served through Traefik from Step 4.

## Step 8 — Monitoring and alerts

The goal is to find out about a problem *before* it becomes an outage, and to have history to look back on.

| Software | What it does |
| --- | --- |
| **Prometheus** | Collects measurements (processor use, memory, disk space, network traffic) every few seconds and stores them over time. |
| **Grafana** | Turns those measurements into charts and dashboards. |
| **Alertmanager** | Sends an **email** when something is wrong. There are **143 alert rules** watching the cluster. |
| **Loki** | Stores the text logs that every app writes, so you can search what happened and when. |
| **Alloy** | Collects logs from every computer and sends them to Loki. |

The chart history and logs are stored on Longhorn, so they survive a crash too.

## Step 9 — Backups and disaster recovery

Replication (Step 5) protects against a failed computer. Backups protect against bigger problems: a mistake, corruption, or losing the whole cluster.

**Three layers of protection:**

1. **Longhorn nightly backups** to a separate storage box (a NAS) on the home network. This covers the 7 apps whose data matters: Vaultwarden, Trilium, Portainer, Grafana, Loki, Prometheus and Alertmanager, about **175 GiB** in total.
2. **A cluster recovery bundle:** a copy of the cluster's records (an etcd snapshot), its settings, and the project's Git repository. Created with `./backup/backup.sh`.
3. **Velero to Garage:** a second, independent backup that runs nightly and is stored in a different place (an S3-style storage service called Garage on a separate machine). Two different tools in two different locations mean a single mistake can't remove both.

**Proving that recovery works:** a separate spare computer, **k3s-dr**, exists to rehearse a disaster. Copies of all the protected apps were rebuilt on it from the backups, started, and checked to confirm the real data was readable, not just that files existed. The full automated rehearsal passed (20 checks passed, 0 failed).

Timers keep this honest: nightly backups, checks that backups are recent, weekly **restore tests**, and a test email to confirm alerts still reach you. Secrets such as passwords and keys are stored encrypted (**SOPS + age**), never in plain text.

**The lesson from the rehearsal:** having a backup is not the same as being able to recover. Recovery counts only when the app starts and the data is there.

## Step 10 — Safe maintenance

Updating a cluster safely means never taking down more than one computer at a time.

- **Rolling updates:** computers are updated **one at a time, workers first and brains last**. Each is *drained* (its apps are moved elsewhere), updated, rebooted, and health-checked (network, storage, brains) before the next begins. If anything fails, the process **stops** and leaves that computer alone for investigation.
- **Look before you change:** risky commands have a check-only mode (`--preflight-only`, or check mode) that reports what *would* happen without doing it.
- **Health checks:** `./repo-doctor.sh` checks the overall state, and `./dr-status.sh` reports **DR READY** when backups are fresh and the recovery plan is in place.
- **Change control:** the configuration lives in GitHub, where automated tests and security checks run on every change, and Dependabot proposes version upgrades so nothing quietly goes out of date.

---

## What the cluster provides today

- **High availability:** 3 brains and 3 workers. Any one computer can fail without an outage.
- **Private services:** a password manager, a notes app, a website, and a Marketplace search tool.
- **Secure access:** automatic HTTPS and a private tunnel, with no open ports on the home router.
- **Durable data:** every app's data is stored three times, with snapshots every 6 hours.
- **Visibility:** dashboards, searchable logs, and 143 alert rules that email you.
- **A tested recovery plan:** three layers of backup, and a rehearsal that has been run and passed.
- **Careful upkeep:** updates one computer at a time, with checks before and after each.

---

## Software list

| Layer | Software | Version |
| --- | --- | --- |
| Operating system | Ubuntu Linux | 26.04.1 LTS |
| Cluster | K3s (Kubernetes) | v1.36.4 |
| Network | Cilium (+ Hubble) | 1.20.1 |
| Service addresses | MetalLB | Layer 2 mode |
| Web front door | Traefik | chart 41.6.0 |
| Certificates | cert-manager | v1.21.1 |
| Outside access | Cloudflare Tunnel (cloudflared) | 2 copies |
| Storage | Longhorn | 1.12.1 |
| Management | Rancher / Portainer | 2.15.1 / chart 245.0.0 |
| Monitoring | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) | chart 87.21.0 |
| Logging | Loki + Alloy | chart 18.9.0 / 1.11.1 |
| Second backup | Velero → Garage | chart 12.1.0 |

---

## Glossary

| Term | Meaning |
| --- | --- |
| **Cluster** | A group of computers working together as one system |
| **Node** | One computer in the cluster |
| **Control plane** | The "brains": the nodes that decide what runs where |
| **Worker** | A node that runs the applications |
| **Pod** | One running copy of an application |
| **Volume (PVC)** | A piece of storage that belongs to an application |
| **Ingress** | The front door that routes web traffic to the right app |
| **Helm** | An "app store" for the cluster; one command installs a whole application |
| **Snapshot** | A point-in-time copy of data, stored alongside the original |
| **Backup** | A copy stored somewhere else, so it survives a disaster |
| **DR (disaster recovery)** | The plan and tooling for rebuilding after a serious failure |
| **Drain** | Moving all apps off a computer before working on it |

---

## Is it healthy? Three quick checks

```bash
kubectl get nodes          # all 6 should show Ready
./repo-doctor.sh --quick   # overall health check; look for a healthy result
./dr-status.sh             # should end with: RESULT: DR READY
```
