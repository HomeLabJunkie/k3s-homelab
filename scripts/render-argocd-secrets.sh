#!/usr/bin/env bash
# Build the Secrets that Argo CD deploys and write them, sops-encrypted, into
# the private configuration repository.
#
# The values come from .secrets.enc and config/cluster.env, as they did when
# deploy.sh created these Secrets itself. Run this after changing one of
# them, then commit and push the configuration repository; Argo CD applies
# the result. Nothing decrypted is printed or left on disk.
#
# Usage:
#   scripts/render-argocd-secrets.sh           Write the encrypted files.
#   scripts/render-argocd-secrets.sh --check   Compare what would be written
#                                              with the Secrets in the cluster,
#                                              key by key. Writes nothing.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"
SECRETS_FILE="${SECRETS_FILE:-$ROOT_DIR/.secrets.enc}"
CONFIG_REPO="${CONFIG_REPO:-$ROOT_DIR/../k3s-homelab-config}"
# Directory inside the configuration repository to write to, with a trailing
# slash. Empty is production; a test cluster's clone sets "envs/test/", the
# same value as ARGOCD_APPS_CONFIG_PATH in its config/cluster.env.
# It is read after config/cluster.env is loaded, below.

CHECK=false
case "${1:-}" in
  "") ;;
  --check) CHECK=true ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

fail() { echo "ERROR: $*" >&2; exit 1; }

for command in sops kubectl openssl argon2 python3 base64 sha256sum; do
  command -v "$command" >/dev/null 2>&1 || fail "$command command is required"
done
[[ -r "$ENV_FILE" ]] || fail "cluster environment file is missing: $ENV_FILE"
[[ -f "$SECRETS_FILE" ]] || fail "encrypted secrets file is missing: $SECRETS_FILE"
[[ -f "$CONFIG_REPO/.sops.yaml" ]] ||
  fail "configuration repository not found at $CONFIG_REPO (set CONFIG_REPO)"

# Plaintext only ever exists in memory-backed, owner-only files.
umask 077
WORK="$(mktemp -d /dev/shm/argocd-secrets.XXXXXX)"
trap 'find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"' EXIT

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
decrypted_secrets="$(sops --decrypt "$SECRETS_FILE")" || fail "sops could not decrypt $SECRETS_FILE"
# shellcheck disable=SC1090
source <(printf '%s\n' "$decrypted_secrets")
unset decrypted_secrets
set +a

CONFIG_PATH="${CONFIG_PATH:-${ARGOCD_APPS_CONFIG_PATH:-}}"
[[ -z "$CONFIG_PATH" || "$CONFIG_PATH" == */ ]] || fail "CONFIG_PATH must end with a slash: $CONFIG_PATH"

for var in ADMIN_EMAIL CLOUDFLARE_TUNNEL_TOKEN ADMIN_UI_USERNAME ADMIN_UI_PASSWORD \
  AUTHELIA_SESSION_SECRET AUTHELIA_STORAGE_ENCRYPTION_KEY AUTHELIA_JWT_SECRET \
  AUTHELIA_OIDC_HMAC_SECRET AUTHELIA_OIDC_JWKS_KEY_B64 GRAFANA_OIDC_CLIENT_SECRET \
  VAULTWARDEN_ADMIN_TOKEN VAULTWARDEN_YUBICO_SECRET_KEY \
  VAULTWARDEN_SMTP_USERNAME VAULTWARDEN_SMTP_PASSWORD \
  DUO_API_HOSTNAME DUO_INTEGRATION_KEY DUO_SECRET_KEY; do
  [[ -n "${!var:-}" ]] || fail "$var is not set"
done

# --- cert-manager: the Cloudflare API token for DNS-01 ------------------------

[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || fail "CLOUDFLARE_API_TOKEN is not set"
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-file=api-token=<(printf '%s' "$CLOUDFLARE_API_TOKEN") \
  --dry-run=client -o yaml >"$WORK/cloudflare-api-token.yaml"

# --- cloudflared: the tunnel token -------------------------------------------

kubectl create secret generic tunnel-token \
  --namespace cloudflared \
  --from-file=token=<(printf '%s' "$CLOUDFLARE_TUNNEL_TOKEN") \
  --dry-run=client -o yaml >"$WORK/tunnel-token.yaml"

# --- Authelia ------------------------------------------------------------------

# The salts are derived from the credentials, so an unchanged password gives
# an unchanged Secret and this script changes nothing when run again.
admin_salt="$(
  printf '%s:%s' "$ADMIN_UI_USERNAME" "$ADMIN_UI_PASSWORD" |
    openssl dgst -sha256 -hmac "$AUTHELIA_SESSION_SECRET" -r | cut -c1-32
)"
admin_hash="$(
  printf '%s' "$ADMIN_UI_PASSWORD" |
    argon2 "$admin_salt" -id -t 3 -k 65536 -p 4 -l 32 -e
)"
# shellcheck disable=SC2016 # literal hash prefix
[[ "$admin_hash" == '$argon2id$'* ]] || fail "could not hash ADMIN_UI_PASSWORD with argon2"

# JSON is valid YAML and quotes the username and hash safely.
users_database="$(
  AUTHELIA_ADMIN_HASH="$admin_hash" python3 -c '
import json, os
user = os.environ["ADMIN_UI_USERNAME"]
print(json.dumps({"users": {user: {
    "displayname": user,
    "password": os.environ["AUTHELIA_ADMIN_HASH"],
    "email": os.environ["ADMIN_EMAIL"],
    "groups": ["admins"],
}}}, indent=2))'
)"

# Grafana's OIDC client secret is stored as a digest, like the admin password.
grafana_client_digest="$(
  printf '%s' "$GRAFANA_OIDC_CLIENT_SECRET" |
    argon2 "$(printf 'grafana:%s' "$GRAFANA_OIDC_CLIENT_SECRET" |
      openssl dgst -sha256 -hmac "$AUTHELIA_SESSION_SECRET" -r | cut -c1-32)" \
      -id -t 3 -k 65536 -p 4 -l 32 -e
)"
# shellcheck disable=SC2016 # literal hash prefix
[[ "$grafana_client_digest" == '$argon2id$'* ]] ||
  fail "could not hash GRAFANA_OIDC_CLIENT_SECRET with argon2"

# Same SMTP account and defaults as scripts/render-alertmanager-config.sh.
smtp_port="${SMTP_PORT:-587}"
if [[ "$smtp_port" == 465 ]]; then smtp_scheme=submissions; else smtp_scheme=submission; fi

kubectl create secret generic authelia-secrets \
  --namespace authelia \
  --from-file=users_database.yml=<(printf '%s\n' "$users_database") \
  --from-file=session-secret=<(printf '%s' "$AUTHELIA_SESSION_SECRET") \
  --from-file=storage-encryption-key=<(printf '%s' "$AUTHELIA_STORAGE_ENCRYPTION_KEY") \
  --from-file=jwt-secret=<(printf '%s' "$AUTHELIA_JWT_SECRET") \
  --from-file=smtp-address=<(printf '%s://%s:%s' "$smtp_scheme" "${SMTP_HOST:-smtp.gmail.com}" "$smtp_port") \
  --from-file=smtp-username=<(printf '%s' "${SMTP_USER:-$VAULTWARDEN_SMTP_USERNAME}") \
  --from-file=smtp-password=<(printf '%s' "${SMTP_PASSWORD:-$VAULTWARDEN_SMTP_PASSWORD}") \
  --from-file=oidc-hmac-secret=<(printf '%s' "$AUTHELIA_OIDC_HMAC_SECRET") \
  --from-file=oidc-jwks-key.pem=<(printf '%s' "$AUTHELIA_OIDC_JWKS_KEY_B64" | base64 -d) \
  --from-file=oidc-grafana-client-secret=<(printf '%s' "$grafana_client_digest") \
  --from-file=duo-hostname=<(printf '%s' "$DUO_API_HOSTNAME") \
  --from-file=duo-integration-key=<(printf '%s' "$DUO_INTEGRATION_KEY") \
  --from-file=duo-secret-key=<(printf '%s' "$DUO_SECRET_KEY") \
  --dry-run=client -o yaml >"$WORK/authelia-secrets.yaml"
unset admin_salt admin_hash users_database grafana_client_digest

# --- Vaultwarden ---------------------------------------------------------------

# Only an Argon2id hash of the admin token is stored (Vaultwarden's
# "bitwarden" preset); the /admin login still uses the token itself. The salt
# is derived from the token, so the hash is the same on every run.
vaultwarden_admin_hash="$(
  printf '%s' "$VAULTWARDEN_ADMIN_TOKEN" |
    argon2 "$(printf 'vaultwarden-admin' |
      openssl dgst -sha256 -hmac "$VAULTWARDEN_ADMIN_TOKEN" -r | cut -c1-32)" \
      -id -t 3 -k 65540 -p 4 -e
)"
# shellcheck disable=SC2016 # literal hash prefix
[[ "$vaultwarden_admin_hash" == '$argon2id$'* ]] ||
  fail "could not hash VAULTWARDEN_ADMIN_TOKEN with argon2"

kubectl create secret generic vaultwarden-admin \
  --namespace vaultwarden \
  --from-file=admin-token=<(printf '%s' "$vaultwarden_admin_hash") \
  --dry-run=client -o yaml >"$WORK/vaultwarden-admin.yaml"
unset vaultwarden_admin_hash

kubectl create secret generic vaultwarden-integrations \
  --namespace vaultwarden \
  --from-file=SMTP_USERNAME=<(printf '%s' "$VAULTWARDEN_SMTP_USERNAME") \
  --from-file=SMTP_PASSWORD=<(printf '%s' "$VAULTWARDEN_SMTP_PASSWORD") \
  --from-file=YUBICO_SECRET_KEY=<(printf '%s' "$VAULTWARDEN_YUBICO_SECRET_KEY") \
  --dry-run=client -o yaml >"$WORK/vaultwarden-integrations.yaml"

# --- monitoring: Grafana and Alertmanager --------------------------------------

for var in BASE_DOMAIN GRAFANA_ADMIN_PASSWORD CLOUDFLARE_ANALYTICS_TOKEN; do
  [[ -n "${!var:-}" ]] || fail "$var is not set"
done
grafana_hostname="${GRAFANA_HOSTNAME:-grafana.${BASE_DOMAIN}}"
authelia_hostname="${AUTHELIA_HOSTNAME:-auth.${BASE_DOMAIN}}"

kubectl create secret generic grafana-admin \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-file=admin-password=<(printf '%s' "$GRAFANA_ADMIN_PASSWORD") \
  --dry-run=client -o yaml >"$WORK/grafana-admin.yaml"

# Read-only Cloudflare Web Analytics token for Grafana's Infinity data source.
kubectl create secret generic grafana-cloudflare \
  --namespace monitoring \
  --from-file=token=<(printf '%s' "$CLOUDFLARE_ANALYTICS_TOKEN") \
  --dry-run=client -o yaml >"$WORK/grafana-cloudflare.yaml"

# Single sign-on through Authelia (auth.generic_oauth in
# apps/monitoring/values.yaml). Grafana reads these as environment variables.
kubectl create secret generic grafana-oidc \
  --namespace monitoring \
  --from-literal=GF_SERVER_ROOT_URL="https://${grafana_hostname}/" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_AUTH_URL="https://${authelia_hostname}/api/oidc/authorization" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_TOKEN_URL="https://${authelia_hostname}/api/oidc/token" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_API_URL="https://${authelia_hostname}/api/oidc/userinfo" \
  --from-literal=GF_AUTH_SIGNOUT_REDIRECT_URL="https://${authelia_hostname}/logout?rd=https%3A%2F%2F${grafana_hostname}%2F" \
  --from-file=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<(printf '%s' "$GRAFANA_OIDC_CLIENT_SECRET") \
  --dry-run=client -o yaml >"$WORK/grafana-oidc.yaml"

# Alertmanager's whole configuration, which carries the SMTP login.
"$ROOT_DIR/scripts/render-alertmanager-config.sh" >"$WORK/alertmanager.yaml" ||
  fail "could not render the Alertmanager configuration"
kubectl create secret generic alertmanager-smtp \
  --namespace monitoring \
  --from-file=alertmanager.yaml="$WORK/alertmanager.yaml" \
  --dry-run=client -o yaml >"$WORK/alertmanager-smtp.yaml"

# --- Rancher: the first-login password -----------------------------------------

[[ -n "${RANCHER_BOOTSTRAP_PASSWORD:-}" ]] || fail "RANCHER_BOOTSTRAP_PASSWORD is not set"
kubectl create secret generic bootstrap-secret \
  --namespace cattle-system \
  --from-file=bootstrapPassword=<(printf '%s' "$RANCHER_BOOTSTRAP_PASSWORD") \
  --dry-run=client -o yaml >"$WORK/bootstrap-secret.yaml"

# --- Velero: the S3 login and the backup repository password --------------------

# A test cluster has no backup store and leaves the velero application out,
# so its secrets file has none of these values.
velero_secrets=false
if [[ -n "${VELERO_GARAGE_ACCESS_KEY:-}${VELERO_GARAGE_SECRET_KEY:-}${VELERO_REPOSITORY_PASSWORD:-}" ]]; then
  for var in VELERO_GARAGE_ACCESS_KEY VELERO_GARAGE_SECRET_KEY VELERO_REPOSITORY_PASSWORD; do
    [[ -n "${!var:-}" ]] || fail "$var is not set"
  done
  velero_secrets=true
  kubectl create secret generic velero-garage-credentials \
    --namespace velero \
    --from-file=cloud=<(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s' \
      "$VELERO_GARAGE_ACCESS_KEY" "$VELERO_GARAGE_SECRET_KEY") \
    --dry-run=client -o yaml >"$WORK/velero-garage-credentials.yaml"
  kubectl create secret generic velero-repo-credentials \
    --namespace velero \
    --from-file=repository-password=<(printf '%s' "$VELERO_REPOSITORY_PASSWORD") \
    --dry-run=client -o yaml >"$WORK/velero-repo-credentials.yaml"
else
  echo "Velero values are not set: skipping the Velero Secrets."
fi

# --- compare with the cluster, or write ---------------------------------------

# Prints "<key> <sha256>" for each data key of a Secret manifest on stdin.
key_digests() {
  python3 -c '
import hashlib, sys, yaml
data = (yaml.safe_load(sys.stdin) or {}).get("data") or {}
for key in sorted(data):
    print(key, hashlib.sha256(data[key].encode()).hexdigest())'
}

check_secret() {
  local namespace="$1" name="$2" rendered="$3" result=0
  echo "==> $namespace/$name"
  if ! kubectl -n "$namespace" get secret "$name" -o yaml >"$WORK/live.yaml" 2>/dev/null; then
    echo "  not in the cluster"
    return 1
  fi
  join -a1 -a2 -e missing -o 0,1.2,2.2 \
    <(key_digests <"$rendered") <(key_digests <"$WORK/live.yaml") |
    while read -r key ours theirs; do
      if [[ "$ours" == "$theirs" ]]; then echo "  same       $key"
      else echo "  DIFFERENT  $key"; fi
    done >"$WORK/report"
  cat "$WORK/report"
  grep -q DIFFERENT "$WORK/report" && result=1
  return "$result"
}

# True when the sops file $1 decrypts to the same manifest as the file $2.
# sops rewrites the YAML, so the two are compared as data, not as text.
decrypts_to() {
  sops --decrypt --input-type yaml --output-type yaml "$1" 2>/dev/null |
    python3 -c '
import sys, yaml
sys.exit(0 if yaml.safe_load(sys.stdin) == yaml.safe_load(open(sys.argv[1])) else 1)' "$2"
}

# Writes the encrypted file unless it already decrypts to the same manifest,
# because sops produces different ciphertext every time.
write_secret() {
  local rendered="$1" target="$2" staged
  if [[ -f "$target" ]] && decrypts_to "$target" "$rendered"; then
    echo "unchanged: ${target#"$CONFIG_REPO"/}"
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  # sops picks its recipients from the configuration repository's .sops.yaml,
  # which it finds from the file's own directory.
  staged="$(dirname "$target")/.$(basename "$target").new"
  cp "$rendered" "$staged"
  if ! (cd "$CONFIG_REPO" && sops --encrypt --in-place --input-type yaml --output-type yaml \
    --filename-override "$target" "$staged"); then
    shred -u "$staged"
    fail "sops could not encrypt $target"
  fi
  decrypts_to "$staged" "$rendered" || {
    rm -f "$staged"
    fail "$target did not decrypt back to what was encrypted"
  }
  mv -f "$staged" "$target"
  chmod 644 "$target"
  echo "written:   ${target#"$CONFIG_REPO"/}"
}

if [[ "$CHECK" == true ]]; then
  status=0
  check_secret cert-manager cloudflare-api-token "$WORK/cloudflare-api-token.yaml" || status=1
  check_secret cloudflared tunnel-token "$WORK/tunnel-token.yaml" || status=1
  check_secret authelia authelia-secrets "$WORK/authelia-secrets.yaml" || status=1
  check_secret vaultwarden vaultwarden-admin "$WORK/vaultwarden-admin.yaml" || status=1
  check_secret vaultwarden vaultwarden-integrations "$WORK/vaultwarden-integrations.yaml" || status=1
  for monitoring_secret in grafana-admin grafana-cloudflare grafana-oidc alertmanager-smtp; do
    check_secret monitoring "$monitoring_secret" "$WORK/$monitoring_secret.yaml" || status=1
  done
  check_secret cattle-system bootstrap-secret "$WORK/bootstrap-secret.yaml" || status=1
  if [[ "$velero_secrets" == true ]]; then
    for velero_secret in velero-garage-credentials velero-repo-credentials; do
      check_secret velero "$velero_secret" "$WORK/$velero_secret.yaml" || status=1
    done
  fi
  exit "$status"
fi

write_secret "$WORK/cloudflare-api-token.yaml" \
  "$CONFIG_REPO/${CONFIG_PATH}cert-manager/cloudflare-api-token.enc.yaml"
write_secret "$WORK/tunnel-token.yaml" "$CONFIG_REPO/${CONFIG_PATH}cloudflared/tunnel-token.enc.yaml"
write_secret "$WORK/authelia-secrets.yaml" "$CONFIG_REPO/${CONFIG_PATH}authelia/authelia-secrets.enc.yaml"
write_secret "$WORK/vaultwarden-admin.yaml" "$CONFIG_REPO/${CONFIG_PATH}vaultwarden/vaultwarden-admin.enc.yaml"
write_secret "$WORK/vaultwarden-integrations.yaml" \
  "$CONFIG_REPO/${CONFIG_PATH}vaultwarden/vaultwarden-integrations.enc.yaml"
for monitoring_secret in grafana-admin grafana-cloudflare grafana-oidc alertmanager-smtp; do
  write_secret "$WORK/$monitoring_secret.yaml" \
    "$CONFIG_REPO/${CONFIG_PATH}monitoring/$monitoring_secret.enc.yaml"
done
write_secret "$WORK/bootstrap-secret.yaml" \
  "$CONFIG_REPO/${CONFIG_PATH}rancher/bootstrap-secret.enc.yaml"
if [[ "$velero_secrets" == true ]]; then
  for velero_secret in velero-garage-credentials velero-repo-credentials; do
    write_secret "$WORK/$velero_secret.yaml" \
      "$CONFIG_REPO/${CONFIG_PATH}velero/$velero_secret.enc.yaml"
  done
fi
echo "Commit and push $CONFIG_REPO for Argo CD to apply any change."
