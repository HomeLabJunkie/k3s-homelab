# Changelog

[Back to the README](../README.md)

Dated notes on upgrades, configuration changes and validated recovery results,
newest first. The other documents describe how things work today; this file
records what changed and when. Merged pull requests hold the full detail.

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
