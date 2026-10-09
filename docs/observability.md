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
- scrape targets for other cluster components (`monitoring-scrape-targets.yaml`)
- homelab baseline alert rules
- custom Grafana dashboards

`monitoring-scrape-targets.yaml` holds PodMonitors for components that expose
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

Certificate alerts (`homelab.certificate.rules` in
`monitoring-longhorn-v2.yaml`) email a warning when a certificate has under 14
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
IngressRoute in `monitoring-ingress.yaml`. Prometheus has no login of its own, so the
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
