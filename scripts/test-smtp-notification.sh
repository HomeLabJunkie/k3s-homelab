#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="${NOTIFY:-$ROOT_DIR/monitoring/dr-notify.sh}"
detail="$(mktemp)"
trap 'rm -f -- "$detail"' EXIT
{
  echo "This is an automated SMTP delivery test for the K3s DR notification path."
  echo "Timestamp: $(date -Iseconds)"
  echo "No action is required unless this message was unexpected."
} >"$detail"
"$NOTIFY" "[TEST] K3s DR SMTP notification" "$detail"
echo "RESULT: SMTP NOTIFICATION TEST SENT"
