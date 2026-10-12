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
- `ARGOCD_CONFIG_REPO_KEY_B64`: the read-only deploy key Argo CD uses to read
  the private configuration repository (private key, base64-encoded on one
  line). See [The private configuration repository](#the-private-configuration-repository)
- `ARGOCD_SOPS_AGE_KEY`: the age private key (`AGE-SECRET-KEY-...`) Argo CD
  uses to decrypt Secrets in the private configuration repository. It is a
  separate key from the laptop's and decrypts nothing else

The Vaultwarden chart references Kubernetes Secrets and must not contain
credential values directly. `scripts/render-argocd-secrets.sh` builds
`vaultwarden-admin` and `vaultwarden-integrations` from the corresponding
values in `.secrets.enc`, and Argo CD deploys them.

## The private configuration repository

Applications that Argo CD deploys cannot read `config/cluster.env`, which
exists only on a laptop. Their environment-specific settings live in a second,
private GitHub repository, `HomeLabJunkie/k3s-homelab-config`. Argo CD reads
it next to this one: an Application names a chart here and a values file
there.

| File in the private repository | Used by |
| --- | --- |
| `website/values.yaml` (`domain`) | The `website` application (`charts/website`) |
| `fb-search/` (manifests, `requirements.txt`, `src/`) | The `fb-search` application, built with Kustomize |

| `cert-manager/values.yaml` (`adminEmail`, optional `acmeServer`) | The `cert-manager-config` application (`charts/cert-manager-config`) |
| `cert-manager/cloudflare-api-token.enc.yaml` | The Cloudflare API token cert-manager proves domain ownership with, encrypted |
| `cloudflared/values.yaml` (`originIP`) | The `cloudflared` application (`charts/cloudflared`) |
| `cloudflared/tunnel-token.enc.yaml` | The tunnel token, encrypted |
| `authelia/values.yaml` (`domain`, `adminEmail`) | The `authelia` application (`charts/authelia`) |
| `authelia/authelia-secrets.enc.yaml` | Authelia's Secret, encrypted |
| `trilium/values.yaml` (`domain`) | The `trilium` application (`charts/trilium`) |
| `vaultwarden/values.yaml` (`domain`, `adminEmail`) | The `vaultwarden` application (`charts/vaultwarden`) |
| `vaultwarden/vaultwarden-admin.enc.yaml`, `vaultwarden-integrations.enc.yaml` | Vaultwarden's Secrets, encrypted |

fb-search is there whole because its source is deliberately not published.
To change it, edit the files in the private repository and push to `main`.
Editing `src/` or `requirements.txt` renames a generated ConfigMap, which
rolls the pod. Argo CD never deletes, so the ConfigMaps of earlier versions
stay in the `website` namespace until removed by hand.

Argo CD reads it over SSH with a read-only deploy key. `deploy.sh` creates the
`repo-k3s-homelab-config` Secret in the `argocd` namespace from
`ARGOCD_CONFIG_REPO_KEY_B64`. To replace the key:

```bash
ssh-keygen -t ed25519 -N '' -f /dev/shm/argocd-config-key
gh repo deploy-key add /dev/shm/argocd-config-key.pub \
  --repo HomeLabJunkie/k3s-homelab-config --title "Argo CD (read-only)"
```

Put `base64 -w0 < /dev/shm/argocd-config-key` in `.secrets.enc` as
`ARGOCD_CONFIG_REPO_KEY_B64`, run `deploy.sh`, then delete the key files and
the old deploy key on GitHub.

The domain, admin email and Traefik address are therefore set in two places:
`config/cluster.env`, for everything `deploy.sh` still deploys, and the
`values.yaml` files in the private repository. Keep them the same. A rebuild needs both
repositories; the private one is on GitHub and cloned beside this one on each
laptop.

## Changing a secret Argo CD deploys

The Cloudflare API token for certificates, the tunnel token, Authelia's Secret (admin login, session and storage keys,
SMTP login, Duo and OIDC credentials) and Vaultwarden's two Secrets (admin
token; SMTP login and Yubico key) reach the cluster through Argo CD. `.secrets.enc` is still where their values are set:

1. Change the value in `.secrets.enc`.
2. Run `scripts/render-argocd-secrets.sh`. It rebuilds the Secrets, including
   the hashed forms Authelia needs, and rewrites only the encrypted files
   whose content changed.
3. Commit and push the private configuration repository. Argo CD applies the
   Secret within about three minutes.
4. Restart what reads it, for example
   `kubectl -n authelia rollout restart deployment/authelia`. The same works
   for `cloudflared` and `vaultwarden`, each in the namespace of its name.

`scripts/render-argocd-secrets.sh --check` compares what it would write with
the Secrets in the cluster, key by key, and prints only `same` or
`DIFFERENT`. `deploy.sh` runs it at the end and warns on a difference.

If the laptop's age key is rotated (`scripts/rotate-sops-age-key.sh`), put
the new public key in the private repository's `.sops.yaml` and run
`sops updatekeys` on each `.enc.yaml` file there. To replace Argo CD's own
key, generate one with `age-keygen`, set `ARGOCD_SOPS_AGE_KEY`, put its
public key in that `.sops.yaml`, run `sops updatekeys` on the same files,
and run `deploy.sh`.

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
