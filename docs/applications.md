# Applications and management services

[Back to the README](../README.md)

## Rancher

Rancher runs in `cattle-system`, deployed by Argo CD (the `rancher` application; see [Argo CD](platform.md#argo-cd)). `deploy.sh` sets the admin password and server URL through its API after the first install.

The deployment includes:

- TLS certificate from cert-manager
- Traefik ingress
- two Rancher replicas
- bootstrap/admin credential configuration
- server URL configuration

## Trilium

Trilium is deployed by Argo CD from the `charts/trilium` chart, with
persistent Longhorn storage. Self-heal is off for it; see
[Argo CD and restores](platform.md#argo-cd-and-restores).

Protected PVC:

```text
trilium/trilium-data
```

The pod runs as the image's `node` user (1000) with a read-only root
filesystem, no Linux capabilities and the default seccomp profile. The image's
own start script needs root to `chown` the data before it switches user, so
the Deployment starts the server directly (`node ./main.mjs`) instead. The
data volume must therefore be owned by 1000:1000; `fsGroup: 1000` keeps it
group-writable.

## Vaultwarden

Vaultwarden is deployed by Argo CD from the `charts/vaultwarden` chart, with
persistent Longhorn storage. Self-heal is off for it; see
[Argo CD and restores](platform.md#argo-cd-and-restores).

Protected PVC:

```text
vaultwarden/vaultwarden-data
```

The pod runs as user 1000 with a read-only root filesystem, no Linux
capabilities and the default seccomp profile. Vaultwarden listens on 8080
inside the pod (`ROCKET_PORT`); the Service still exposes port 80. The files
on the data volume were created by root, and `fsGroup: 1000` gives the group
write access to them.

The admin token, SMTP login and Yubico key reach the cluster as two Secrets
that Argo CD decrypts from the private configuration repository; to change
one, see [Changing a secret Argo CD deploys](configuration.md#changing-a-secret-argo-cd-deploys).
`deploy.sh` still sends the initial invitation, to the address in
`.secrets.enc`.

General sign-up/invitation behavior is controlled by the deployment manifest rather than documented with real credentials here.

Image upgrades are recorded in the [changelog](CHANGELOG.md).

## Website (jeffriffle.com)

The `charts/website` Helm chart runs the `jeffriffle` Deployment in the
`website` namespace. Argo CD deploys it (the `website` application, see
[Argo CD](platform.md#argo-cd)) and takes the domain from
`website/values.yaml` in the private configuration repository. The site is
served from the private `HomeLabJunkie/jeffriffle.com` repo at that domain,
and `www.` redirects there. The chart also holds the route for `/fb-search`,
because it is a path on the same host.

In that repo, the text lives in content files that can be edited online at
`/admin/` (Sveltia CMS). Each save commits to `main`, and a GitHub Action builds
the site onto the `deploy` branch. Each pod runs
[git-sync](https://github.com/kubernetes/git-sync) as a sidecar. It checks
`deploy` every 60 seconds with a read-only deploy key, so edits go live without
a rollout. nginx (unprivileged, read-only root filesystem) serves the checkout. The
pod sets `runAsNonRoot`, so no container in it can start as root. nginx waits
10 seconds before it stops (`preStop`), which gives Traefik time to stop
sending to the pod, so a rollout does not fail requests.

The `jeffriffle-git` Secret (the private deploy key, `WEBSITE_DEPLOY_KEY_B64`
in `.secrets.enc`) is not in the chart: Argo CD deploys it from the private
configuration repository, where `scripts/render-argocd-secrets.sh` writes it
encrypted. After changing the key, run
`kubectl -n website rollout restart deployment/jeffriffle`. Cloudflare Access, configured in the
Cloudflare dashboard rather than in this repo, puts a login in front of
`/admin/`.

The nginx config lives in `charts/website/templates/configmap.yaml`. The
Deployment carries a checksum of it, so merging a change to the config rolls
the pods. nginx writes one JSON line per request, including Cloudflare's
visitor IP and country, to Loki.

The **jeffriffle.com - Website** Grafana dashboard (`charts/monitoring-extras/dashboards/jeffriffle-website.json`)
combines three sources:

- Cloudflare Web Analytics, measured in visitors' browsers: page views, visits,
  countries, referrers, browsers, devices, and Core Web Vitals. Grafana queries
  Cloudflare's GraphQL API through the Infinity plugin, using a read-only
  "Account Analytics" token (`CLOUDFLARE_ANALYTICS_TOKEN`, stored in the
  `grafana-cloudflare` Secret). `deploy.sh` fills in `CLOUDFLARE_ACCOUNT_ID` from
  `config/cluster.env` when it applies the dashboard, so the ID stays out of git.
- The nginx access logs in Loki: page views, unique visitors, countries,
  referrers and top pages, with bots excluded.
- Traefik's metrics: request rate, errors, and response time. Bot probes and
  user agents come from the logs.
