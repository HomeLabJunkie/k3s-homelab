# Changelog

[Back to the README](../README.md)

Dated notes on upgrades, configuration changes and validated recovery results,
newest first. The other documents describe how things work today; this file
records what changed and when. Merged pull requests hold the full detail.

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
