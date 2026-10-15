# How to

[Back to the README](../README.md)

Everyday tasks on the running cluster. Argo CD deploys everything except
K3s, Cilium, kube-vip, MetalLB and Longhorn, so almost every change is the
same: edit git, merge, and Argo CD applies it within about three minutes.
[Platform components](platform.md#argo-cd) explains how that works.

Two repositories are involved:

- **This one** (public): charts, Application files, policies, dashboards.
  Changes go through a pull request.
- **`k3s-homelab-config`** (private, cloned beside this one): each cluster's
  domain-specific settings and its Secrets, encrypted. Changes are pushed to
  `main` directly, and are mostly written by the two render scripts, not by
  hand.

Argo CD reads GitHub, not your laptop. Nothing happens until the change is
on `main`.

- [Check that everything is healthy](#check-that-everything-is-healthy)
- [Add a new application](#add-a-new-application)
- [Change a setting](#change-a-setting)
- [Change a secret](#change-a-secret)
- [Upgrade a chart or an image](#upgrade-a-chart-or-an-image)
- [Undo a bad change](#undo-a-bad-change)
- [Stop Argo CD in an emergency](#stop-argo-cd-in-an-emergency)

## Check that everything is healthy

```bash
argocd app list            # every application Synced and Healthy
./dr-status.sh             # backups fresh, DR READY
kubectl get certificates -A
kubectl get pods -A | grep -vE 'Running|Completed'
```

`argocd` here is the shell function from dotfiles: it uses kubectl's access
(`--core`), so no Argo CD login is needed. `argocd app get NAME` shows one
application's resources, and `argocd app diff NAME` shows what differs from
git.

In Grafana, "Homelab - Argo CD (GitOps)" shows the same at a glance, and the
Backups, Network and Security dashboards cover the rest. The Argo CD UI is
at `https://argocd.<domain>`.

## Add a new application

The example adds `example`, a web app with a data volume, behind Authelia at
`example.<domain>`. Trilium is the closest existing model: copy from
`charts/trilium` and `apps/argocd/applications/templates/trilium.yaml`.

### 1. Write the chart

Create `charts/example/` with `Chart.yaml`, `values.yaml` and one template
holding:

- the `Namespace`;
- a `PersistentVolumeClaim` on `storageClassName: longhorn`, if it keeps
  data;
- the `Deployment`, with a pinned image tag (never `latest`), running as
  non-root with a read-only root filesystem, all capabilities dropped and a
  `RuntimeDefault` seccomp profile. Trilium's shows how; the policy below
  refuses anything else in the protected namespaces;
- a `Service`;
- a cert-manager `Certificate` for `example.{{ .Values.domain }}` from the
  `letsencrypt-prod` ClusterIssuer;
- a Traefik `IngressRoute` on `websecure` with the `admin-ui-auth`
  middleware (namespace `traefik`) and the certificate's secret. Use an
  IngressRoute, not an Ingress: Traefik loads it with its middleware, so it
  never starts before the middleware exists.

Settings that differ between clusters, such as the domain, come from
values; leave them empty in `values.yaml` and use `required` in the
template, so a missing one fails loudly. Add a `ci-values.yaml` with
placeholder values: `scripts/validate-manifests.sh` and CI render the chart
with it.

Images must come from the allowed registries (Docker Hub, `ghcr.io`,
`quay.io`, `registry.k8s.io` and a few more; the list is in
`apps/kyverno/policies/enforce-app-namespaces.yaml`).

### 2. Add its settings to the private repository

If the chart needs the domain, add the app to the loop in
`scripts/render-argocd-values.sh` that writes `domain:` for `routes`,
`trilium` and `website`. Then:

```bash
scripts/render-argocd-values.sh          # writes example/values.yaml
cd ../k3s-homelab-config && git add example && git commit -m "Add example" && git push
```

A Secret the app needs goes the same way through
`scripts/render-argocd-secrets.sh`, from a value in `.secrets.enc`; see
[Change a secret](#change-a-secret).

### 3. Write the Application

Copy `apps/argocd/applications/templates/trilium.yaml` to `example.yaml`,
and change the names, namespace, chart path and values file. Keep the
`{{- if not (has "example" .Values.disabled) }}` wrapper so a test cluster
can leave it out.

Choose the sync policy on purpose:

| The app... | `selfHeal` | `prune` |
| --- | --- | --- |
| holds data that `recovery/restore.sh` may swap | `false` | `false` |
| is only configuration (routes, policies, dashboards) | `true` | `true` |
| is someone else's chart with CRDs | `true` | `false` |

A chart from a new Helm repository also needs that repository in
`sourceRepos` in `apps/argocd/project.yaml`. That file is applied by
`deploy.sh`, not by Argo CD, so run `./deploy.sh` once after it merges.

### 4. Lock it down and protect it

- **Authelia:** add `example.<domain>` to `access_control` in
  `charts/authelia/templates/configmap.yaml`.
- **Network policy:** copy `apps/network-policies/trilium.yaml` to
  `example.yaml` and adjust it. It denies everything, then allows DNS,
  traffic within the namespace, traffic from Traefik, and HTTPS out to the
  internet; change the last two to what the app really needs.
- **Kyverno:** once the app runs and its policy report is clean, add its
  namespace to `apps/kyverno/policies/enforce-app-namespaces.yaml`, so a
  pod that breaks the rules is refused rather than reported.
- **Backups:** Longhorn's nightly backup covers every volume automatically.
  For Velero's nightly backup as well, add the namespace to
  `apps/velero/manifests/velero-schedules.yaml`. For the DR checks and
  `recovery/restore.sh`, add a line to `recovery/apps.conf` and, for an HTTP
  health check, a URL in `restore.sh`'s `http_health_check`.

### 5. Merge, then the two steps outside git

Open one pull request with all of the above. When it merges, Argo CD
creates the application and deploys it; `argocd app get example` shows
progress, and the certificate is usually ready within two minutes.

Then, by hand:

1. **Cloudflare:** add a public hostname `example.<domain>` to the tunnel,
   pointing at `https://<CLOUDFLARE_ORIGIN_IP>` with No TLS Verify. Without
   it the app works only on the LAN.
2. **Docs:** add the app to [Applications](applications.md) and the
   README's table.

### Removing an application

Delete its Application file and merge. Argo CD deletes the Application but,
for an app with `prune: false`, leaves its resources in the cluster. Delete
the namespace by hand when you are sure (a volume with `Delete` reclaim
policy goes with it), then remove its lines from the files in step 4.

## Change a setting

**A setting in this repository** (a chart value, replica count, resource
limit, alert rule, dashboard): edit the file, open a pull request, merge.

**A setting in `config/cluster.env`** (domain, addresses, admin email,
backup share):

```bash
$EDITOR config/cluster.env
scripts/render-argocd-values.sh            # rewrites changed values.yaml files
cd ../k3s-homelab-config && git commit -am "..." && git push
k3s-sync push                              # copy cluster.env to the other laptop
```

`scripts/render-argocd-values.sh --check` prints `same` or `DIFFERENT` for
each file without writing. The table of which setting goes where is in
[Configuration and secrets](configuration.md#the-private-configuration-repository).

## Change a secret

Run these in your own terminal; they read and write `.secrets.enc`.

```bash
sops .secrets.enc                          # edit the value
scripts/render-argocd-secrets.sh           # re-encrypts changed Secrets
cd ../k3s-homelab-config && git commit -am "..." && git push
k3s-sync push
```

Argo CD applies the Secret within three minutes; most apps then need a
restart, for example
`kubectl -n authelia rollout restart deployment/authelia`. Which restart each
Secret needs, and the few credentials `deploy.sh` still creates, are in
[Configuration and secrets](configuration.md#changing-a-secret-argo-cd-deploys).
`scripts/render-argocd-secrets.sh --check` compares with the cluster without
printing any value.

## Upgrade a chart or an image

**Third-party charts** (Traefik, cert-manager, Kyverno, monitoring, Velero,
Argo CD itself and the rest): Renovate opens a pull request on Monday
mornings when a chart has a newer version. Read the chart's release notes,
then merge; merging is the upgrade. To upgrade by hand, change
`targetRevision` in the Application file.

**Images in this repository's own charts** (Trilium, Vaultwarden, Authelia,
cloudflared, the website): nothing watches these. Change the tag in the
chart's template and merge. Back up first for an app that holds data:

```bash
recovery/restore.sh --plan vaultwarden     # shows the latest backup
```

**Not through Argo CD:** Longhorn's version is in `deploy.sh` and held at
1.12.1 until 1.13.1. K3s and Cilium are upgraded with Ansible; see
[Maintenance](maintenance.md).

## Undo a bad change

Revert the pull request on GitHub (the "Revert" button) and merge the
revert. Argo CD applies the old state within three minutes. For a change in
the private repository, `git revert` the commit and push.

Where `prune` is `false`, a resource the bad change added stays behind after
the revert, shown as out of sync; delete it by hand. If Argo CD itself is
broken by the change and cannot apply the revert, fix the values on `main`
and run `ARGOCD_FORCE_INSTALL=true ./deploy.sh`.

## Stop Argo CD in an emergency

To change something by hand without Argo CD putting it back within seconds:

```bash
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
# ...make the change...
kubectl -n argocd scale statefulset argocd-application-controller --replicas=1
```

When the controller starts again it restores what git says, so make the
same change in git first if it should last. To pause one application
instead, see [Argo CD and restores](platform.md#argo-cd-and-restores).
