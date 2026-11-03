#!/usr/bin/env bash
set -Eeuo pipefail

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || {
    echo "ERROR: required SMTP variable is empty: $name" >&2
    exit 1
  }
}

SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-${VAULTWARDEN_SMTP_USERNAME:-}}"
SMTP_PASSWORD="${SMTP_PASSWORD:-${VAULTWARDEN_SMTP_PASSWORD:-}}"
MAIL_FROM="${MAIL_FROM:-${ADMIN_EMAIL:-$SMTP_USER}}"
MAIL_TO="${MAIL_TO:-${ADMIN_EMAIL:-}}"

for var in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD MAIL_FROM MAIL_TO; do
  require_var "$var"
done

export SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD MAIL_FROM MAIL_TO

python3 <<'PY_CONFIG'
import json
import os

config = {
    "global": {
        "smtp_smarthost": f"{os.environ['SMTP_HOST']}:{os.environ['SMTP_PORT']}",
        "smtp_from": os.environ["MAIL_FROM"],
        "smtp_auth_username": os.environ["SMTP_USER"],
        "smtp_auth_password": os.environ["SMTP_PASSWORD"],
        "smtp_require_tls": True,
    },
    "route": {
        "receiver": "smtp-email",
        "group_by": ["alertname", "namespace"],
        "group_wait": "30s",
        "group_interval": "5m",
        "repeat_interval": "12h",
        "routes": [
            # Meta-alerts that exist only to drive other machinery: Watchdog
            # proves the pipeline works, InfoInhibitor mutes info alerts.
            {
                "receiver": "null",
                "matchers": ['alertname=~"Watchdog|InfoInhibitor"'],
            }
        ],
    },
    "receivers": [
        {"name": "null"},
        {
            "name": "smtp-email",
            "email_configs": [
                {
                    "to": os.environ["MAIL_TO"],
                    "send_resolved": True,
                }
            ],
        },
    ],
    # The kube-prometheus-stack defaults, which this configuration replaces.
    "inhibit_rules": [
        {
            "source_matchers": ['severity="critical"'],
            "target_matchers": ['severity=~"warning|info"'],
            "equal": ["namespace", "alertname"],
        },
        {
            "source_matchers": ['severity="warning"'],
            "target_matchers": ['severity="info"'],
            "equal": ["namespace", "alertname"],
        },
        {
            "source_matchers": ['alertname="InfoInhibitor"'],
            "target_matchers": ['severity="info"'],
            "equal": ["namespace"],
        },
        {
            "target_matchers": ['alertname="InfoInhibitor"'],
        },
    ],
}

print(json.dumps(config, separators=(",", ":")))
PY_CONFIG
