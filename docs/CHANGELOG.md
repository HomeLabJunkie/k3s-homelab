# Changelog

[Back to the README](../README.md)

Dated notes on upgrades, configuration changes and validated recovery results,
newest first. The other documents describe how things work today; this file
records what changed and when. Merged pull requests hold the full detail.

## 2026-10-13: Cilium agent metrics on; Grafana dashboards for Velero and Cilium

The Cilium agents now serve Prometheus metrics (`cilium_agent_metrics`,
default on), and a `cilium-agent` PodMonitor scrapes them. The Ansible role
used to change Cilium only when its version changed; it now also compares the
agents' metrics address with the setting. That covers a new cluster. On
production `deploy.sh` does not touch Cilium, so the setting was applied with
`helm upgrade --reuse-values` (release revision 14): the agents rolled two
nodes at a time with no container restarts elsewhere, every agent reported
6/6 nodes reachable afterwards, and seven public hostnames returned the same
status codes before and after. "Homelab - Backups (Velero)" and "Homelab -
Network (Cilium)" join the dashboards.

## 2026-10-13: A Grafana dashboard for Argo CD

"Homelab - Argo CD (GitOps)" joins the dashboards in
`charts/monitoring-extras`: applications out of sync or not healthy, a table
of all applications, sync and health over time, syncs per hour and Argo CD's
own timings and memory. It uses the metrics Argo CD's ServiceMonitors
already supplied.

## 2026-10-13: The lint copy of the repository no longer holds private files

`ansible-lint` installs this repository as a collection under
`.ansible/collections` whenever it runs on a laptop. With an empty
`build_ignore` in `galaxy.yml` that copy included `.secrets.enc`,
`config/cluster.env`, the inventory, logs, and the `.venv` and `.ansible`
folders themselves. `build_ignore` now lists them; the built archive went
from over 100 MB to under 1 MB and holds none of them. The stale copies
found on both laptops were deleted.

## 2026-10-13: Laptop age key replaced

`scripts/rotate-sops-age-key.sh` ran against the real laptop key for the
first time: `.sops.yaml` here and in the configuration repository name the
new public key, all 27 Secrets there and both secrets files here were
re-encrypted, and each opens with the new key alone and not with the old
one. A recovery bundle was published and the secrets recovery test passed.
Before the run the script would have left `.secrets.test.enc`, the test
cluster's secrets file, encrypted to the old key; it now re-encrypts every
`.secrets*.enc` file beside `.secrets.enc`.

## 2026-10-13: Backup address change proven; the target checks itself again

On the test cluster the Longhorn backup address was changed through
`config/cluster.env`, the settings script and the configuration repository:
Argo CD applied it, a backup landed on the new share, and changing it back
restored the earlier backups to Longhorn's list. A wrong address showed a
fault: the test cluster's target had a poll interval of `0s`, because Argo
CD had created it before Longhorn did, so it never checked itself and went
on reporting "available" while backups failed. `charts/longhorn-config` now
sets `pollInterval` to `5m0s`; with it, the wrong address was reported
unavailable within five minutes. Production already had `5m0s`.

## 2026-10-13: StatefulSet promotion proven; it now pauses Argo CD

`recovery/restore.sh --promote-app alertmanager` and `--rollback-app
alertmanager` ran on production: 51 and 41 seconds, health checks passed,
Alertmanager held the Watchdog alert again on the restored volume and on the
original. Before the run, the StatefulSet path did not pause Argo CD, whose
self-heal would have put the replica count back in the middle of the volume
swap; it now pauses the owning application for the swap and resumes it
afterwards. The same day `ARGOCD_FORCE_INSTALL=true ./deploy.sh` ran on
production (exit 0, Helm revision 5, no Argo CD pod restarted, 26
applications Synced and Healthy).

## 2026-10-13: Scripts use the repository's Ansible by themselves

`deploy.sh` stopped at its toolchain guard on production because the
laptop's own Ansible was older than the pinned one in `.venv`. Each script
that runs Ansible now puts `.venv/bin` first on `PATH` itself when the
directory exists, so nothing has to be exported first.

## 2026-10-13: Full deploy.sh run on production

The first run on production since `deploy.sh` became a bootstrap: exit 0 in
161 seconds. Ansible changed nothing on any of the six nodes and restarted
no K3s service; the Longhorn Helm step re-applied chart `1.12.1` with no pod
restarted and all volumes healthy; Argo CD's install was skipped; the Rancher
password step and the Vaultwarden invitation found their work already done;
the settings and Secrets comparisons reported every item the same. All 26
applications stayed Synced and Healthy.

## 2026-10-13: First real promotion and rollback of a restored volume

`recovery/restore.sh --promote-app trilium` and `--rollback-app trilium` ran
on production for the first time. The latest Longhorn backup was restored
into `trilium-restore-test`; the promotion paused the Argo CD application,
switched the Deployment to the restored volume in 36 seconds and passed its
health check; Trilium was then used through its public address on the
restored data. The rollback returned it to the original volume in 29 seconds
and resumed the Argo CD application, which reported Synced and Healthy. The
health check no longer prints the page it fetches.

## 2026-10-13: Nine applications delete what is removed from git

Pruning is on for the applications that hold only configuration: `routes`,
`network-policies`, `monitoring-extras`, `kyverno-policies`,
`kyverno-custom-policies`, `backup-config`, `cert-manager-config`,
`cloudflared` and `website`. The other seventeen keep `prune: false`; see
[Working with Argo CD](platform.md#argo-cd) for the reasons.

## 2026-10-13: The key rotation test runs in CI

`tests/test-rotate-sops-age-key.sh` skipped on GitHub because sops and age
were not installed there. The `repo-safety` workflow now installs both (sops
pinned by version and checksum), and the test fails instead of skipping when
a tool is missing in CI. Production's Argo CD key was rotated the same day
with `scripts/rotate-sops-age-key.sh --argocd`: 26 applications Synced and
Healthy on the new key alone.

## 2026-10-13: Four chart updates through Renovate

Alloy `1.13.1`, Loki `18.15.1`, kube-prometheus-stack `92.3.1` and Velero
`12.2.1`, each a Renovate pull request merged on its own with production
checked in between. The first three were applied to the test cluster
together beforehand, from a branch. Afterwards on production: 26
applications Synced and Healthy, 90 of 90 Prometheus targets up, 152 alert
rules, logs arriving in Loki, and the disposable Velero backup and restore
test passed on the new chart.

## 2026-10-13: The forced Argo CD install works

`ARGOCD_FORCE_INSTALL=true ./deploy.sh` had never been run, and failed on
its first try on the test cluster: Helm refused the ServiceMonitors that
Argo CD had created itself. The Helm step now takes ownership of what is
there (`--take-ownership --force-conflicts`). On the test cluster it then
passed twice, once over a healthy Argo CD and once after its server and
repository server were deleted; all 24 applications stayed Synced and
Healthy.

## 2026-10-13: Key rotation covers the configuration repository

`scripts/rotate-sops-age-key.sh` re-encrypted only `.secrets.enc`, so after a
laptop key rotation the Secrets Argo CD deploys would still have been
encrypted to the old key. It now re-encrypts and pushes the private
configuration repository as well, and refuses to start if the two
`.sops.yaml` files disagree. A new form, `--argocd`, replaces Argo CD's own
key: see [Replacing an age key](configuration.md#replacing-an-age-key).
`tests/test-rotate-sops-age-key.sh` covers the laptop form with throwaway
keys.

## 2026-10-13: Argo CD knows its own address

Logging out of Argo CD landed on `argocd.example.com`, the chart's
placeholder: nothing had ever set `global.domain`. It now comes from
`argocd/values.yaml` in the private configuration repository, generated from
`config/cluster.env` like the other settings files, and `deploy.sh` passes
the same address when it installs Argo CD on a new cluster.

## 2026-10-12: One place for settings; Longhorn's backup target in Argo CD

`scripts/render-argocd-values.sh` now generates every `values.yaml` in the
private configuration repository from `config/cluster.env`, so a setting is
changed in one place instead of two. Generated for production and for the
test cluster, the files held the same settings as the hand-written ones.
The test cluster's `cluster.env` is kept in that repository as
`envs/test/cluster.env`. See
[the private configuration repository](configuration.md#the-private-configuration-repository).

Where Longhorn sends volume backups became the `longhorn-config` application
(`charts/longhorn-config`): the `default` BackupTarget, and the login for the
CIFS share as an encrypted Secret. On production the comparison showed only
ownership annotations and the target stayed available. `deploy.sh` (1,185 to
1,138 lines) no longer creates that Secret or sets the target; it waits for
the target to be available. It also no longer tests a changed address with a
temporary second target before switching: check a new share is reachable
before changing `BACKUP_NAS_IP` or `LONGHORN_BACKUP_SHARE`.

The disposable Velero test (`scripts/test-velero-backup.sh`) passed the same
day, the first backup and restore since Argo CD took over Velero.

## 2026-10-12: Argo CD upgraded itself to 3.5.5

Renovate was given access to the repository and opened its Dependency
Dashboard (issue #143) and its first pull request, chart `argo-cd` `10.10.2`
to `10.10.3` (Argo CD `v3.5.4` to `v3.5.5`, bug fixes only; the two chart
versions render the same apart from the image tag). Merging it was the first
upgrade of Argo CD through its own `argocd` application: every Argo CD pod
was replaced and the application was Synced and Healthy again 63 seconds
after the merge. All 25 applications stayed healthy, the three applications
with encrypted Secrets rendered again after the repo server restarted, and
the `admin` login was not touched.

## 2026-10-12: Argo CD deploys the website's deploy key

The `jeffriffle-git` Secret, which git-sync clones the site with, moved to
the private configuration repository like the other Secrets
(`scripts/render-argocd-secrets.sh` writes it; `--check` compares it).
`deploy.sh` no longer creates it, and no longer restarts the website when
the key changes: after changing `WEBSITE_DEPLOY_KEY_B64`, run the script,
push the configuration repository, then
`kubectl -n website rollout restart deployment/jeffriffle`. On production
the Secret Argo CD renders was compared with the live one first and matched.

## 2026-10-12: Renovate proposes chart upgrades

`renovate.json` was added so that Renovate opens a pull request when a
chart in an Argo CD Application file has a newer version (eleven charts and
the snapshot controller). Nothing merges by itself. See
[Chart updates](platform.md#chart-updates).

The Helm release records of the ten releases Argo CD now owns were deleted
from production the same day (82 records), so `helm list` shows only what
Helm still installs. The test cluster's Argo CD age key is kept, encrypted,
in the configuration repository as `envs/test/argocd-sops-age-key.enc.yaml`.

## 2026-10-12: Charts are rendered in CI

The `repo-safety` workflow now renders every chart in `charts/` and the
Argo CD applications chart with `helm template`, so a chart that does not
render cannot merge and then fail in Argo CD. Two scripts nothing referred to
were removed: `scripts/git-audit.sh` (superseded by `scripts/scan-secrets.sh`
and Gitleaks) and `scripts/hashicorp-troubleshoot.sh` (the cluster has no
Vault).

## 2026-10-12: Argo CD manages itself; deploy.sh is a bootstrap

On 2026-10-12, Argo CD's own chart became the `argocd` application (chart
`10.10.2`, the same `apps/argocd/values.yaml`). On production the comparison
showed nothing but ownership annotations; no Argo CD pod restarted and the
`admin` password was not touched. Upgrading Argo CD is now a change to
`targetRevision` in `apps/argocd/applications/templates/argocd.yaml`.

`deploy.sh` went from 1,514 lines to about 1,220:

- It installs Argo CD with Helm only on a cluster that has none, at the
  version in that Application file. `ARGOCD_FORCE_INSTALL=true` installs it
  again, for an Argo CD too broken to repair itself from git.
- It waits for all applications together, then for all certificates,
  instead of one wait and several checks per chart.
- It checks that every volume in the cluster is on Longhorn, not only the
  monitoring and logging ones.
- Gone: the per-chart rollout, endpoint and object checks that an
  application's health already covers, the second Argo CD install pass, the
  clean-up of objects replaced in earlier releases (old Ingresses, the
  basic-auth Secret, the old MetalLB monitor), and the long status listing
  at the end.

It still builds the cluster with Ansible, installs Longhorn, creates the
three Secrets Argo CD cannot deploy for itself, sets Rancher's admin
password through its API and creates the first Vaultwarden invitation.

## 2026-10-12: Argo CD deploys Traefik

On 2026-10-12, Traefik moved to Argo CD as the `traefik` application (chart
`41.7.1`, values moved to `apps/traefik/values.yaml`). On production the
comparison showed no difference in the Deployment, the Service or the
`traefik.io` CRDs that routes use. It did show the unused Traefik Hub CRDs
(`hub.traefik.io`) behind the chart, because Helm never upgrades CRDs after
the first install; Argo CD brought them up to the chart's version. No
Traefik pod restarted, the load-balancer address stayed `192.168.0.200`, and
176 of 176 requests to the site during the sync returned 200.

With this, every chart except Longhorn and Argo CD itself is deployed by
Argo CD. `deploy.sh` waits for the application instead of validating and
installing the chart.

## 2026-10-12: Argo CD deploys Rancher

On 2026-10-12, Rancher moved to Argo CD as the `rancher` application (chart
`2.15.2`, values in `apps/rancher/values.yaml`, hostname from the
configuration repository). Its certificate joined the others in
`charts/routes`. The chart only accepts the first-login password as a plain
value, so that value is no longer set: Argo CD deploys the
`bootstrap-secret` Secret, built by `scripts/render-argocd-secrets.sh`, and
`extraEnv` gives Rancher the same `CATTLE_BOOTSTRAP_PASSWORD` variable from
it. `deploy.sh` waits for the application, then sets the admin password and
server URL through Rancher's API as before. The components Rancher installs
by itself (its webhook, Fleet, the system upgrade controller) are not part
of the application.

## 2026-10-12: Argo CD deploys Velero and the backup settings

On 2026-10-12, `scripts/install-velero-backup.sh` was replaced by three Argo
CD applications. `snapshot-controller` installs the CSI snapshot API from
the upstream repository at `v8.6.0`. `backup-config` applies
`manifests/backup`: Longhorn's snapshot class, the temporary storage class
and the recurring snapshot and backup jobs. `velero` installs the chart
(`12.2.0`) with its two Secrets, now built by
`scripts/render-argocd-secrets.sh`, and the backup schedule, which used to
be applied by hand. The address of the backup store moved to the
configuration repository. A test cluster leaves `velero` out, since it has
no store to back up to.

## 2026-10-12: Argo CD deploys kube-prometheus-stack

On 2026-10-12, kube-prometheus-stack moved to Argo CD as the `monitoring`
application (chart `92.2.0`, values in `apps/monitoring/values.yaml`). Its
four Secrets (Grafana's admin login, Cloudflare analytics token and Authelia
single sign-on settings, and Alertmanager's configuration) are now built by
`scripts/render-argocd-secrets.sh` and decrypted by Argo CD; all ten keys
matched the live Secrets before the handover. The one setting that differs
per cluster, the host alias that sends Grafana's single sign-on calls to
Traefik, moved to the configuration repository.

On production the comparison showed only Argo CD's tracking annotation on
103 resources. After the sync no monitoring pod had changed, 90 of 90
Prometheus targets were up, 152 alerting rules were loaded and only the
always-on Watchdog alert was firing. `deploy.sh` waits for the application
instead of creating the Secrets and installing the chart. Grafana is no
longer restarted automatically when its single sign-on Secret changes.

## 2026-10-12: Argo CD deploys Loki and Alloy

On 2026-10-12, the logging stack moved to Argo CD as two applications,
`loki` and `alloy`. Their values files moved from the repository root to
`apps/loki/values.yaml` and `apps/alloy/values.yaml`, and the chart versions
(Loki `18.14.0`, Alloy `1.13.0`) now live in the Application files. On
production the comparison showed only Argo CD's tracking annotation, no pod
restarted, and Loki reported ready afterwards. `deploy.sh` waits for the two
applications instead of installing the charts.

## 2026-10-12: Argo CD deploys the admin routes and the monitoring extras

On 2026-10-12, the manifests `deploy.sh` still applied by hand moved to two
Argo CD applications. `routes` (`charts/routes`) holds the HTTPS routes and
certificates of the Traefik dashboard, Longhorn, Grafana, Prometheus and
Argo CD. `monitoring-extras` (`charts/monitoring-extras`) holds the alert
rules, scrape targets, the Loki data source and the Grafana dashboards,
including the two that were built from JSON files with `kubectl create
configmap`. The files in its `manifests/` directory are emitted unchanged,
because alert rules and dashboards contain `{{ }}` of their own.

`kubectl diff` of both charts against production showed no difference before
the handover. `templates/generated` now holds one unused file kept for the
secret scan; `scripts/prepare-env.sh` only renders the Ansible inventory.
Legacy templates nothing used (`trilium-cert`, `trilium-ingress`,
`vaultwarden-cert`, `cloudflared-config`) and `apps/trilium/helm_install.txt`
were removed, as was `apply_manifest` from `deploy.sh`.

## 2026-10-12: Argo CD deploys cert-manager; installed first by deploy.sh

On 2026-10-12, cert-manager moved to Argo CD, the first of the platform
charts. Two applications took over: `cert-manager` (the chart, with
`apps/cert-manager/values.yaml`) and `cert-manager-config` (the
`letsencrypt-prod` ClusterIssuer from `charts/cert-manager-config`, and the
Cloudflare API token as a sops-encrypted Secret). On production the
comparison showed only Argo CD's tracking annotation; no pod restarted and
all ten certificates stayed ready.

Because cert-manager comes before almost everything, `deploy.sh` now
installs Argo CD first, straight after the cluster. Applications that
cannot sync yet keep retrying, and the script waits for each where it is
needed. Argo CD's ServiceMonitors are added by a second pass after
monitoring is installed.

Two changes came out of testing on the throwaway cluster. The issuer's ACME
server is now a setting, and the test environment uses Let's Encrypt's
staging service, so rebuilding the test cluster no longer counts against the
weekly limit on identical certificates. And `deploy.sh` now retries a
certificate that fails at the issuer: in two rebuilds out of two, Let's
Encrypt failed one order of ten at its last step ("Certificate not found",
then "orderNotReady"), after which cert-manager waits an hour. The script
clears that wait up to three times per certificate.

A rebuild from bare VMs with these changes completed in one run: 13
applications Synced and Healthy, 10 of 10 certificates, every pod running.
One certificate needed the retry, which was done by hand in that run; the
automatic version was then run against the same cluster without error, but
has not yet had a real failure to handle.

## 2026-10-12: Test environment for Argo CD; full rebuild tested

On 2026-10-12, `deploy.sh --bootstrap` was run against the throwaway test
cluster for the first time since Argo CD took over the applications. It
needed one thing first: a cluster built from this repository would have
deployed production's settings and Secrets, including the production tunnel
token. `apps/argocd/applications` is now a chart, and a cluster's
`config/cluster.env` can point it at a branch (`ARGOCD_APPS_REVISION`), a
directory of the configuration repository (`ARGOCD_APPS_CONFIG_PATH`, the
test cluster uses `envs/test/`) and leave applications out
(`ARGOCD_APPS_DISABLED`). The test cluster has its own Argo CD age key.
Production's eleven Applications render exactly as before.

The run found one defect. On a freshly installed cluster the `kyverno`
application never became Synced, so `deploy.sh` stopped after 15 minutes:
the chart gives its policy CRDs an empty `labels: {}` and `annotations: {}`,
which the API server drops, and Argo CD kept seeing a difference.
`apps/kyverno/values.yaml` now gives them a real label and annotation.
Production never showed this because Helm had installed those CRDs there.

After that fix the cluster was destroyed and rebuilt from nothing. The run
went from bare VMs through K3s, the platform charts, Argo CD and Authelia,
and stopped at the Rancher certificate, where Let's Encrypt answered
"Certificate not found" while finalizing one order of ten. With that
certificate requested again, a second `deploy.sh` finished: 11 applications
Synced and Healthy, 10 of 10 certificates ready, every pod running, all 18
Secret keys matching the test secrets file, and `rancher.` on the test
domain answering through the test tunnel. Production was not touched.

The test also showed that the test secrets file needs production's mail
login and website deploy key, as the procedure says: with stand-ins,
Authelia does not start, git-sync cannot fetch the site, and the Vaultwarden
invitation fails.

## 2026-10-11: Argo CD UI reachable through the Cloudflare tunnel

On 2026-10-11, `argocd.${BASE_DOMAIN}` was added as a public hostname on the
Cloudflare tunnel, in the Cloudflare dashboard. The UI had been LAN-only by
decision; it is now reachable from anywhere, behind Authelia (two-factor,
`admins` group) and then Argo CD's own login, like Longhorn and Grafana.
Nothing changed in the cluster: the route and the Authelia rule were already
in place. The `admin` password was changed from the generated one and is
kept in the password manager.

## 2026-10-11: Argo CD deploys Trilium and Vaultwarden

On 2026-10-11, Trilium and Vaultwarden moved to Argo CD, the last stage of
the plan. Each is a chart (`charts/trilium`, `charts/vaultwarden`) that
renders exactly what its template did, so neither pod was restarted.
Vaultwarden's two Secrets are now built by
`scripts/render-argocd-secrets.sh` and decrypted by Argo CD. The admin-token
hash is salted from the token instead of at random, so it no longer changes
on every run; the stored hash changed once as a result, and takes effect
when Vaultwarden next restarts.

Both applications sync from git with self-heal off. `recovery/restore.sh`
now pauses the Argo CD application that owns a Deployment before
`--promote-app` scales it down and repoints its volume, and resumes it on
`--rollback-app`. This also covers Authelia, which has self-heal on. Pausing
was tested on the website (a manual scale-down held while paused and was
undone 2 seconds after resuming); a promotion itself was not run.

## 2026-10-11: Argo CD deploys cloudflared and Authelia; secrets with sops

On 2026-10-11, cloudflared and Authelia moved to Argo CD, each as a small
chart (`charts/cloudflared`, `charts/authelia`) that renders the same
resources as the templates it replaces. Their Secrets moved too: they are
now in the private configuration repository, encrypted with sops, and Argo
CD decrypts them with the KSOPS plugin (`quay.io/viaductoss/ksops:v4.5.1`)
added to its repo server. Argo CD has its own age key
(`ARGOCD_SOPS_AGE_KEY`, a new required value), separate from the laptop's,
so the key kept in the cluster cannot decrypt `.secrets.enc`.

`scripts/render-argocd-secrets.sh` builds both Secrets from `.secrets.enc`,
taking over the argon2 hashing `deploy.sh` did for Authelia, and writes the
encrypted files. Its `--check` mode showed all 14 keys identical to the live
Secrets before the handover. `deploy.sh` now creates the `sops-age` Secret
before installing Argo CD, waits for the two applications instead of
deploying them, and verifies the admin UIs redirect to Authelia after Argo
CD has deployed it rather than before monitoring is installed.

The handover did not restart cloudflared; 68 of 68 requests through the
tunnel during it returned 200. Authelia restarted once, for the new
configuration checksum on its pod, which ended the open sessions. A change
to Authelia's Secret no longer restarts it automatically.

`.gitignore` rules for rendered files are now anchored to the repository
root. Unanchored, `authelia.yaml` and `cloudflared.yaml` also matched the
new chart template and Application files.

## 2026-10-11: Argo CD deploys fb-search from the private repository

On 2026-10-11, `apps/fb-search` moved, manifests and source together, to
`fb-search/` in the private `k3s-homelab-config` repository, and a
`fb-search` Argo CD application now builds it from there. Kustomize needs
the source next to the manifests, and the source is not published, so the
directory could not stay in this repository. The handover added only Argo
CD's tracking annotation; the pod was not restarted. `kubectl apply -k` is
no longer how fb-search is deployed. Its `fb-search` Secret is still
created by hand.

## 2026-10-11: Argo CD deploys the website; private configuration repository

On 2026-10-11, the website moved to Argo CD. Its manifests became a small
Helm chart, `charts/website`, replacing `templates/generated/website.yaml.template`
and `website-nginx.yaml`. The chart renders the same eight resources as
before, plus a checksum of the nginx config on the pods, so a config change
now rolls them without `deploy.sh`. The route for `/fb-search` moved into
the chart from `apps/fb-search/ingress.yaml`, which removes the last
hard-coded domain from that directory.

The domain comes from a new private repository,
`HomeLabJunkie/k3s-homelab-config`, which Argo CD reads with a read-only
deploy key (`ARGOCD_CONFIG_REPO_KEY_B64` in `.secrets.enc`, a new required
value). `deploy.sh` creates that credential and the website's git-sync key
before handing over to Argo CD, then waits for the `website` application.
Handing over rolled the pods once for the new checksum; 424 of 424 requests
during the sync returned 200.

fb-search was planned for the same stage and did not move. Its source
(`apps/fb-search/src/`) is deliberately kept out of this public repository,
so Argo CD cannot build it from here. It is still deployed with
`kubectl apply -k apps/fb-search`.

`scripts/validate-manifests.sh` now renders each chart in `charts/` with its
`ci-values.yaml` and validates the result. The chart is in `charts/` because
`.gitignore` excludes `apps/website/`, a rule from when site content lived
there.

## 2026-10-11: Argo CD deploys Trivy Operator, Kyverno and the policies

On 2026-10-11, five Argo CD applications took over what `deploy.sh` used to
install with Helm and `kubectl`: `trivy-operator`, `kyverno`,
`kyverno-policies`, `kyverno-custom-policies` and `network-policies`. A
`root` application creates them from `apps/argocd/applications/`, and all
belong to a `homelab` project that only allows this repository and the two
chart repositories as sources. Chart versions now live in the Application
files, and a change reaches the cluster by merging to `main`.

The handover changed nothing that runs: the comparison showed only Argo CD's
tracking annotation to add (and a `managed-by` label on four Trivy reports),
and no pod was replaced. Automated sync with self-heal is on and pruning is
off. Deleting a managed network policy brought it back in 3 seconds, and
changing the enforcing Kyverno policy to Audit by hand was undone in 2.

Two things came out of the handover. First, Argo CD showed that
`apps/network-policies/website.yaml` and `cloudflared.yaml` had never been
committed: `.gitignore` entries for the rendered `website.yaml` and
`cloudflared.yaml` at the repository root also matched them. The policies
were running, applied from one laptop, but were not in git. They are
committed now. Second, the earlier advice to delete a policy in an emergency
no longer works by itself, because Argo CD restores it; `docs/platform.md`
describes stopping the controller first. Two alerts were added:
`ArgoCDAppOutOfSync` and `ArgoCDAppUnhealthy`.

## 2026-10-11: Argo CD installed (engine only)

On 2026-10-11, Argo CD (chart `10.10.2`, Argo CD `v3.5.4`) was installed in a
new `argocd` namespace and added to `deploy.sh`. It manages nothing yet: no
`Application` exists. Its UI is at `argocd.<domain>` through Traefik, with a
Let's Encrypt certificate, behind Authelia (the hostname was added to the
`admins` two-factor rule, which restarted Authelia and ended existing
sessions) and Argo CD's own login. The hostname is not on the Cloudflare
tunnel. The bundled Dex and notifications controller are off, and Prometheus
scrapes all four components. Redis comes from `ecr-public.aws.com`, which was
added to Kyverno's allowed registries. `docs/platform.md` lists the stages in
which applications will move to Argo CD.

## 2026-10-11: Website restarts no longer drop requests

On 2026-10-11, the website's nginx container gained a 10-second `preStop`
sleep. Before it, each rollout failed one or two requests in the second after
an old pod stopped, because Traefik was still sending to it. Three restarts
with a request every half second then returned 200 every time. A rollout now
takes about ten seconds longer.

## 2026-10-11: Network policies for cloudflared, Trilium and Vaultwarden

On 2026-10-11, the `cloudflared`, `trilium` and `vaultwarden` namespaces got
default-deny network policies (`apps/network-policies/`), written from Hubble
recordings and trialled in Cilium's audit mode in the same way as `website`.
cloudflared may reach Cloudflare (7844, 443) and Traefik's pods; Trilium the
internet on 443; Vaultwarden the internet on 443 and 587. Each accepts only
Traefik, plus Prometheus for cloudflared. In audit mode, requests to every
tunnel hostname, Vaultwarden icon downloads and the `restore.sh` health checks
produced no would-be drops. Once enforced, all tunnel hostnames answered as
before, connections from Trilium and Vaultwarden to the Kubernetes API and the
Unraid server timed out, Vaultwarden still reached Gmail's SMTP port, the
health checks passed, and a cloudflared restart registered its eight tunnel
connections. The only drops recorded were cloudflared's start-up ICMP probes,
which this tunnel does not need.

## 2026-10-11: Network policies for the website namespace

On 2026-10-11, the `website` namespace got its first network policies
(`apps/network-policies/website.yaml`, applied by `deploy.sh`): deny by
default, then allow Traefik in, Prometheus to the fb-search metrics port,
cluster DNS, git-sync out to the internet on port 22 and fb-search out on 443.
The rules were written from traffic recorded with Hubble, which was already
running. They were trialled in Cilium's per-endpoint audit mode: normal use,
including a real fb-search search, produced no would-be drops, while test
connections to the Kubernetes API and to the Unraid server were flagged. Once
enforced, those connections and one to Home Assistant timed out, the site and
a search still worked, git-sync kept updating, Prometheus kept scraping, and a
restart of the site started cleanly. `docs/platform.md` describes the method.

A restart of the site drops one or two requests in a one-second window. The
same happens with the policies removed, so it is an existing gap in how the
old pods shut down, not an effect of the policies.

## 2026-10-11: Kyverno enforces restricted pods in the application namespaces

On 2026-10-11, a first blocking policy, `enforce-app-namespaces`, was added
in Deny mode for the `authelia`, `cloudflared`, `trilium`, `vaultwarden` and
`website` namespaces. It refuses pods and workloads that run as root, lack a
read-only root filesystem, seccomp profile or dropped capabilities, use host
access, or use unpinned images or unlisted registries. It was applied in Audit
mode first; all 13 existing pods and Deployments passed. In Deny mode a
non-compliant pod and Deployment were refused in those namespaces, a compliant
pod was accepted, a non-compliant pod in `default` was still accepted, and a
real `rollout restart` of cloudflared completed. The other 20 policies stay in
Audit mode.

`recovery/restore.sh` creates helper pods in the application namespaces, so
its health-check and restore-inspect pods now run as restricted, non-root
pods using the application's own user ID. `--health-check` for Trilium and
Vaultwarden and a `--restore-app` / `--cleanup-test` cycle for Trilium passed
with the new pods. A consequence of enforcement is that `kubectl rollout
undo` to a revision from before the hardening is refused.

The "Homelab - Security Scanning" dashboard gained a "Policy (Kyverno)" row,
and a `KyvernoAdmissionControllerDown` alert was added.

## 2026-10-11: Kyverno added in audit mode

On 2026-10-11, Kyverno (chart `3.9.1`, Kyverno `v1.19.1`) was installed in a
new `kyverno` namespace and added to `deploy.sh`, with 20 policies that only
report: the 17 Pod Security Standards "restricted" policies from the
`kyverno-policies` chart, and three in `apps/kyverno/policies/` (allowed image
registries, no `latest` tags, read-only root filesystems). The engine runs
with `forceFailurePolicyIgnore`, so a Kyverno outage cannot stop pods being
created. The first background scan wrote 380 policy reports with no
evaluation errors. The six applications this repository defines pass every
policy; the failures are in platform components that need host access.
`docs/observability.md` has the details.

## 2026-10-11: Vaultwarden runs as non-root

On 2026-10-11, the Vaultwarden pod stopped running as root. It now runs as
user 1000 with a read-only root filesystem, no Linux capabilities, no
privilege escalation, the default seccomp profile and an `emptyDir` at `/tmp`,
and listens on 8080 inside the pod instead of the privileged port 80; the
Service port is unchanged. The existing data files stay owned by root;
`fsGroup: 1000` changed their group to 1000 and added group write permission.
After the restart Vaultwarden logged no errors or warnings, `/alive` and
`/api/config` answered 200 through the public hostname, and the database file
kept its size. Trivy's manifest audit for the workload went from 3 high and 5
medium findings to 1 medium (the image registry check). A Longhorn snapshot,
`pre-nonroot-vaultwarden-20261011`, was taken just before the change.

## 2026-10-11: Trilium runs as non-root

On 2026-10-11, the Trilium pod stopped starting as root. The image's start
script runs as root to `chown` the data and then switches to the `node` user;
the Deployment now starts the server directly as user 1000
(`node ./main.mjs`), with a read-only root filesystem, no Linux capabilities,
no privilege escalation, the default seccomp profile and an `emptyDir` at
`/tmp`. The `USER_UID` and `USER_GID` variables, which only the start script
read, were removed. The data was already owned by 1000:1000; `fsGroup: 1000`
added group write permission and the setgid bit to the files on the volume.
After the restart Trilium reported the same 580 notes, passed its consistency
check and answered its health check. Trivy's manifest audit for the workload
went from 3 high and 4 medium findings to 1 medium (the image registry check).
A Longhorn backup of the volume from 09:20 UTC the same day existed before the
change.

## 2026-10-11: fb-search runs with a restricted security context

On 2026-10-11, both fb-search containers were given a read-only root
filesystem, no Linux capabilities and no privilege escalation, and the pod
now requires a non-root user and the runtime's default seccomp profile. It
already ran as user 1000. Chromium's profile, its caches and the location
lookup cache now go to an `emptyDir` at `/tmp` (`HOME=/tmp`), so they are
still discarded on restart as before. After the change a real search through
the scraper returned 54 listings in 28 seconds and left no Chromium processes
behind. Trivy's manifest audit for the workload went from 2 high and 8 medium
findings to 2 medium, both the image registry check.

## 2026-10-11: Website pods must run as non-root

On 2026-10-11, `runAsNonRoot: true` was added to the jeffriffle.com
Deployment. Its containers already ran as non-root users (git-sync 65533,
nginx 101) with read-only filesystems and no capabilities; the setting makes
Kubernetes refuse a future image that would run as root. Both pods were
replaced one at a time and the site answered 200 on every request during the
rollout. Trivy's manifest audit for the workload went from 6 medium findings
to 3, all of them the image registry check. The remaining low findings (user
IDs below 10000, no CPU limits) are left as they are.

## 2026-10-11: cloudflared runs with a restricted security context

On 2026-10-11, the cloudflared Deployment gained a security context: it must
run as the image's non-root user (65532), with a read-only root filesystem,
all Linux capabilities dropped, no privilege escalation and the runtime's
default seccomp profile. Both pods were replaced, each registered its four
tunnel connections with no errors, and the public sites kept answering.
Trivy's manifest audit for the workload went from 3 high and 4 medium
findings to 1 medium (the image registry check, which is a policy matter).

## 2026-10-11: Trivy Operator added

On 2026-10-11, Trivy Operator (chart `0.37.0`, operator `0.35.0`) was
installed in a new `trivy-system` namespace and added to `deploy.sh`. It scans
the images of every workload for known vulnerabilities and exposed secrets,
audits manifests and RBAC, and scores the cluster against the CIS, NSA and Pod
Security benchmarks. It only reads the cluster and writes report resources; it
uses no persistent storage and blocks nothing. One Trivy server pod holds the
vulnerability database for all scan jobs; without it, scans of multi-container
pods failed with "cache may be in use by another process". Its configuration is
`apps/trivy-operator/values.yaml`, and Prometheus scrapes the findings as
`trivy_*` metrics. `docs/observability.md` describes how to read the reports.

The same day a Grafana dashboard, "Homelab - Security Scanning"
(`dashboards/trivy-operator.json`), and two alerts were added:
`TrivyOperatorDown` and `TrivyExposedSecretInImage`. There is deliberately no
alert on vulnerability counts: the first scan found 19 critical and 318 high
findings across 63 images, most of them waiting on the image's publisher, so
such an alert would never clear.

## 2026-10-10: Traefik chart 41.7.1; ansible-core 2.21.5

On 2026-10-10, the Traefik Helm chart pin moved from `41.7.0` to `41.7.1`.
The Traefik version stays at `v3.7.14`; the chart only adds support for newer
Traefik Hub releases, and it renders the same manifests with this
repository's values. The supported `ansible-core` minimum was raised from
`2.21.4` to `2.21.5`, so each laptop's `.venv` has to be updated before
`deploy.sh` or the maintenance scripts will run.

## 2026-10-10: Full rebuild with deploy.sh tested on an isolated cluster

On 2026-10-10, `./deploy.sh --bootstrap` built the whole stack from empty VMs
on the isolated test cluster, in one pass of 25 minutes with no errors and no
intervention: six nodes Ready, 117 pods running, nine Let's Encrypt
certificates issued, seven Longhorn volumes healthy with the backup target
available, and Rancher answering from the internet through a Cloudflare
tunnel. It used a separate domain, tunnel and API token, and ran from a
separate clone of the repository; `docs/backup-and-dr.md` describes the
setup. The domain's DNS zone was compared with a backup afterwards and was
unchanged. This also proved the Rancher `--set-file` password change from
2026-10-09, which had not run live.

Getting there took twelve partial runs. Most stops were gaps in the test
environment, now fixed in `recovery/dr-test-cluster.sh`: each node gets a
200 GB dedicated Longhorn disk and 4 vCPUs, a seventh VM stands in for the
backup NAS, and disk syncs on the test dataset are relaxed so etcd keeps up.

The runs also found faults in `deploy.sh`, fixed here and proven with four
further runs:

- Vaultwarden was not restarted when its secrets changed, so a new mail
  password or admin token had no effect until something else restarted it.
  Its deployment is now stamped with a hash of those values, as Authelia's
  already was.
- The website was only waited on when its nginx config had just changed, so
  a run could report success with the site's pods failing. `deploy.sh` now
  always waits for the site and its certificate, and restarts it when the
  nginx config or the deploy key changes.
- After a deployment had been stuck, the next run could fail once at the
  same step on the stale status. The waits for Authelia, Vaultwarden and
  the website now ride that out.

Two prerequisites of a real rebuild are now documented: every node needs its
storage disk mounted at `/var/lib/storage` beforehand, and the mail login
must work, because Authelia will not start and the Vaultwarden invitation
fails without it.

## 2026-10-10: Rehearsal checks for Authelia and fb-search; iLO login in secrets

DR rehearsals now validate all eight restored volumes. Authelia is not
started, since it needs its production configuration; a small pod mounts
each of the two remaining volumes read-only and the rehearsal checks that
Authelia's `db.sqlite3` is a SQLite database and that the `fb-search`
dependencies and install marker are present. A full rehearsal on 2026-10-10
passed in 39 minutes with 21 checks and 0 failures, up from 17.

`recovery/dr-host-power.sh` still reads the iLO login from
`~/.config/ilo-ubuntu-hp`, and now falls back to `DR_ILO_USERNAME` and
`DR_ILO_PASSWORD` in `.secrets.enc` when that file does not exist, so a
replacement laptop can power the DR server on. The old DR VM on Unraid,
kept as a fallback since the move to `ubuntu-hp`, was deleted.

## 2026-10-10: Fresh bootstrap tested on an isolated cluster

On 2026-10-10, `site.yml` was run from scratch against six new VMs on
`ubuntu-hp` (three servers, three workers), created by the new
`recovery/dr-test-cluster.sh` on a NAT network that is firewalled off from
the LAN. The run passed in 8 minutes with no failures: all six nodes Ready on
`v1.36.5+k3s1`, every pod running, and secrets encryption enabled from first
boot. It confirmed the 2026-10-09 fixes on a real bootstrap: the servers
joined one at a time without deadlocking, and the cluster token was not on
any K3s command line and its staging file was gone afterwards.

The first attempt found a second deadlock of the same kind. The agent role
waited for each worker to be Ready, but on a fresh cluster no node is Ready
until Cilium is installed by the play that follows. `site.yml` now lets
workers register without that wait
(`k3s_agent_wait_for_ready: false`) and verifies that every node is Ready at
the end; node maintenance still waits for Ready as before. The test covers
the cluster layer only. `deploy.sh` and the applications were not run.

## 2026-10-10: DR host moved to ubuntu-hp; full rehearsal passed

On 2026-10-10, the DR host was rebuilt as a VM on the `ubuntu-hp` server
(KVM/libvirt, 8 vCPUs, 32 GB, 500 GB disk on the `tank` ZFS pool) at
`192.168.1.127`, replacing the 4 vCPU / 11 GB VM on Unraid. It was built with
the new `recovery/dr-host-build.sh`, which reads its versions from
production: K3s `v1.36.5+k3s1`, Cilium `1.20.2` and Longhorn `1.12.1`. The
old host was a K3s minor version behind. A full
`./recovery/dr-rehearsal.sh --execute` against the new host passed in 36
minutes: 8 volumes restored and bound, the six validated applications
started on their restored data (17 checks, 0 failures), and cleanup left a
clean preflight. Authelia's volume and `fb-search-deps` are restored and
bound but have no validation checks.

Two gaps showed up and were fixed. The bind and cleanup steps knew six
volumes while the restore plan had eight, so a rehearsal would have stopped
at BIND; and three DR helpers had the old node name `k3s-dr-test` hardcoded.
The rehearsal's help text and the docs also claimed that `--execute` asks
for `RESTORE`, `BIND` and `CLEANUP`; it runs unattended, and the text now
says so.

`ubuntu-hp` is powered on only for rehearsals. `recovery/dr-host-power.sh`
switches it on through its iLO and off again, and with
`DR_HOST_ON_DEMAND=true` `dr-status.sh` notes an unreachable DR host and
skips its checks instead of failing. The server also keeps a copy of the NAS
backup share in `tank/backup/k3s` (165 GB on the first run), refreshed and
snapshotted each time it boots. The `k3s-dr` SSH alias now points at the new
VM; the old VM is shut down on Unraid, with autostart disabled, and kept as
a fallback for now.

## 2026-10-09: etcd snapshot restore tested with encrypted Secrets

On 2026-10-09, the etcd snapshot from cluster bundle `20261009-132622`, the
first taken after secrets encryption was enabled, was restored into a
throwaway K3s `v1.36.5+k3s1` server in a Docker container on the operator
laptop. The container ran on an internal network with no route to the LAN and
with the agent disabled, so no workloads started. The snapshot's checksum
matched the bundle's `SHA256SUMS`, the `--cluster-reset` restore succeeded and
the restored API became ready with all 34 namespaces. All 180 Secrets were
readable; 179 matched production by hash and the other had since been
replaced in production. The restored etcd database still held its Secrets as
AES-CBC records. The restore refused to run without the cluster token, and
again with a wrong one, and the `K3S_TOKEN` in `.secrets.enc` matched the
live cluster's token. The test covers the control plane and Secrets only: no
workloads were started. Every test artifact was removed afterwards. The steps
are in [Backup and disaster recovery](backup-and-dr.md).

## 2026-10-09: K3s secrets encryption at rest

On 2026-10-09, secrets encryption was enabled on the running cluster, so
Secrets are now stored encrypted in etcd and in etcd snapshots (K3s's default
AES-CBC provider). `--secrets-encryption` was added to `extra_server_args`,
and the documented K3s procedure for an existing HA cluster was followed:
`k3s secrets-encrypt enable` on `k3s-node-0`, each of the three servers
reconciled in turn with `maintain-node.sh --apply`, `rotate-keys` on
`k3s-node-0`, which re-encrypted all 180 Secrets, then a second restart of
each server. All three report `Encryption Status: Enabled` with matching
hashes. As a check, a throwaway Secret and ConfigMap were created and an etcd
snapshot taken: the Secret's value did not appear in the snapshot and the
ConfigMap's did. Every `maintain-node.sh` run passed its post-maintenance
validation, Longhorn volumes returned to healthy between servers, and no pods
were left unhealthy. Cluster bundles were taken before (`20261009-124046`)
and after (`20261009-132622`); the first is the last one whose snapshot holds
Secrets unencrypted. Restoring a snapshot now needs the cluster's
`K3S_TOKEN`, as described in
[Backup and disaster recovery](backup-and-dr.md). A snapshot restore was
tested later the same day; see the entry above.

## 2026-10-09: Portainer removed

On 2026-10-09, Portainer was removed; Rancher is the only management UI. The
Helm release (chart `245.1.0`), its IngressRoute and certificate, and the
`portainer` namespace were deleted, which also deleted the 20 GiB Longhorn
volume. Its data was not kept: the Longhorn backup volume and its 42 backups
were deleted from the NAS as well. `deploy.sh` no longer installs it, and it
was taken out of `recovery/apps.conf`, the DR rehearsal scripts, the Velero
`protected-apps-daily` schedule (applied the same day) and the documentation.
Afterwards `dr-status.sh` reported 7 protected workloads with 7 fresh
backups, and a DR rehearsal now restores six volumes instead of seven. Two
things clear on their own: the Authelia access rule for the Portainer
hostname goes with the next `deploy.sh` run, and the Velero backups that
still contain the namespace expire by 2026-10-16.

`repo-doctor.sh` also gained a manifest-validation section the same day; it
is skipped under `--quick`.

## 2026-10-09: Manifest validation against the cluster's CRDs

On 2026-10-09, `scripts/validate-manifests.sh` was added. It runs
`kubeconform` in strict mode over every Kubernetes manifest in the
repository, including the rendered ones that Git ignores, and is read-only.
A first run against the public CRD schema catalog had reported
`task: system-backup` on a Longhorn RecurringJob as invalid although the
installed Longhorn accepts it, so the script validates against schemas
exported from the cluster's own CRDs and against its Kubernetes version
instead. The exported schemas are closed, so a misspelt field in a custom
resource is rejected. Schemas are cached under
`~/.cache/k3s-homelab/manifest-schemas` and reused with `--offline`. On both
laptops all 118 resources in 34 files validated against Kubernetes 1.36.5 and
227 exported CRD schemas. The run on the T480 also turned up a stale,
gitignored `apps/longhorn/longhorn-ingress.yaml` from September that nothing
used; it was deleted. The check needs `kubeconform` on the laptop and is not
part of CI or `repo-doctor.sh`.

## 2026-10-09: Credential handling, backup permissions and bootstrap hardened

On 2026-10-09, three findings from a repository security audit were fixed.
`deploy.sh` now passes the Rancher bootstrap password to Helm with
`--set-file` instead of on the command line, and the `k3s_server` role has
`k3s-init` read the cluster token from a root-only file
(`k3s_server_init_token_file`) that is removed when bootstrap finishes, so
neither credential appears in a process list. `backup.sh` stages under
`umask 077` and strips group and other access from the published bundle,
failing the backup if any entry is still open; before, the etcd snapshot,
which holds every Kubernetes Secret, was published world-readable. Bundles
already on the NAS keep their old permissions, and the snapshot is still
stored unencrypted. Finally, a fresh multi-server bootstrap could not
complete: the servers play runs one host at a time, but each server waited
for every control-plane node to join. Each server now waits only for itself,
and a separate play in `site.yml` verifies full membership afterwards.
Redeploys of an existing cluster were never affected. The backup change is
covered by a new test and the playbooks pass a syntax check; none of the
three has yet been used on a live bootstrap, Rancher install or backup run.

## 2026-10-08: Traefik rejects encoded null characters

On 2026-10-08, the `web` and `websecure` entrypoints were set to reject
request paths containing an encoded null character (`%00`), through two
`allowEncodedNullCharacter=false` flags in `additionalArguments` (release
revision 27, chart and image unchanged). Traefik allows all seven encoded
characters by default and logs a startup warning when no entrypoint denies
any of them; an encoded null has no legitimate use in a path, so denying it
removes the warning without affecting the applications behind the proxy. The
other six, including encoded slashes and percents, are still allowed. Both
replicas rolled out cleanly. Afterwards Grafana returned its usual `302`
through the ingress address and a path containing `%00` returned `400`. The
only startup warning left is the cross-namespace notice, which is expected:
five IngressRoutes share the `traefik/admin-ui-auth` middleware.

## 2026-10-08: Traefik chart 41.7.0

On 2026-10-08, the Helm chart was upgraded from `41.6.1` to `41.7.0` (release
revision 26), moving Traefik from `v3.7.13` to `v3.7.14` with the existing
release values. `deploy.sh` defaults to the same chart version. v3.7.14 fixes
eight security advisories. Its migration notes cover the Ingress-NGINX and
Gateway API providers and OTLP histograms, none of which are enabled here.
With this repository's values the rendered manifests differ only in the image
tag and the `helm.sh/chart` label, and the CRDs are unchanged. Both replicas
rolled out one at a time with no errors or warnings logged, and 97 paired
probes of the site, on the LAN address and through Cloudflare, all succeeded
during the roll. Every ingress hostname returned the same response before and
after, and Rancher's `/ping` returned `pong` through the ingress service.
See the upstream
[release notes](https://github.com/traefik/traefik/releases/tag/v3.7.14).

## 2026-10-08: kube-vip v1.2.4

On 2026-10-08, kube-vip was upgraded from `v1.0.4` to `v1.2.4`;
`kube_vip_tag_version` in the Ansible group variables now matches. The
releases in between are mostly BGP, egress and service-mode work; for this
cluster's ARP control-plane mode they bring leader-election and ARP fixes. The
required RBAC is unchanged. The DaemonSet was switched to `OnDelete` for the
roll so the pods could be replaced one at a time: the two standbys first, each
checked for a clean start, then the leader. The strategy was restored to
`RollingUpdate` afterwards.

Three failovers were measured by probing `/readyz` on the API address about
twice a second. From a wired laptop and from a worker node, each failover cost
one to three failed probes. From a laptop on Wi-Fi, a failover that moved the
address to a different node left the API unreachable for three to seven
minutes, because that laptop kept using the previous node's MAC address. Only
clients outside the cluster are affected: the nodes reach the API through
their local load balancer, and ingress traffic uses the MetalLB address.
Whether v1.0.4 behaved the same from Wi-Fi was not measured. Afterwards all
three pods were ready with no errors logged, the API and etcd reported ok, and
the three kube-vip scrape targets were up.

## 2026-10-08: MetalLB v0.16.1

On 2026-10-08, MetalLB was upgraded from `v0.15.3` to `v0.16.1` by applying
the upstream `metallb-native.yaml`; `metal_lb_controller_tag_version` and
`metal_lb_speaker_tag_version` in the Ansible group variables now match. Only
three CRDs, the controller, the speakers and one RoleBinding changed. The
Traefik service kept `192.168.0.200`, announced from the same node, and 204
probes of that address at half-second intervals during the roll all succeeded.

Since 0.16, MetalLB serves metrics over HTTPS on port `metricshttps` (9120)
and checks the scraper's token with the Kubernetes API, so the old plain-HTTP
monitor stopped working. `monitoring-scrape-targets.yaml` now grants the
controller and speakers the token and access review permissions that check
needs, and the `metallb` PodMonitor moved from `metallb-system` to the
`monitoring` namespace so it can present Prometheus's own token. `deploy.sh`
deletes the old monitor. All seven MetalLB targets were up again afterwards.
See the upstream
[release notes](https://metallb.io/release-notes/#version-0-16-1).

## 2026-10-08: kube-prometheus-stack chart 92.2.0

On 2026-10-08, the Helm chart was upgraded from `87.21.0` to `92.2.0` (release
revision 20) with its existing values, after a monitoring-only Velero backup
(`monitoring-pre-kps-92-2-0`) and after applying the chart's ten Prometheus
Operator CRDs (`v0.94.1`) server-side. `deploy.sh` defaults to the same chart
version. The upgrade moves Prometheus Operator from `v0.92.1` to `v0.94.1`,
Prometheus from `3.13.1` to `3.15.0`, Alertmanager from `0.33.1` to `0.34.1`
and Grafana from `13.1.1` to `13.2.3`. Grafana now runs from its distroless
image with a read-only root filesystem, and the control-plane monitors
authenticate with a token Secret the chart creates; neither needed a values
change here.

The first attempt (revision 19) failed: the new Grafana pod was scheduled on a
different node and could not attach the ReadWriteOnce data volume while the
old pod still held it. `monitoring-values.yaml` now sets Grafana's
`deploymentStrategy` to `Recreate`, which let the rollout finish. The old
Grafana pod kept serving for the ten minutes the new one was stuck, and
`KubernetesDeploymentUnavailable` fired and cleared. Afterwards all 81 scrape targets across 26 pools were up,
the 35 rule groups loaded, only `Watchdog` was firing, 24-hour-old data was
still queryable, and Grafana's sign-in redirected to Authelia. See the chart's
[upgrade guide](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/UPGRADE.md).

## 2026-10-08: maintain-node.sh waits for Longhorn after the uncordon

On 2026-10-08, `maintain-node.sh` was changed so that a node which passes its
own checks (API, node Ready, Cilium, kube-vip) is uncordoned first, and the
Longhorn check then waits up to 30 minutes for that node's replicas to
rebuild. Before, Longhorn was judged while the node was still cordoned, when
its replicas are stopped, so every node in the K3s v1.36.5 roll reported FAIL
and was left cordoned. A node that fails its own checks still stays cordoned.
If Longhorn does not recover in time the run still fails and stops, with the
node left in service so the rebuild can continue. The wait is set by
`POST_MAINTENANCE_LONGHORN_ATTEMPTS` and
`POST_MAINTENANCE_LONGHORN_INTERVAL_SECONDS`. The change is covered by the
mock tests and a check-mode run; it has not yet been used on a live roll.

## 2026-10-08: K3s v1.36.5

On 2026-10-08, all six nodes were upgraded from `v1.36.4+k3s1` to
`v1.36.5+k3s1`, after a fresh cluster recovery bundle (`backup/backup.sh`,
`RESULT: BACKUP PASSED`) and check-mode dry runs on one control-plane node and
one worker. The release updates Kubernetes to v1.36.5, fixes restore from
compressed etcd snapshots and bumps gRPC for CVE-2026-84445. Its warning about
the bundled Traefik chart does not apply, because K3s runs here with
`--disable traefik`.

The nodes were rolled one at a time with `maintain-node.sh --apply --yes`,
control plane first (`k3s-node-0` to `k3s-node-2`), then the workers. On every
node the API, node, Cilium and kube-vip checks passed, but the Longhorn check
failed and the script left the node cordoned: it checks volume robustness
while the node is still cordoned, when Longhorn has stopped that node's
replicas. Each node was then uncordoned by hand and the next one started only
after all nine volumes were healthy again, which took between three and
sixteen minutes per node. Afterwards all six nodes were Ready on v1.36.5 with
none cordoned, etcd and `/readyz` reported ok, Cilium showed 6/6 nodes
reachable, all ten certificates were Ready, and seven public hostnames
returned the same status codes as before. See the upstream
[release notes](https://github.com/k3s-io/k3s/releases/tag/v1.36.5%2Bk3s1).

## 2026-10-08: Alloy chart 1.13.0

On 2026-10-08, the Alloy Helm chart was upgraded from `1.11.1` to `1.13.0`
(release revision 15) with the existing `alloy-values.yaml`, moving Alloy from
`v1.18.1` to `v1.20.0` and its config reloader from `v0.91.0` to `v0.94.0`.
`deploy.sh` defaults to the same chart version. The breaking changes in Alloy
1.19 and 1.20 concern `prometheus.write.queue` and `otelcol.*` components,
none of which this configuration uses. The new pod reported ready and log
lines kept arriving in Loki. For its first two minutes Alloy re-sent older
pod log lines, which Loki rejected as `entry too far behind`; no errors were
logged after that.

## 2026-10-07: Trilium v0.106.0

On 2026-10-07, the image was upgraded from `triliumnext/trilium:v0.104.1` to
`v0.106.0`, skipping v0.105.0, after a Trilium-only Velero backup
(`trilium-pre-0-106-0`). Only the image tag changed in the rendered manifest.
On first start Trilium wrote its own `backup-before-migration.db`, migrated
the database from version 239 to 240, and passed its consistency checks with
no errors logged; `/api/health-check` returned `ok` from inside the pod and
the ingress redirected to login as before.

The two releases change some behaviour:

- General HTML in text notes is no longer preserved by default (re-enable
  under Options → Text notes → Preserve unsupported HTML tags), and `<div>`s
  in text notes are unwrapped.
- `#label=value` searches now match the full value only.
- MCP access now requires authentication.
- `cheerio` is no longer built in for scripts.

See the upstream
[v0.105.0](https://github.com/TriliumNext/Trilium/releases/tag/v0.105.0) and
[v0.106.0](https://github.com/TriliumNext/Trilium/releases/tag/v0.106.0)
release notes.

## 2026-10-07: Cilium 1.20.2

On 2026-10-07, Cilium was upgraded from `1.20.1` to `1.20.2` (Helm release
revision 13) with its existing values; `cilium_tag` in the Ansible group
variables now matches. 1.20.2 is a bug-fix release, including fixes for two
agent crashes and for dropped traffic and connection handling in the BPF load
balancer. With this cluster's values the rendered chart differs only in image
tags: the agent, operator and Hubble Relay moved to `v1.20.2`, Envoy to
`v1.37.6` and Hubble UI to `v0.13.6`. The agents rolled two nodes at a time
with no container restarts anywhere in the cluster. Afterwards every agent
reported `OK` with 6/6 nodes reachable, all six nodes stayed Ready, a
cross-node service call and outbound HTTPS from a pod succeeded, and seven
public hostnames returned the same status codes before and after. See the
upstream
[release notes](https://github.com/cilium/cilium/releases/tag/v1.20.2).

## 2026-10-07: Rancher 2.15.2 and Loki chart 18.14.0

On 2026-10-07, Rancher was upgraded from `2.15.1` to `2.15.2` (release
revision 15) with its existing Helm values, after an on-demand etcd snapshot
(`pre-rancher-2-15-2`). 2.15.2 is a patch release with security fixes: logout
now revokes the server-side session token, unauthenticated users can no longer
modify public UI settings, and three Fleet issues are closed. Both replicas
rolled out on `v2.15.2`, `/ping` returned `pong`, the `local` cluster stayed
Ready, and Rancher then upgraded its own Fleet (`0.16.2`), webhook (`0.11.3`)
and Turtles (`0.27.2`) charts. See the upstream
[release notes](https://github.com/rancher/rancher/releases/tag/v2.15.2).

The same day, the Loki Helm chart was upgraded from `18.9.0` to `18.14.0`
(release revision 14) with the existing `loki-values.yaml`, moving Loki and
its canary from `3.7.6` to `3.7.8` and the gateway's access-log exporter from
`0.4.11` to `0.4.21`. Loki restarted once on its existing volume and reported
ready, new log lines arrived from 35 streams within two minutes, and logs from
1, 6, 24 and 72 hours earlier were still queryable. `deploy.sh` defaults to
both new chart versions.

## 2026-10-07: Portainer chart 245.1.0 and Velero chart 12.2.0

On 2026-10-07, the Portainer Helm chart was upgraded from `245.0.0` to
`245.1.0` (release revision 16) and the Velero Helm chart from `12.1.0` to
`12.2.0` (release revision 12), each with its existing values. `deploy.sh` and
`scripts/install-velero-backup.sh` default to the same chart versions. Both
are chart-only changes: `portainer-values.yaml` already pinned
`portainer-ce:2.45.1-alpine` and `velero-values.yaml` already pinned
`velero:v1.18.4`, so the rendered manifests differ only in chart labels, the
Velero CRDs are unchanged, and no pod restarted. Portainer answered through
its ingress as before. Velero's `garage` storage location stayed Available,
all six node agents stayed ready, the daily schedule stayed enabled, and a
test backup (`velero-post-chart-12-2-0`) completed.

## 2026-10-07: cert-manager v1.21.2

On 2026-10-07, the Helm chart was upgraded from `v1.21.1` to `v1.21.2`
(release revision 20) with the same `crds.enabled=true` setting. `deploy.sh`
defaults to the same chart version. v1.21.2 is a bug-fix release that upstream
advises all users to take: it fixes controller and webhook panics and ACME
renewal bugs, and stops ACME and Vault issuers copying untrusted HTTP response
bodies into status conditions and Events. The controller, webhook and
cainjector rolled out cleanly, all ten certificates and the `letsencrypt-prod`
ClusterIssuer stayed Ready, and a server-side dry run of a new Certificate
passed the admission webhook. See the upstream
[release notes](https://github.com/cert-manager/cert-manager/releases/tag/v1.21.2).

## 2026-10-07: Vaultwarden 1.37.4

On 2026-10-07, the image was upgraded from `vaultwarden/server:1.37.3` to
`1.37.4`, after a Vaultwarden-only Velero backup (`vaultwarden-pre-1-37-4`).
1.37.4 is a security release fixing seven advisories, the most severe being
revoked organization members keeping access (High, 8.1) and a two-factor
authentication flaw (Medium, 6.8). Its upgrade notes do not apply here:
`IP_HEADER` and Duo are not configured, and the database is SQLite. Only the
image tag changed in the rendered manifest. The pod started cleanly with no
errors or warnings logged, and `/alive` returned 200 before and after. See the
upstream
[release notes](https://github.com/dani-garcia/vaultwarden/releases/tag/1.37.4).

## 2026-10-07: cloudflared 2026.10.0

On 2026-10-07, the image was upgraded from `cloudflare/cloudflared:2026.9.1`
to `2026.10.0`, skipping 2026.9.2 and 2026.9.3. The releases in between harden
Quick Tunnel authentication, which this tunnel does not use, cap response
sizes and update dependencies. 2026.10.0 normalizes request paths when access
rules are used, retries DNS resolution and cancels QUIC reads when request
bodies close. Only the image tag changed in the rendered manifest. Both
replicas rolled out one at a time and each registered four `http2`
connections, all six nodes remained Ready, and seven public hostnames returned
the same status codes before and after. See the upstream
[release notes](https://github.com/cloudflare/cloudflared/blob/2026.10.0/RELEASE_NOTES).

## 2026-10-06: fb-search process reaping and cached dependencies

On 2026-10-06, the fb-search pod was given `shareProcessNamespace: true`, so
the pause container is PID 1 and reaps the Chromium processes each search
orphans. The previous pod had built up 57 defunct `chrome-headless` processes
in six days; the new pod showed none after three browser runs. The same day,
the dependency-caching change merged on 2026-09-23 was applied for the first
time: packages now install, hash-verified, into the `fb-search-deps` Longhorn
volume and are reused on restart. `apps/fb-search` is not part of `deploy.sh`
and reaches the cluster only through `kubectl apply -k apps/fb-search`.

## 2026-10-01: Traefik chart 41.6.1

On 2026-10-01, the Helm chart was upgraded from `41.6.0` to `41.6.1`
(release revision 25), retaining Traefik `v3.7.13` and the existing release
values. `deploy.sh` defaults to the same chart version. The chart change only
adds Traefik Hub v3.21.0 support: with this repository's values the rendered
manifests differ only in the `helm.sh/chart` label, and the CRDs are unchanged.
Both replicas rolled out cleanly, all six nodes remained Ready, and every
ingress hostname returned the same response before and after, with Rancher's
`/ping` returning `pong` through the ingress service with HTTPS certificate
validation.
See the [upstream chart release](https://github.com/traefik/traefik-helm-chart/releases/tag/v41.6.1).

## 2026-09-24: Vaultwarden 1.37.3

On 2026-09-24, the image was upgraded from `vaultwarden/server:1.37.1` to
`1.37.3`, after a Vaultwarden-only Velero backup (`vaultwarden-pre-1-37-3`).
1.37.2 is required by Bitwarden clients 2026.8.0 and newer. 1.37.3 fixes
password changes from the newer web vault, and it revokes remembered 2FA
devices when credentials or 2FA settings change. The pod started cleanly and
`/alive` returned 200. See the upstream
[1.37.2](https://github.com/dani-garcia/vaultwarden/releases/tag/1.37.2) and
[1.37.3](https://github.com/dani-garcia/vaultwarden/releases/tag/1.37.3)
release notes.

## 2026-09-21: Traefik values

On 2026-09-21, `traefik-values.yaml` was updated (release revision 15, same
chart and Traefik version, PR #40):

- `aliasHeadersStrategy: delete` on all four entrypoints (`web`, `websecure`,
  `traefik`, `metrics`), so clients cannot spoof managed headers with aliased
  names such as `X_Auth_User`. Apps that rely on underscore-style header names
  would break; none were found.
- `--providers.kubernetescrd.safeNaming=false` set explicitly through
  `additionalArguments`, keeping the legacy naming scheme. The chart omits the
  flag when the value is `false`, so it cannot be set through chart values.

Both replicas rolled out cleanly and the ingress hosts still responded. The
remaining startup warnings are the deliberate `allowCrossNamespace` setting and
the encoded-characters default.

## 2026-09-17: Traefik chart 41.6.0

On 2026-09-17, the Helm chart was upgraded from `41.5.0` to `41.6.0`
(release revision 14), retaining Traefik `v3.7.13` and the existing release
values. `deploy.sh` defaults to the same chart version. Both replicas passed
rollout verification, all six nodes remained Ready, and Rancher's `/ping`
returned `pong` through the ingress service with HTTPS certificate validation.
See the [upstream chart release](https://github.com/traefik/traefik-helm-chart/releases/tag/v41.6.0).
Startup logs still warned about unset `aliasHeadersStrategy` and `SafeNaming`,
and enabled cross-namespace references; these settings were preserved.

## 2026-08-26: Public history reset

Repository history was reset to a sanitized public root commit on 2026-08-26.
The public history contains no earlier private commits; an encrypted local
backup was retained by the repository owner. The sanitized tree was checked
with the repository scanner and Gitleaks before publication.

## 2026-08-22: DR readiness after recovery

The post-recovery readiness run on 2026-08-22 confirmed:

```text
Production nodes:    6/6 Ready
Protected workloads: 7
Fresh backups:       7
Stale backups:       0
Missing backups:     0
Restore capacity:    175.0 GiB
20% headroom target: 210.0 GiB
DR available:        358 GiB
DR preflight:        14 PASS / 0 WARN / 0 FAIL
Result:               DR READY
```

## 2026-08-21: Full DR rehearsal passed

The full automated rehearsal completed successfully on 2026-08-21.

Application/data validation:

```text
PASS: 20
WARN: 0
FAIL: 0
```

Post-cleanup DR preflight:

```text
PASS: 14
WARN: 0
FAIL: 0
```

Final result:

```text
RESULT: FULL DR REHEARSAL PASSED
```

The rehearsal proved:

- all seven current Longhorn restore volumes can be recovered
- large restores can safely resume after transient API pressure
- matching completed restores are detected as `SKIP-COMPLETE`
- correct existing PV/PVC bindings are idempotent
- Prometheus historical TSDB data is queryable
- Loki restored historical/index data is visible
- application databases are non-empty and readable
- cleanup returns the DR host to a clean baseline
- Longhorn backups remain untouched
