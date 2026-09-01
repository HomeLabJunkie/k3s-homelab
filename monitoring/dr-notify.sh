#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMAIL_ENV="${EMAIL_ENV:-$ROOT/config/email.env}"
subject="${1:-K3s DR alert}"
body_file="${2:-}"
body="No additional details."
[[ -n "$body_file" && -f "$body_file" ]] && body="$(cat "$body_file")"
sent=0

if command -v notify-send >/dev/null 2>&1; then
  notify-send --urgency=critical "$subject" "$body" && sent=1 || true
fi

if [[ -f "$EMAIL_ENV" ]] && command -v msmtp >/dev/null 2>&1; then
  set -a
  # shellcheck disable=SC1090
  source "$EMAIL_ENV"
  set +a

  email_ready=1
  for v in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD MAIL_FROM MAIL_TO; do
    [[ -n "${!v:-}" ]] || email_ready=0
  done

  if (( email_ready == 1 )); then
    msg="$(mktemp)"
    cfg="$(mktemp)"
    trap 'rm -f "${msg:-}" "${cfg:-}"' EXIT
    cat >"$msg" <<EOF
From: ${MAIL_FROM}
To: ${MAIL_TO}
Subject: ${subject}
Date: $(date -R)
Content-Type: text/plain; charset=UTF-8

${body}
EOF
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
    msmtp -C "$cfg" -t <"$msg" && sent=1
  fi
fi

if (( sent == 0 )); then
  echo "WARNING: no desktop or email notification channel was available" >&2
  exit 1
fi
