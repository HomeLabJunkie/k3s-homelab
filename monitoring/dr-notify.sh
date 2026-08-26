#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMAIL_ENV="${EMAIL_ENV:-$ROOT/config/email.env}"
[[ -f "$EMAIL_ENV" ]] || { echo "ERROR: missing $EMAIL_ENV"; exit 1; }
set -a
source "$EMAIL_ENV"
set +a
for v in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD MAIL_FROM MAIL_TO; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is unset"; exit 1; }
done
command -v msmtp >/dev/null 2>&1 || { echo "ERROR: msmtp is required"; exit 1; }

subject="${1:-K3s DR alert}"
body_file="${2:-}"
msg="$(mktemp)"
cfg="$(mktemp)"
trap 'rm -f "$msg" "$cfg"' EXIT

cat >"$msg" <<EOF
From: ${MAIL_FROM}
To: ${MAIL_TO}
Subject: ${subject}
Date: $(date -R)
Content-Type: text/plain; charset=UTF-8

EOF

if [[ -n "$body_file" && -f "$body_file" ]]; then
  cat "$body_file" >>"$msg"
else
  cat >>"$msg"
fi

cat >"$cfg" <<EOF
defaults
auth on
tls on
tls_starttls ${SMTP_STARTTLS:-on}
account dr
host ${SMTP_HOST}
port ${SMTP_PORT}
user ${SMTP_USER}
password ${SMTP_PASSWORD}
from ${MAIL_FROM}
account default : dr
EOF
chmod 600 "$cfg"
msmtp -C "$cfg" -t <"$msg"
