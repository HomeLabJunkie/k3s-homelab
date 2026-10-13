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
| `website/values.yaml` (`domain`), `website/jeffriffle-git.enc.yaml` | The `website` application (`charts/website`): its domain, and git-sync's deploy key, encrypted |
| `fb-search/` (manifests, `requirements.txt`, `src/`) | The `fb-search` application, built with Kustomize |

| `cert-manager/values.yaml` (`adminEmail`, optional `acmeServer`) | The `cert-manager-config` application (`charts/cert-manager-config`) |
| `cert-manager/cloudflare-api-token.enc.yaml` | The Cloudflare API token cert-manager proves domain ownership with, encrypted |
| `monitoring/values.yaml` | Added to `apps/monitoring/values.yaml` for the `monitoring` application: where Grafana finds Authelia |
| `monitoring/*.enc.yaml` | The four monitoring Secrets, encrypted |
| `velero/values.yaml`, `velero/*.enc.yaml` | The `velero` application: the backup store's address, and its two Secrets, encrypted. Production only |
| `argocd/values.yaml` (`global.domain`) | The `argocd` application: Argo CD's own address, where it sends the browser after logging out |
| `rancher/values.yaml` (`hostname`), `rancher/bootstrap-secret.enc.yaml` | The `rancher` application: its hostname, and the first-login password, encrypted |
| `routes/values.yaml` (`domain`) | The `routes` application (`charts/routes`) |
| `monitoring-extras/values.yaml` (`cloudflareAccountId`) | The `monitoring-extras` application (`charts/monitoring-extras`) |
| `cloudflared/values.yaml` (`originIP`) | The `cloudflared` application (`charts/cloudflared`) |
| `cloudflared/tunnel-token.enc.yaml` | The tunnel token, encrypted |
| `authelia/values.yaml` (`domain`, `adminEmail`) | The `authelia` application (`charts/authelia`) |
| `longhorn/values.yaml`, `longhorn/backup-credentials.enc.yaml` | The `longhorn-config` application (`charts/longhorn-config`): the address of the share Longhorn backs volumes up to, and its login, encrypted |
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

Those `values.yaml` files are generated, not edited.
`config/cluster.env` is the one place a setting is changed:

1. Change the value in `config/cluster.env`.
2. Run `scripts/render-argocd-values.sh`. It rewrites the `values.yaml`
   files in the private repository whose content changed.
3. Commit and push the private repository. Argo CD applies the change
   within about three minutes.

`scripts/render-argocd-values.sh --check` compares what it would write with
the files there now and prints `same` or `DIFFERENT` for each. `deploy.sh`
runs it at the end and warns on a difference.

| Setting in `config/cluster.env` | Goes to |
| --- | --- |
| `BASE_DOMAIN` | `domain` for authelia, routes, trilium, vaultwarden and website; Rancher's hostname; the Authelia hostname Grafana is pointed at |
| `ADMIN_EMAIL` | `adminEmail` for authelia, cert-manager and vaultwarden |
| `CLOUDFLARE_ORIGIN_IP` | cloudflared's `originIP`; the address Grafana uses for Authelia |
| `CLOUDFLARE_ACCOUNT_ID` | monitoring-extras |
| `BACKUP_NAS_IP`, `LONGHORN_BACKUP_SHARE`, `LONGHORN_BACKUP_CREDENTIAL_SECRET` | Longhorn's backup target (`longhorn/values.yaml`) |
| `UNRAID_IP` | Velero's backup store address |
| `ACME_SERVER` (optional) | A different certificate authority address; the test cluster sets Let's Encrypt's staging service |

A rebuild needs both repositories; the private one is on GitHub and cloned
beside this one on each laptop.

## Changing a secret Argo CD deploys

The Cloudflare API token for certificates, the tunnel token, the four
monitoring Secrets (Grafana's admin login, Cloudflare analytics token and
single sign-on settings; Alertmanager's configuration), the login for
Longhorn's backup share, the website's deploy key, Authelia's Secret (admin login, session and storage keys,
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
   For the monitoring Secrets, restart `deployment/monitoring-grafana` in
   `monitoring`; Alertmanager reloads its configuration by itself. For the
   website's deploy key, restart `deployment/jeffriffle` in `website`. Longhorn
   reads the backup share's login again at its next check of the target,
   within five minutes.

`scripts/render-argocd-secrets.sh --check` compares what it would write with
the Secrets in the cluster, key by key, and prints only `same` or
`DIFFERENT`. `deploy.sh` runs it at the end and warns on a difference.

### Replacing an age key

`scripts/rotate-sops-age-key.sh` replaces either of the two keys and
re-encrypts everything that was encrypted to the old one, in this repository
and in the private one. Both forms commit and push the private repository.

**The laptop key.** Generate a key with `age-keygen`, add it to the sops key
file beside the old one, and put its public key in `.sops.yaml` here and in
the private repository in place of the old one. Then run the script with no
arguments. It refuses to start if the two `.sops.yaml` files disagree,
re-encrypts the private repository's Secrets and `.secrets.enc`, publishes a
recovery bundle, runs the secrets recovery test, and sends a reminder to
update the key's record in Bitwarden. Argo CD is not affected: its own key
has not changed.

**Argo CD's key.** Run `scripts/rotate-sops-age-key.sh --argocd` with
`kubectl` pointed at the cluster. It generates the new key itself and:

1. checks that the cluster holds the key in `.secrets.enc` and that every
   application is Synced and Healthy;
2. gives Argo CD both keys, so it can decrypt whichever commit it is looking
   at;
3. puts the new public key in the private repository's `.sops.yaml`,
   re-encrypts the Secrets, checks each decrypts with the new key alone, and
   pushes;
4. stores the new key in `.secrets.enc` as `ARGOCD_SOPS_AGE_KEY`;
5. takes the old key away from Argo CD, has it render every application
   again, and waits until all are Synced and Healthy on the pushed commit;
6. publishes a recovery bundle, because an older one restores a key that
   opens nothing any more.

A failure before the push in step 3 puts everything back as it was. On a
test cluster, set `SKIP_RECOVERY_BACKUP=true`; the script also updates the
copy of that cluster's key in `envs/test/argocd-sops-age-key.enc.yaml`.
Afterwards copy `.secrets.enc` to the other laptop (`k3s-sync push`) and pull
the private repository there.

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
