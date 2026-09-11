#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$(
  ADMIN_EMAIL=alerts@example.test \
  VAULTWARDEN_SMTP_USERNAME=smtp-user@example.test \
  VAULTWARDEN_SMTP_PASSWORD='test-password' \
    "$ROOT/scripts/render-alertmanager-config.sh"
)"

python3 - "$output" <<'PY_TEST'
import json
import sys

config = json.loads(sys.argv[1])
assert config["global"]["smtp_smarthost"] == "smtp.gmail.com:587"
assert config["global"]["smtp_auth_username"] == "smtp-user@example.test"
assert config["global"]["smtp_auth_password"] == "test-password"
assert config["route"]["receiver"] == "smtp-email"
assert config["route"]["routes"][0]["receiver"] == "null"
assert config["receivers"][1]["email_configs"][0]["to"] == "alerts@example.test"
assert config["receivers"][1]["email_configs"][0]["send_resolved"] is True
PY_TEST

echo 'PASS: Alertmanager SMTP configuration renderer'
