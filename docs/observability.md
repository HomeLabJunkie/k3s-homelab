# Monitoring and logging

[Back to the README](../README.md)

## Monitoring

The monitoring stack uses `kube-prometheus-stack`.

Components include:

- Prometheus
- Alertmanager
- Grafana
- kube-state-metrics
- node-exporter
- Prometheus Operator
- Longhorn ServiceMonitor
- scrape targets for other cluster components (`charts/monitoring-extras/manifests/monitoring-scrape-targets.yaml`)
- homelab baseline alert rules
- custom Grafana dashboards

`monitoring-scrape-targets.yaml` in that directory holds PodMonitors for components that expose
metrics without creating their own monitor: Traefik, cert-manager, MetalLB, the
Cilium operator and Envoy proxies, kube-vip, Loki, loki-canary, Alloy and
cloudflared. These feed the Traefik (per-app requests, 5xx rate, p95 latency)
and Certificates (days until expiry) dashboards. Vaultwarden and Trilium
have no metrics endpoint of their own, so Traefik's per-service
metrics are their traffic view. The Cilium agent does not serve metrics because
`prometheus-serve-addr` is unset in `cilium-config`.

The log panels on the homelab dashboards filter on Loki's `detected_level`
rather than matching the word "error" in the line text, so INFO lines that
mention error fields no longer appear.

The "Homelab - Argo CD (GitOps)" dashboard
(`charts/monitoring-extras/dashboards/argocd.json`) shows what Argo CD is
doing: how many applications are out of sync or not healthy, a row per
application with its sync, health and auto-sync state, both over time, syncs
per hour by application, and how long Argo CD takes to compare with Git. The
sync counts start again when the application controller restarts, so the
24-hour totals can read low after one.

Certificate alerts (`homelab.certificate.rules` in
`charts/monitoring-extras/manifests/monitoring-longhorn-v2.yaml`) email a warning when a certificate has under 14
days left, a critical under 7 days, a warning when one stays not Ready for an
hour, and a warning if cert-manager metrics disappear so the others would go
silent. Let's Encrypt renews at 30 days, so expiry alerts mean renewal has been
failing for about two weeks.

Alertmanager routes warning and critical alerts through the SMTP credentials
already stored in `.secrets.enc`. The configuration is rendered at deployment
time, so SMTP passwords are never written to tracked files. The always-firing
`Watchdog` alert is intentionally suppressed until an external dead-man
receiver is configured.

The workstation DR monitor uses the same credentials through
`monitoring/dr-notify.sh`. Run `./monitoring/dr-notify.sh --check` to validate
the configuration without sending mail. An optional `config/email.env` can
override the shared account.

The Prometheus UI is at `prometheus.${BASE_DOMAIN}`, defined with Grafana's
IngressRoute in `charts/routes/templates/monitoring.yaml`. Prometheus has no login of its own, so the
route uses the same `admin-ui-auth` Authelia middleware as the Traefik
dashboard and Longhorn (see [Authelia](authelia.md)). The Cloudflare
tunnel's hostnames are managed in the Zero Trust dashboard, so a new hostname
also needs a public hostname entry there pointing at
`https://${CLOUDFLARE_ORIGIN_IP}` with No TLS Verify, like the others.

Persistent monitoring data is stored on Longhorn.

Protected monitoring PVCs include:

- Grafana
- Prometheus
- Alertmanager

The deployment explicitly verifies that monitoring PVCs are Bound using the `longhorn` StorageClass.

## Logging

Cluster logging uses:

- Loki
- Grafana Alloy
- Grafana Loki datasource
- logging-focused Grafana dashboards

Loki storage is Longhorn-backed and is part of the tested DR recovery set.

Alloy collects Kubernetes logs and sends them to Loki.

Loki rejects entries older than 168h. Alloy resends the last line it read
whenever it reconnects to a pod's log stream, so for a pod that has been quiet
longer than that, Loki would reject the same stale line on every reconnect.
Alloy's `drop_stale` stage drops lines older than 167h before sending them;
`loki_process_dropped_lines_total` counts them.

## Security scanning

Trivy Operator runs in the `trivy-system` namespace, installed by Argo CD
(see [Argo CD](platform.md#argo-cd)) from `apps/trivy-operator/values.yaml`. It only reads the cluster: it starts
short-lived scan jobs in its own namespace and stores the results as report
resources next to each workload. It does not change or block anything.

| Report | What it covers |
| --- | --- |
| `vulnerabilityreports` | Known vulnerabilities (CVEs) in each container image |
| `exposedsecretreports` | Credentials found inside image layers |
| `configauditreports` | Manifest problems, such as containers running as root |
| `rbacassessmentreports`, `clusterrbacassessmentreports` | Over-broad roles |
| `infraassessmentreports` | Settings of the Kubernetes components themselves |
| `clustercompliancereports` | Scores against the CIS, NSA and Pod Security benchmarks |

```bash
kubectl get vulnerabilityreports -A -o wide
kubectl -n vaultwarden describe vulnerabilityreport <name>
kubectl get clustercompliancereports
```

A workload is scanned when it is created or its image changes, and each
report is replaced after 24 hours, so new vulnerabilities in an unchanged
image still appear. At most three scan jobs run at a time, and they all ask
the `trivy-server` pod, which holds the vulnerability database on the node's
disk and downloads it again if the pod moves.

Prometheus scrapes the totals through the chart's ServiceMonitor, for example
`trivy_image_vulnerabilities` (per workload and severity) and
`trivy_resource_configaudits`. The "Homelab - Security Scanning" Grafana
dashboard (`charts/monitoring-extras/dashboards/trivy-operator.json`) shows them: totals with each
image counted once, the trend, the worst images, workloads failing manifest
checks, benchmark results and risky roles.

Two alerts in `monitoring-longhorn-v2.yaml` (same directory) cover the scanner:
`TrivyOperatorDown` (no metrics for 30 minutes) and
`TrivyExposedSecretInImage` (a credential found inside an image). Vulnerability
counts do not alert, because most findings wait on the image's publisher.

## Policy

Kyverno runs in the `kyverno` namespace, installed by Argo CD from
`apps/kyverno/`. It checks pods against written rules when they are created
or changed and re-checks everything in the background. Where Trivy reports
what is wrong today, Kyverno states the rule and keeps checking it.

There are 21 policies. Twenty are in **Audit** mode: they write a result and
never block.

- 17 from the `kyverno-policies` chart, the Kubernetes Pod Security Standards
  at the "restricted" level (`apps/kyverno/policies-values.yaml`).
- 3 written for this cluster in `apps/kyverno/policies/`: images only from the
  registries already in use, no `latest` or missing image tags, and read-only
  root filesystems.

```bash
kubectl get validatingpolicies
kubectl get policyreports -A
kubectl -n vaultwarden describe policyreport
```

The applications this repository defines (Authelia, cloudflared, Trilium,
Vaultwarden, the website and fb-search) pass all 20. Most failures come from
platform components that need host access to work: Longhorn, Cilium, MetalLB,
kube-vip and Velero's node agents.

Kyverno's webhook sees every pod and workload create and update outside
`kube-system` and `kyverno`. Two settings keep it from ever standing in the
way: each policy has `failurePolicy: Ignore`, and the engine runs with
`forceFailurePolicyIgnore`, so if Kyverno is down requests are admitted
unchecked. The `KyvernoAdmissionControllerDown` alert fires when that has been
the case for 15 minutes.

### The one policy that blocks

`apps/kyverno/policies/enforce-app-namespaces.yaml` is in **Deny** mode for
the `authelia`, `cloudflared`, `trilium`, `vaultwarden` and `website`
namespaces. There, a pod, or a Deployment, StatefulSet, DaemonSet, Job or
CronJob that would create one, is refused unless it:

- runs as non-root, with no privilege escalation and all capabilities dropped;
- has a read-only root filesystem and a seccomp profile;
- uses no host network, process or IPC namespace, no hostPath volume and no
  privileged container;
- uses images with a version tag or digest from the allowed registries.

The refusal names the policy and the rule, for example:

```text
Policy enforce-app-namespaces failed: Blocked by enforce-app-namespaces:
every container must run as non-root ...
```

Things to know:

- `kubectl rollout undo` to a revision from before 2026-10-11 is refused,
  because those pod templates ran as root.
- A debug or test pod in one of these namespaces needs the same security
  context. `recovery/restore.sh` creates its health-check and restore-inspect
  pods that way, running as the application's own user.
- To add a namespace, make its policy report clean first, then add it to the
  list in the policy file and merge it; Argo CD applies the change.
- To stop enforcing in an emergency, stop Argo CD's controller first (see
  [Stopping Argo CD in an emergency](platform.md#stopping-argo-cd-in-an-emergency)),
  then `kubectl delete validatingpolicy enforce-app-namespaces`. Without that
  step Argo CD restores the policy, or its `Deny` action, within seconds.

The "Policy (Kyverno)" row on the "Homelab - Security Scanning" dashboard
shows blocked requests, the trend of failed checks by policy and namespace,
and the time Kyverno adds to a request. The failure counts are a trend, not an
exact total; `kubectl get policyreports -A` has the current state.
