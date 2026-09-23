#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMAIL_ENV="${EMAIL_ENV:-$ROOT/config/email.env}"
ENV_FILE="${ENV_FILE:-$ROOT/config/cluster.env}"
CHECK_ONLY=false

if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
  shift
fi

subject="${1:-K3s DR alert}"
body_file="${2:-}"
body="No additional details."
[[ -n "$body_file" && -f "$body_file" ]] && body="$(cat "$body_file")"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ -f "$EMAIL_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$EMAIL_ENV"
  set +a
fi

if [[ -z "${SMTP_USER:-}" || -z "${SMTP_PASSWORD:-}" ]]; then
  set -a
  if [[ -f "$ROOT/.secrets.enc" ]]; then
    command -v sops >/dev/null 2>&1 || {
      echo "ERROR: sops is required to load SMTP credentials" >&2
      exit 1
    }
    # Keep going on failure so the desktop notification can still be sent.
    if decrypted_secrets="$(sops --decrypt "$ROOT/.secrets.enc")"; then
      # shellcheck disable=SC1090
      source <(printf '%s\n' "$decrypted_secrets")
    else
      echo "WARNING: sops could not decrypt SMTP credentials; email disabled" >&2
    fi
    unset decrypted_secrets
  elif [[ -f "$ROOT/.secrets" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT/.secrets"
  fi
  set +a
fi

SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-${VAULTWARDEN_SMTP_USERNAME:-}}"
SMTP_PASSWORD="${SMTP_PASSWORD:-${VAULTWARDEN_SMTP_PASSWORD:-}}"
MAIL_FROM="${MAIL_FROM:-${ADMIN_EMAIL:-$SMTP_USER}}"
MAIL_TO="${MAIL_TO:-${ADMIN_EMAIL:-}}"

email_ready=1
for var in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD MAIL_FROM MAIL_TO; do
  [[ -n "${!var:-}" ]] || email_ready=0
done

if [[ "$CHECK_ONLY" == true ]]; then
  (( email_ready == 1 )) || {
    echo "ERROR: SMTP notification configuration is incomplete" >&2
    exit 1
  }
  command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl is required for SMTP notifications" >&2
    exit 1
  }
  curl --version | grep -qE '^Protocols: .*smtp' || {
    echo "ERROR: the installed curl does not support SMTP" >&2
    exit 1
  }
  echo "SMTP notification configuration is ready for ${MAIL_TO}."
  exit 0
fi

desktop_sent=0
email_sent=0

if command -v notify-send >/dev/null 2>&1; then
  if notify-send --urgency=critical "$subject" "$body"; then
    desktop_sent=1
  fi
fi

if (( email_ready == 1 )); then
  command -v curl >/dev/null 2>&1 || {
    echo "ERROR: SMTP is configured but curl is unavailable" >&2
    exit 1
  }
  for value in "$SMTP_HOST" "$SMTP_PORT" "$SMTP_USER" "$SMTP_PASSWORD" \
               "$MAIL_FROM" "$MAIL_TO"; do
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
      echo "ERROR: SMTP configuration contains a line break" >&2
      exit 1
    }
  done
  # curl's config parser treats \ as an escape inside double quotes, so escape
  # backslashes and quotes; otherwise a password containing \ is silently altered.
  cq() {
    local v="${1//\\/\\\\}"
    printf '%s' "${v//\"/\\\"}"
  }
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
url = "$(cq "smtp://${SMTP_HOST}:${SMTP_PORT}")"
ssl-reqd
user = "$(cq "${SMTP_USER}:${SMTP_PASSWORD}")"
mail-from = "$(cq "${MAIL_FROM}")"
mail-rcpt = "$(cq "${MAIL_TO}")"
upload-file = "$(cq "${msg}")"
silent
show-error
EOF
  chmod 600 "$cfg"
  if curl --config "$cfg"; then
    email_sent=1
  else
    echo "ERROR: SMTP notification delivery failed" >&2
    exit 1
  fi
fi

if (( desktop_sent == 0 && email_sent == 0 )); then
  echo "WARNING: no desktop or email notification channel was available" >&2
  exit 1
fi
