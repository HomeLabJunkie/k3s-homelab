# Configuration and secrets

[Back to the README](../README.md)

## Environment

Copy the public environment template:

```bash
cp config/cluster.env.example config/cluster.env
```

Populate local values for:

- base domain
- administrative email
- kube-vip address
- node addresses
- MetalLB range
- Cloudflare origin address
- NAS address
- NFS cluster-backup export and Longhorn SMB share

## Secrets

Sensitive values should be kept in the encrypted/local secrets workflow and not committed in plaintext.

`deploy.sh` supports:

```text
.secrets.enc   # preferred, SOPS-encrypted
.secrets       # local fallback
```

Expected sensitive values include:

- Rancher bootstrap/admin credentials
- Cloudflare API/tunnel credentials
- Vaultwarden admin token
- initial Vaultwarden account address
- Vaultwarden SMTP username and password
- Vaultwarden Yubico secret key, when Yubico OTP is enabled
- Grafana admin password
- dedicated Longhorn CIFS username and password
- `ADMIN_UI_USERNAME` / `ADMIN_UI_PASSWORD` (12+ characters): the Authelia
  admin login for the Traefik dashboard, Longhorn and Prometheus, which have no
  login of their own
- `AUTHELIA_SESSION_SECRET`, `AUTHELIA_STORAGE_ENCRYPTION_KEY`,
  `AUTHELIA_JWT_SECRET` (32+ characters each, `openssl rand -hex 32`). Never
  rotate the storage key casually: it decrypts the registered 2FA devices
- `AUTHELIA_OIDC_HMAC_SECRET` and `GRAFANA_OIDC_CLIENT_SECRET`
  (`openssl rand -hex 32`), and `AUTHELIA_OIDC_JWKS_KEY_B64`, Authelia's OIDC
  signing key (`openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 | base64 -w0`)
- `DUO_API_HOSTNAME`, `DUO_INTEGRATION_KEY`, `DUO_SECRET_KEY`: Duo Auth API
  application details for Authelia's Duo Push
- Values are read with bash `source`: single-quote any value containing shell
  characters such as `&`, `;`, `|`, `$`, spaces or `#` after a space
- `WEBSITE_DEPLOY_KEY_B64`: the jeffriffle.com repo's read-only deploy key
  (private key, base64-encoded on one line), used by git-sync

The tracked Vaultwarden values template references Kubernetes Secrets and must
not contain credential values directly. `deploy.sh` creates or updates
`vaultwarden-admin` and `vaultwarden-integrations` from the corresponding
values in `.secrets.enc`.

## K3s cluster token

The repository has been hardened so the K3s cluster token is no longer stored
as plaintext in tracked Ansible variables.

Current Ansible configuration reads:

```yaml
k3s_token: "{{ lookup('env', 'K3S_TOKEN') }}"
```

`K3S_TOKEN` is provided through the local encrypted secrets workflow.

Continue to treat `.secrets.enc` as the authoritative encrypted local secret
store and never commit decrypted secret material.
