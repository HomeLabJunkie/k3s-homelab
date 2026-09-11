#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"
SECRETS_FILE="${SECRETS_FILE:-$ROOT_DIR/.secrets.enc}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

[[ -r "$SECRETS_FILE" ]] || { echo "ERROR: missing $SECRETS_FILE" >&2; exit 1; }
command -v sops >/dev/null || { echo "ERROR: sops is required" >&2; exit 1; }

decrypted="$TMP_DIR/secrets.env"
sops -d "$SECRETS_FILE" >"$decrypted"
chmod 600 "$decrypted"
required=(
  VELERO_REPOSITORY_PASSWORD
  VELERO_GARAGE_ACCESS_KEY
  VELERO_GARAGE_SECRET_KEY
  LONGHORN_CIFS_USERNAME
  LONGHORN_CIFS_PASSWORD
)
for key in "${required[@]}"; do
  grep -qE "^${key}=.+$" "$decrypted" || {
    echo "ERROR: required encrypted secret is missing: $key" >&2
    exit 1
  }
done

grep -q '"sops"[[:space:]]*:' "$SECRETS_FILE" || {
  echo "ERROR: encrypted file has no SOPS metadata" >&2
  exit 1
}

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
NAS="${NAS:-${BACKUP_NAS_IP:-${UNRAID_IP:-}}}"
EXPORT="${EXPORT:-${CLUSTER_BACKUP_EXPORT:-}}"
if [[ -n "$NAS" && -n "$EXPORT" ]]; then
  # shellcheck source=backup/remote-storage.sh
  source "$ROOT_DIR/backup/remote-storage.sh"
  storage_init
  storage_mount
  trap 'storage_unmount; rm -rf -- "$TMP_DIR"' EXIT
  latest="$(storage_sudo readlink -f "$STORAGE_MOUNT/cluster/latest")"
  encrypted_copy="$latest/repo/k3s-secrets.enc"
  storage_sudo test -s "$encrypted_copy" || {
    echo "ERROR: recovery bundle does not contain encrypted SOPS secrets" >&2
    exit 1
  }
  echo "==> Recovery bundle contains encrypted secrets"
fi

echo "==> SOPS decryption succeeded"
echo "==> Required backup and notification secrets are present"
echo "RESULT: ENCRYPTED SECRETS RECOVERY VERIFIED"
