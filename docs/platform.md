# Platform components

[Back to the README](../README.md)

Networking, ingress, certificates and storage. Environment-specific addresses
come from `config/cluster.env`.

## Networking

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

## Cilium and Hubble

Cilium is the active CNI.

The current configuration uses:

- native routing mode
- cluster CIDR `10.42.0.0/16`
- Hubble enabled
- kube-proxy-compatible K3s networking configuration
- Flannel disabled

### Watching traffic with Hubble

Hubble records every connection Cilium handles, with the pods on each end and
whether policy allowed it. The relay and UI run in `kube-system`. The UI is
not published; reach it with
`kubectl -n kube-system port-forward svc/hubble-ui 12000:80` and open
<http://localhost:12000>. From the command line, the Cilium agent carries the
`hubble` client:

```bash
RELAY="$(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}')"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --server "$RELAY:80" --namespace website --verdict DROPPED -f
```

Each node keeps only its last few thousand flows, about a minute on this
cluster, so follow (`-f`) while the traffic happens.

### Network policies

`apps/network-policies/` holds standard Kubernetes NetworkPolicies, applied by
Argo CD (the `network-policies` application) and enforced by Cilium. A namespace listed there denies all
traffic by default and allows only what its file names. Namespaces without a
file are unrestricted.

| Namespace | Allowed in | Allowed out |
| --- | --- | --- |
| `website` | Traefik to nginx (8080) and fb-search (8000); Prometheus to fb-search metrics (9100) | Cluster DNS; git-sync to the internet on 22 (GitHub); fb-search to the internet on 443 |
| `cloudflared` | Prometheus to the metrics port (20241) | Cluster DNS; the internet on 7844 (Cloudflare's edge) and 443 (its API); Traefik's pods on 8000 and 8443 |
| `trilium` | Traefik to Trilium (8080); pods in the same namespace | Cluster DNS; the internet on 443; pods in the same namespace |
| `vaultwarden` | Traefik to Vaultwarden (8080); pods in the same namespace | Cluster DNS; the internet on 443 and 587 (mail through Gmail); pods in the same namespace |

"The internet" excludes the private ranges, so these pods cannot reach the
home network, the nodes, the Kubernetes API or other pods. The kubelet's
probes need no rule: Cilium always lets a node reach its own pods.

Three details that are easy to trip over:

- The tunnel's origin is Traefik's load-balancer address, `192.168.0.200:443`.
  Cilium translates that to a Traefik pod before it checks policy, so the
  cloudflared rule names the Traefik pods and their container ports (8000 and
  8443), not the address.
- Trilium and Vaultwarden allow traffic within their own namespace because
  `recovery/restore.sh --health-check` starts a pod there that calls the
  application's Service.
- cloudflared's ICMP probes to the internet at start-up are dropped. Only its
  optional ICMP proxying uses them, which this tunnel does not.

To write policies for another namespace without risking an outage:

1. Record what it does: `hubble observe --namespace <ns> -f` while using the
   application.
2. Put its endpoints in audit mode, so policy is evaluated but nothing is
   dropped. On the node running each pod:
   `cilium-dbg endpoint config <id> PolicyAuditMode=Enabled`, with the ID from
   `kubectl -n <ns> get ciliumendpoints`.
3. Apply the policies and watch `hubble observe --namespace <ns> --verdict AUDIT`.
   Anything listed would have been dropped.
4. When only unwanted traffic is listed, set `PolicyAuditMode=Disabled`.

Audit mode is per pod and is lost when the pod restarts, after which the
policy is enforced. Argo CD puts a deleted policy back within seconds, so to
open a namespace's networking in a hurry, follow "Stopping Argo CD in an
emergency" below and then run
`kubectl delete -f apps/network-policies/<namespace>.yaml`.

## kube-vip

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

## MetalLB

MetalLB provides Kubernetes `LoadBalancer` service addresses.

Current mode:

```text
Layer 2
```

The pool is supplied through:

```text
METALLB_IP_RANGE
```

## Traefik

Traefik is installed separately with Helm rather than using the K3s bundled Traefik.

It handles application ingress and TLS-enabled service exposure.

Routes that use a Traefik middleware are `IngressRoute` objects, not Kubernetes
`Ingress` objects: Longhorn, Grafana, Prometheus, Trilium, the
`www` redirect and the Traefik dashboard. Traefik reads Ingresses and its own
CRDs through two separate providers. At startup the Ingress routes used to load
a moment before the middlewares, and each one logged
`middleware "...@kubernetescrd" does not exist` (harmless, since the pod was not
Ready yet). IngressRoutes and Middlewares load together, so the errors are
gone. Routes without a middleware (Authelia, Rancher, Vaultwarden, the website)
are still Ingresses. `deploy.sh` removes the replaced Ingress after applying
each IngressRoute.

Chart upgrades and value changes are recorded in the [changelog](CHANGELOG.md).

## cert-manager

cert-manager issues and renews certificates using the configured Let's Encrypt `ClusterIssuer`.
Argo CD deploys both: the chart as the `cert-manager` application
(`apps/cert-manager/values.yaml`), and the issuer with its Cloudflare API
token as `cert-manager-config` (`charts/cert-manager-config`).

The issuer is called `letsencrypt-prod` on every cluster, because every
Certificate names it. Which Let's Encrypt service it uses is the chart's
`acmeServer` value. Production uses the real service. The test cluster uses
the staging service, whose certificates browsers do not trust and which has
no weekly limit, so rebuilding the test cluster does not use up the five
identical certificates a week that the real service allows.

Cloudflare API credentials are loaded from the encrypted/local secrets file and are not committed to the repository.

## Cloudflare Tunnel

A Cloudflare Tunnel provides external connectivity without exposing the Kubernetes nodes directly.

Argo CD deploys it from the `charts/cloudflared` chart. The tunnel token is
a Secret that Argo CD decrypts from the private configuration repository.

The pods run with a restricted security context: the image's non-root user
(65532), a read-only root filesystem, no Linux capabilities, no privilege
escalation, and the runtime's default seccomp profile.

## Authelia

Authelia is the login portal in front of the admin UIs. See [Authelia](authelia.md).

## Longhorn storage

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

## Argo CD

Argo CD (chart `10.10.2`, Argo CD `v3.5.4`) runs in the `argocd` namespace. It
watches git and makes the cluster match it. `deploy.sh` installs the engine
from `apps/argocd/values.yaml`; each thing it manages is an `Application`
resource. The applications have all been handed over. The platform charts
are moving one stage at a time; until its stage, `deploy.sh` still installs
a chart with Helm.

`deploy.sh` installs Argo CD first, straight after the cluster itself,
because Argo CD deploys cert-manager and nearly everything after it. On a
new cluster most applications cannot sync at that moment: the CRDs, storage
or Traefik they need arrive later in the script. Each one retries for about
two hours, and the script waits for each at the point where it must be
ready. Argo CD's ServiceMonitors are left out of that first install, since
the monitoring CRDs do not exist yet; a second pass adds them once
monitoring is installed.

| Stage | What moves to Argo CD | State |
| --- | --- | --- |
| 1 | The engine itself, UI behind Authelia | Done 2026-10-11 |
| 2 | Trivy Operator, Kyverno and its policies, network policies | Done 2026-10-11 |
| 3 | Website (with the private configuration repository) | Done 2026-10-11 |
| 3 | fb-search (manifests and source moved to the private configuration repository) | Done 2026-10-11 |
| 4 | cloudflared and Authelia, with their Secrets encrypted in the private repository | Done 2026-10-11 |
| 5 | Trilium and Vaultwarden (self-heal off; `restore.sh` pauses Argo CD) | Done 2026-10-11 |
| 6 | cert-manager and its issuer; Argo CD installed first by `deploy.sh` | Done 2026-10-12 |
| 7 | The admin UIs' routes (`routes`); alert rules, scrape targets, the Loki data source and dashboards (`monitoring-extras`) | Done 2026-10-12 |
| 8 | Loki and Alloy | Done 2026-10-12 |
| 9 | kube-prometheus-stack and its Secrets | Done 2026-10-12 |
| 10 | Velero, with the snapshot controller and Longhorn's backup settings | Done 2026-10-12 |
| 10 | Rancher | Not started |
| 11 | Traefik | Not started |
| 12 | Argo CD's own chart; `deploy.sh` reduced to a bootstrap | Not started |

K3s, Cilium, kube-vip, MetalLB and Longhorn stay with Ansible and `deploy.sh`.
Rancher installs Fleet, another GitOps engine; nothing in this repository
uses it, and the two must not manage the same resources.

### How a change reaches the cluster

`apps/argocd/root.yaml` is the one Application `deploy.sh` applies. It makes
Argo CD create every Application in `apps/argocd/applications/templates/`. Each of
those names a chart version and a values file, or a directory of manifests,
on the `main` branch of this repository on GitHub. The `website` application
also reads its domain from the
[private configuration repository](configuration.md#the-private-configuration-repository),
and `fb-search` is built entirely from it. `cloudflared` and `authelia` take
their settings and their Secrets from it.

- To upgrade a chart, change `targetRevision` in its Application file. To
  change a setting, edit its values file or manifest. Open a pull request;
  when it merges, Argo CD applies it within about three minutes.
- Argo CD reads GitHub, not a laptop's working copy. An unmerged edit does
  nothing, and `deploy.sh` no longer installs these components itself.
- A manual edit to something Argo CD manages is undone within seconds
  (self-heal). The two applications that are plain manifests
  (`kyverno-custom-policies`, `network-policies`) are restored exactly. The
  three Helm-chart applications use server-side apply, which the charts'
  large CRDs require; there, a value another tool adds to a list can survive
  beside Argo CD's own.
- Argo CD never deletes (`prune: false`). Removing a file from git leaves the
  resource in the cluster, shown as out of sync, until it is deleted by hand.

```bash
kubectl -n argocd get applications
kubectl -n argocd exec argocd-application-controller-0 -- argocd app diff <name> --core
```

The Helm release records for `trivy-operator`, `kyverno` and
`kyverno-policies` from before the handover still appear in `helm list`.
Nothing uses them; do not run `helm upgrade` on those releases.

### Environments

`apps/argocd/applications` is a small chart, so two clusters can deploy the
same applications from different places. Its defaults are production: the
`main` branch of this repository and the top level of the configuration
repository. `deploy.sh` passes other values when these are set in
`config/cluster.env`:

| Setting | Meaning |
| --- | --- |
| `ARGOCD_APPS_REVISION` | Branch of this repository the applications deploy. Default `main` |
| `ARGOCD_APPS_CONFIG_PATH` | Directory of the configuration repository with this cluster's settings and Secrets, with a trailing slash. Default empty (production); the test cluster uses `envs/test/` |
| `ARGOCD_APPS_DISABLED` | Comma-separated applications not to create. The test cluster leaves out `fb-search` |

The test cluster's Argo CD has its own age key, so it cannot decrypt
production's Secrets, and production's cannot decrypt the test ones. See
[Testing a full rebuild](backup-and-dr.md#testing-a-full-rebuild).

### Secrets

Argo CD can only deploy what is in git, so the Secrets of the applications it
manages are in the private configuration repository, encrypted with sops.
Only the values are encrypted. The KSOPS plugin, installed in Argo CD's repo
server by `apps/argocd/values.yaml`, decrypts them while an application is
rendered.

The files are encrypted to two age keys. One is the laptop key that protects
`.secrets.enc`. The other exists only for Argo CD: it is the `sops-age`
Secret in the `argocd` namespace, which `deploy.sh` creates from
`ARGOCD_SOPS_AGE_KEY`. Someone who takes that key from the cluster can read
the Secrets Argo CD deploys, which are in the cluster anyway, and nothing
else in `.secrets.enc`.

Argo CD's own two credentials (`sops-age` and the configuration repository's
deploy key) and the Secrets of applications it does not manage yet are still
created by `deploy.sh`. To change a Secret Argo CD deploys, see
[Changing a secret Argo CD deploys](configuration.md#changing-a-secret-argo-cd-deploys).

### Argo CD and restores

Trilium and Vaultwarden hold data, so their applications sync changes from
git but do not self-heal: a manual scale-down for maintenance stays as it
is until git changes.

`recovery/restore.sh --promote-app APP` scales a Deployment to zero and points
it at a restored volume. If Argo CD manages that Deployment (Trilium,
Vaultwarden and Authelia today), the script first pauses its application by
setting the `argocd.argoproj.io/skip-reconcile` annotation, so nothing puts
the old volume back. `--rollback-app` removes the annotation once the
Deployment matches git again.

After a promotion that is kept, the application stays paused, because the
Deployment uses the `APP-restore-test` volume and git names the original. Argo
CD ignores the application until the annotation is removed, and its status
there goes stale. To see or clear a pause:

```bash
kubectl -n argocd get applications.argoproj.io \
  -o custom-columns='NAME:.metadata.name,PAUSED:.metadata.annotations.argocd\.argoproj\.io/skip-reconcile'
kubectl -n argocd annotate applications.argoproj.io APP argocd.argoproj.io/skip-reconcile-
```

Clearing it while the Deployment still uses the restored volume makes Argo
CD switch it back to the original at the next sync.

### Stopping Argo CD in an emergency

To change or delete something Argo CD manages without it being put back,
stop the controller first, and start it again afterwards:

```bash
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
# ...make the change...
kubectl -n argocd scale statefulset argocd-application-controller --replicas=1
```

When the controller starts again it restores what git says, so make the same
change in git before then if it should last.

### The UI

The UI is at `https://argocd.${BASE_DOMAIN}`, behind Authelia (two-factor,
`admins` group) and then Argo CD's own login. Since 2026-10-11 the hostname
is a public hostname on the Cloudflare tunnel, set up like the other
Authelia-protected UIs (see [Authelia](authelia.md)), so it is reachable from
anywhere. The tunnel route is configured in the Cloudflare dashboard, not in
this repository.

If the tunnel or Authelia is down, skip both from a machine with `kubectl`:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80   # http://localhost:8080
```

The login is user `admin`. Its password was changed from the generated one on
2026-10-11 and is kept in the password manager, not in `.secrets.enc`. On a
rebuilt cluster the first login uses the generated password in the
`argocd-initial-admin-secret` Secret: read it in your own terminal, change it
in the UI (User Info, Update Password), then delete that Secret.
