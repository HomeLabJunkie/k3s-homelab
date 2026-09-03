#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/config/cluster.env}"
SRC_DIR="${SRC_DIR:-$ROOT/templates}"
OUT_DIR="${OUT_DIR:-$ROOT/rendered}"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: missing $ENV_FILE"; exit 1; }
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a
for v in BASE_DOMAIN ADMIN_EMAIL UNRAID_IP CLUSTER_BACKUP_EXPORT LONGHORN_BACKUP_EXPORT; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is unset"; exit 1; }
done
command -v envsubst >/dev/null || { echo "Install gettext-base for envsubst"; exit 1; }
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
while IFS= read -r -d '' f; do
  rel="${f#"$SRC_DIR"/}"; out="$OUT_DIR/$rel"; mkdir -p "$(dirname "$out")"
  envsubst <"$f" >"$out"
done < <(find "$SRC_DIR" -type f -print0)
echo "Rendered to $OUT_DIR"
