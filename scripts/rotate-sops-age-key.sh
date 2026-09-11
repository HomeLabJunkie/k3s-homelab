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
"$ROOT_DIR/scripts/test-secrets-recovery.sh"
{
  echo "SOPS age-recipient rotation completed."
  echo
  echo "Update the Bitwarden SOPS AGE KEY record with the new private key now."
  echo "The encrypted secrets recovery test passed."
  echo
  echo "Recipients before: $(paste -sd, "$before")"
  echo "Recipients after:  $(paste -sd, "$after")"
} >"$detail"
"$NOTIFY" "[ACTION REQUIRED] Update Bitwarden SOPS AGE KEY" "$detail"
echo "RESULT: SOPS AGE-KEY ROTATION VERIFIED; BITWARDEN REMINDER SENT"
