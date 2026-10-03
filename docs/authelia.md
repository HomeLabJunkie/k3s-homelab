# Authelia

[Back to the README](../README.md)

Authelia (`authelia.yaml`, namespace `authelia`) is the login portal at
`auth.${BASE_DOMAIN}` in front of the admin UIs: the Traefik dashboard,
Longhorn, Prometheus, Grafana, Portainer and Trilium. Their routes use the
shared `admin-ui-auth` Traefik middleware (`traefik-admin-ui-auth@kubernetescrd`
from other namespaces), which asks Authelia about each request. Anyone not
logged in is redirected to the portal; access needs a password and a second
factor (Duo Push, TOTP app or security key), and only the `admins` group is allowed. Any
other hostname sent through the middleware is denied. Portainer and Trilium
keep their own logins behind Authelia; Grafana signs in through Authelia too.
The middleware accepts at most 64 KiB (`maxResponseBodySize: 65536`) from
Authelia per check; its answers are about 100 bytes plus the redirect URL.
Without a limit Traefik logs a `maxResponseBodySize is not configured` warning
for every protected route at startup.

- **Users:** one admin, `ADMIN_UI_USERNAME` / `ADMIN_UI_PASSWORD` from
  `.secrets.enc`. `deploy.sh` writes an argon2id-hashed users file into the
  `authelia-secrets` Secret. Password reset and change in the portal are
  disabled; change `ADMIN_UI_PASSWORD` and redeploy instead.
- **Second factor:** on first login, register a TOTP app or security key.
  Authelia confirms by emailing a one-time code to `ADMIN_EMAIL`, using the
  same SMTP account as Alertmanager.
- **Duo Push:** Authelia uses a Duo Auth API application (`DUO_API_HOSTNAME`,
  `DUO_INTEGRATION_KEY`, `DUO_SECRET_KEY` in `.secrets.enc`, the same one
  deployrr's Authelia uses). Duo sends the push to the Duo user whose username
  matches `ADMIN_UI_USERNAME`; that user must already have a device enrolled in
  Duo (self-enrollment is off). Pick "Push Notification" on the portal's
  second-factor page; Authelia remembers it as the preferred method.
- **Storage:** registered devices live in SQLite on the 1Gi `authelia-data`
  Longhorn PVC, encrypted with `AUTHELIA_STORAGE_ENCRYPTION_KEY`. A restored
  PVC is only readable with that same key. Sessions are in memory, so an
  Authelia restart logs everyone out; `deploy.sh` restarts it only when its
  configuration or secrets change.
- **Grafana single sign-on:** Authelia is also an OpenID Connect provider with
  one client, `grafana`. Grafana (`auth.generic_oauth` in
  `monitoring-values.yaml`) redirects straight to Authelia and signs in as the
  Authelia user, keyed by email, as a Grafana server admin; only the `admins`
  group is accepted. `deploy.sh` puts the Authelia URLs, `GF_SERVER_ROOT_URL`
  and the client secret in the `grafana-oidc` Secret, and maps the Authelia
  hostname to Traefik on the LAN (`hostAliases`), so Grafana's server-side
  token and userinfo calls never go through Cloudflare. The local `admin`
  login is the break-glass way in: `/login?disableAutoLogin=true` with
  `GRAFANA_ADMIN_PASSWORD`. Signing out of Grafana also signs out of Authelia.
- **Protecting another app:** add its hostname to `access_control` in
  `templates/generated/authelia.yaml.template` and route it with an
  `IngressRoute` that lists the `admin-ui-auth` middleware (namespace
  `traefik`), as in `templates/generated/portainer-ingress.yaml.template`. Do
  not use an `Ingress` with the `router.middlewares` annotation: it works, but
  logs a missing-middleware error each time Traefik starts. Clients that call an app's API directly cannot follow the
  login redirect: keep Vaultwarden out of Authelia.
- **Trilium sync and ETAPI:** the desktop app's sync and ETAPI clients cannot
  follow a login redirect either, so Authelia bypasses just the paths they use
  and Trilium guards each itself: `/api/login/sync` (HMAC of the document
  secret), the `/api/sync/*` routes the client calls (the session that login
  creates), `GET /api/setup/sync-seed` (the Trilium password), and `/etapi`
  (an API token). The web UI and every other path still need Authelia. If a
  desktop app syncing through Cloudflare fails with error 1010, Cloudflare's
  bot check is rejecting it (it blocks non-browser clients); add a WAF skip
  rule for `trilium.${BASE_DOMAIN}` with paths starting `/api/sync`,
  `/api/login/sync`, `/api/setup/sync-seed` and `/etapi`.
- **Cloudflare:** `auth.${BASE_DOMAIN}` needs a public hostname in the tunnel
  pointing at `https://${CLOUDFLARE_ORIGIN_IP}` with No TLS Verify, or logins
  only work on the LAN. The Authelia-protected hostnames are not in a
  Cloudflare Access application and do not enforce Access JWT validation on
  their tunnel routes; either one would put a second login in front of
  Authelia, or return 403. Rancher and `${BASE_DOMAIN}/admin` still use
  Cloudflare Access.
