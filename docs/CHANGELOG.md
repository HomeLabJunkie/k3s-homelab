# Changelog

[Back to the README](../README.md)

Dated notes on upgrades, configuration changes and validated recovery results,
newest first. The other documents describe how things work today; this file
records what changed and when. Merged pull requests hold the full detail.

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
