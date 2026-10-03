# Applications and management services

[Back to the README](../README.md)

## Rancher

Rancher is installed by Helm in `cattle-system`.

The deployment includes:

- TLS certificate from cert-manager
- Traefik ingress
- two Rancher replicas
- bootstrap/admin credential configuration
- server URL configuration

## Portainer

Portainer CE provides a second management interface.

Its data is stored on a Longhorn PVC and is included in the protected DR application set.

## Trilium

Trilium is deployed with persistent Longhorn storage.

Protected PVC:

```text
trilium/trilium-data
```

## Vaultwarden

Vaultwarden is deployed with persistent Longhorn storage.

Protected PVC:

```text
vaultwarden/vaultwarden-data
```

The admin token and initial invitation address come from local encrypted secrets.

General sign-up/invitation behavior is controlled by the deployment manifest rather than documented with real credentials here.

Image upgrades are recorded in the [changelog](CHANGELOG.md).

## Website (jeffriffle.com)

`website.yaml` runs the `jeffriffle` Deployment in the `website` namespace. It
serves the site from the private `HomeLabJunkie/jeffriffle.com` repo at
`${BASE_DOMAIN}`, and `www.${BASE_DOMAIN}` redirects there.

In that repo, the text lives in content files that can be edited online at
`/admin/` (Sveltia CMS). Each save commits to `main`, and a GitHub Action builds
the site onto the `deploy` branch. Each pod runs
[git-sync](https://github.com/kubernetes/git-sync) as a sidecar. It checks
`deploy` every 60 seconds with a read-only deploy key, so edits go live without
a rollout. nginx (unprivileged, read-only root filesystem) serves the checkout.

`deploy.sh` creates the `jeffriffle-git` Secret from `WEBSITE_DEPLOY_KEY_B64`
(the base64-encoded private deploy key). Cloudflare Access, configured in the
Cloudflare dashboard rather than in this repo, puts a login in front of
`/admin/`.

The nginx config lives in `website-nginx.yaml`, outside `templates/` so that
`envsubst` doesn't strip nginx's `$variables`. `deploy.sh` restarts the site when
it changes. nginx writes one JSON line per request, including Cloudflare's
visitor IP and country, to Loki.

The **jeffriffle.com - Website** Grafana dashboard (`dashboards/jeffriffle-website.json`)
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
