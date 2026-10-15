# Argo CD

[Back to the README](../README.md)

How Argo CD runs this cluster. For the everyday tasks (adding an app,
changing a setting or secret, upgrading, undoing) see [How to](how-to.md).

Argo CD (chart `10.10.3`, Argo CD `v3.5.5`) runs in the `argocd` namespace.
It watches git and makes the cluster match it. Each thing it manages is an
`Application`. It deploys everything except K3s, Cilium, kube-vip, MetalLB
and Longhorn, which stay with Ansible and `deploy.sh`, and that includes its
own chart: the `argocd` application keeps the installation matching
`apps/argocd/values.yaml`.

Rancher installs Fleet, another GitOps engine. Nothing in this repository
uses it, and the two must not manage the same resources.

## Checking it

```bash
argocd app list               # every application Synced and Healthy
argocd app get NAME           # one application, with its resources
argocd app diff NAME          # what git would change
```

`argocd` is the shell function from the dotfiles: it uses kubectl's access
(`--core`), so no Argo CD login is needed. Without it:
`kubectl -n argocd get applications`.

`helm list` shows only what Helm still installs: `longhorn` (upgraded by
`deploy.sh`), `argocd` (installed by `deploy.sh` on a new cluster), `cilium`
(from Ansible), and the releases Rancher installs for itself.

## How a change reaches the cluster

`apps/argocd/root.yaml` is the one Application `deploy.sh` applies. It makes
Argo CD create every Application in `apps/argocd/applications/templates/`
(25 of them, 26 with `root`). Each names a chart version and a values file,
or a directory of manifests, on the `main` branch of this repository on
GitHub. `cloudflared`, `authelia` and `website` also take settings and
Secrets from the
[private configuration repository](configuration.md#the-private-configuration-repository),
and `fb-search` is built entirely from it.

- Argo CD reads GitHub, not a laptop's working copy. An unmerged edit does
  nothing. A merged one is applied within about three minutes.
- To upgrade a chart, change `targetRevision` in its Application file. That
  includes Argo CD itself (`argocd.yaml`, which `deploy.sh` also reads); its
  pods restart during that sync and it finishes the job when they are back.
- A manual edit to something Argo CD manages is undone within seconds
  (self-heal). The ten applications that use server-side apply (the
  third-party charts with large CRDs, such as cert-manager, Kyverno,
  monitoring, Traefik and Velero) can keep a value another tool added to a
  list beside Argo CD's own.

## Sync policy

**Self-heal** is on everywhere except `trilium` and `vaultwarden`. They hold
data, so they apply changes from git but leave a manual scale-down for
maintenance in place until git changes.

**Deleting what is removed from git** depends on the application:

| Deletes (`prune: true`) | Never deletes (`prune: false`) |
|---|---|
| `routes`, `network-policies`, `monitoring-extras`, `kyverno-policies`, `kyverno-custom-policies`, `backup-config`, `cert-manager-config`, `cloudflared`, `website` | everything else |

The first group holds only configuration: routes, policies, dashboards,
alert rules, backup jobs. There a leftover is the risk, such as a removed
route that keeps a service reachable or a removed alert that keeps firing.
Deleting waits until the rest of the change is applied and healthy.

The second group keeps `prune: false` for one of three reasons:

- it holds data (`authelia`, `trilium`, `vaultwarden`, `fb-search`): a volume
  claim or the namespace itself could be deleted;
- it is someone else's chart that carries CRDs (`cert-manager`, `kyverno`,
  `monitoring`, `traefik`, `velero` and the rest): an upgrade that drops a
  CRD would delete every object of that kind;
- deleting would be drastic: `root` owns the other applications, `argocd` is
  itself, `longhorn-config` is the backup target.

There, removing a file from git leaves the resource in the cluster, shown as
out of sync, until it is deleted by hand. [How to](how-to.md#add-a-new-application)
shows which policy to pick for a new app.

## What deploy.sh still does

`deploy.sh` builds what has to exist before Argo CD can work:

1. The cluster, with Ansible (K3s, Cilium, kube-vip, MetalLB).
2. Argo CD, with Helm, only if the cluster has none. The chart version comes
   from `apps/argocd/applications/templates/argocd.yaml`, so there is one
   place to change it. The ServiceMonitors are left out of that install,
   since the monitoring CRDs do not exist yet; Argo CD adds them later.
3. The two Secrets Argo CD cannot deploy for itself: the key it decrypts with
   (`sops-age`) and its login to the private configuration repository.
4. The `homelab` project and the `root` Application.
5. Longhorn, with Helm. Where it sends backups is set by Argo CD (the
   `longhorn-config` application).

On a new cluster most applications cannot sync at first: the CRDs, storage
or Traefik they need are not there yet. Each one retries for about two
hours. `deploy.sh` waits for all of them, then for every certificate, then
sets Rancher's admin password and server URL and creates the first
Vaultwarden invitation.

On a cluster that already runs Argo CD, `deploy.sh` leaves it alone.

**If Argo CD is too broken to repair itself** (for example after a bad change
to its own values), fix the values on `main` and run
`ARGOCD_FORCE_INSTALL=true ./deploy.sh`. That installs the chart with Helm
again; Helm takes over what Argo CD created, and Argo CD still reports
itself Synced afterwards because both apply the same chart and values.

## Secrets

Argo CD can only deploy what is in git, so the Secrets of the applications it
manages are in the private configuration repository, encrypted with sops
(only the values). The KSOPS plugin in Argo CD's repo server decrypts them
while an application is rendered.

The files are encrypted to two age keys: the laptop key that protects
`.secrets.enc`, and one that exists only for Argo CD, the `sops-age` Secret
in the `argocd` namespace (`ARGOCD_SOPS_AGE_KEY` in `.secrets.enc`). Someone
who takes that key from the cluster can read the Secrets Argo CD deploys,
which are in the cluster anyway, and nothing else.

`deploy.sh` still creates Argo CD's own two credentials. To change a Secret
Argo CD deploys, see
[Changing a secret Argo CD deploys](configuration.md#changing-a-secret-argo-cd-deploys).

## Chart updates

[Renovate](https://docs.renovatebot.com/) (`renovate.json`) opens a pull
request when a chart named in an Application file, or the snapshot
controller's image, has a newer version. It checks on Monday mornings, opens
at most five pull requests at a time, keeps Kyverno and its policies chart
together, labels major versions `major`, and never merges by itself.
Merging one is the upgrade, so read the chart's release notes first.
Dependabot covers pip, GitHub Actions and Docker. Longhorn is not covered;
its version is in `deploy.sh` and held on purpose.

Renovate works only while its GitHub app (github.com/apps/renovate) has
access to the repository and "Silent mode" is off for it in Mend's portal
(developer.mend.io, the repository's Settings, Dependencies, with "Automated
PRs" on). Its "Dependency Dashboard" issue lists what it found and what is
waiting.

## Environments

`apps/argocd/applications` is a small chart, so two clusters can deploy the
same applications from different places. Its defaults are production.
`deploy.sh` passes other values when these are set in `config/cluster.env`:

| Setting | Meaning |
| --- | --- |
| `ARGOCD_APPS_REVISION` | Branch of this repository the applications deploy. Default `main` |
| `ARGOCD_APPS_CONFIG_PATH` | Directory of the configuration repository with this cluster's settings and Secrets, with a trailing slash. Default empty (production); the test cluster uses `envs/test/` |
| `ARGOCD_APPS_DISABLED` | Comma-separated applications not to create. The test cluster leaves out `fb-search` |

The test cluster's Argo CD has its own age key, so neither cluster can
decrypt the other's Secrets. See
[Rehearse a rebuild on the test cluster](disaster-recovery.md#rehearse-a-rebuild-on-the-test-cluster).

## Pausing one application

The `argocd.argoproj.io/skip-reconcile` annotation stops Argo CD acting on
one application. `recovery/restore.sh --promote-app` and `--rollback-app`
use it only while they swap an app's volume: they scale the workload to
zero, make the restored volume take over the live claim's name (keeping its
Argo CD tracking), scale back up and resume the application. A failure in
between leaves it paused. To see or clear a pause:

```bash
kubectl -n argocd get applications.argoproj.io \
  -o custom-columns='NAME:.metadata.name,PAUSED:.metadata.annotations.argocd\.argoproj\.io/skip-reconcile'
kubectl -n argocd annotate applications.argoproj.io APP argocd.argoproj.io/skip-reconcile-
```

A Deployment promoted before 2026-10-15 was instead pointed at
`APP-restore-test` and left paused; `--rollback-app` still undoes one of
those. To stop all of Argo CD, see
[Stop Argo CD in an emergency](how-to.md#stop-argo-cd-in-an-emergency).

## The UI

`https://argocd.${BASE_DOMAIN}`, behind Authelia (two-factor, `admins`
group) and then Argo CD's own login. It is a public hostname on the
Cloudflare tunnel like the other Authelia-protected UIs (see
[Authelia](authelia.md)); the tunnel route is set in the Cloudflare
dashboard, not in this repository.

If the tunnel or Authelia is down:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80   # http://localhost:8080
```

The login is user `admin`, with the password in the password manager, not in
`.secrets.enc`. On a rebuilt cluster the first login uses the generated
password in the `argocd-initial-admin-secret` Secret: read it in your own
terminal, change it in the UI (User Info, Update Password), then delete that
Secret.
