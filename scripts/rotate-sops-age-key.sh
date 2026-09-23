#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-$ROOT_DIR/.secrets.enc}"
NOTIFY="${NOTIFY:-$ROOT_DIR/monitoring/dr-notify.sh}"
[[ -f "$SECRETS_FILE" && -f "$ROOT_DIR/.sops.yaml" ]] || { echo "ERROR: SOPS files are missing" >&2; exit 1; }
command -v sops >/dev/null || { echo "ERROR: sops is required" >&2; exit 1; }
before="$(mktemp)"; after="$(mktemp)"; detail="$(mktemp)"
trap 'rm -f -- "$before" "$after" "$detail"' EXIT
sops -d "$SECRETS_FILE" >/dev/null
jq -r '.sops.age[]?.recipient' "$SECRETS_FILE" | sort >"$before"
sops updatekeys --yes "$SECRETS_FILE"
jq -r '.sops.age[]?.recipient' "$SECRETS_FILE" | sort >"$after"
if cmp -s "$before" "$after"; then
  echo "ERROR: SOPS recipient set did not change; no reminder sent" >&2; exit 1
fi
# Existing recovery bundles still hold the old ciphertext; publish one for the
# new recipients before the recovery test checks the latest bundle.
echo "==> Publishing a recovery bundle encrypted to the new recipients..."
"$ROOT_DIR/backup/backup.sh" || {
  echo "ERROR: .secrets.enc was re-keyed, but the recovery backup failed." >&2
  echo "ERROR: existing DR bundles are still encrypted to the previous recipients; keep the old key," >&2
  echo "ERROR: rerun backup/backup.sh, then scripts/test-secrets-recovery.sh. No reminder was sent." >&2
  exit 1
}
"$ROOT_DIR/scripts/test-secrets-recovery.sh"
{
  echo "SOPS age-recipient rotation completed."
  echo
  echo "Update the Bitwarden SOPS AGE KEY record with the new private key now."
  echo "The encrypted secrets recovery test passed against a fresh recovery bundle."
  echo
  echo "Keep the previous private key escrowed: older recovery bundles are still"
  echo "encrypted to it until they age out (retention keeps ${BACKUP_KEEP_COUNT:-14} nightly bundles)."
  echo
  echo "Recipients before: $(paste -sd, "$before")"
  echo "Recipients after:  $(paste -sd, "$after")"
} >"$detail"
"$NOTIFY" "[ACTION REQUIRED] Update Bitwarden SOPS AGE KEY" "$detail"
echo "RESULT: SOPS AGE-KEY ROTATION VERIFIED; BITWARDEN REMINDER SENT"
