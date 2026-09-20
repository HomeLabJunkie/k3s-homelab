#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a
# shellcheck disable=SC1091
source "${ENV_FILE:-$ROOT_DIR/config/cluster.env}"
set +a
: "${BACKUP_NAS_IP:?BACKUP_NAS_IP is not set}"
: "${LONGHORN_BACKUP_SHARE:?LONGHORN_BACKUP_SHARE is not set}"
TARGET_URL="cifs://${BACKUP_NAS_IP}/${LONGHORN_BACKUP_SHARE}?cifsOptions=vers%3D3.0"
SECRET="${LONGHORN_BACKUP_CREDENTIAL_SECRET:-longhorn-backup-cifs}"
username=''; password=''
while IFS='=' read -r key value; do
  case "$key" in
    LONGHORN_CIFS_USERNAME) username="$value" ;;
    LONGHORN_CIFS_PASSWORD) password="$value" ;;
  esac
done
[[ -n "$username" && -n "$password" ]] || { echo 'ERROR: missing Longhorn CIFS credentials' >&2; exit 1; }
kubectl -n longhorn-system create secret generic "$SECRET" \
  --from-literal=CIFS_USERNAME="$username" \
  --from-literal=CIFS_PASSWORD="$password" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n longhorn-system patch backuptarget default --type merge \
  -p "{\"spec\":{\"backupTargetURL\":\"$TARGET_URL\",\"credentialSecret\":\"$SECRET\"}}" >/dev/null
kubectl -n longhorn-system wait --for=jsonpath='{.status.available}'=true \
  backuptarget/default --timeout=15m
echo 'RESULT: DR LONGHORN TARGET MIGRATED TO WD CIFS'
