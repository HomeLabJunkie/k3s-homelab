#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0

check() {
  local label="$1"
  local regex="$2"
  local hits

  hits="$({
    git grep --cached -IlE "$regex" -- \
      ':!config/cluster.env.example' \
      ':!config/email.env.example' \
      ':!README.md' \
      ':!.gitignore' \
      2>/dev/null || true
  } | sort -u)"

  if [[ -n "$hits" ]]; then
    echo "ERROR: $label detected in tracked files:" >&2
    echo "$hits" >&2
    fail=1
  fi
}

check "private key" 'BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY'
check "age private key" 'AGE-SECRET-KEY(-PQ)?-1'
check "GitHub token" '(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})'
check "AWS access key" '(AKIA|ASIA)[A-Z0-9]{16}'
check "Google API key" 'AIza[0-9A-Za-z_-]{35}'
check "Slack token" 'xox[baprs]-[A-Za-z0-9-]{10,}'
check "live Stripe secret key" 'sk_live_[0-9A-Za-z]{16,}'

vaultwarden_values="templates/generated/apps/vaultwarden/values.yaml.template"
if git ls-files --error-unmatch "$vaultwarden_values" >/dev/null 2>&1; then
  value_hits="$(awk '
    /^(adminToken|smtp|yubico):/ {
      section=$1
      sub(/:.*/, "", section)
      next
    }
    /^[^[:space:]]/ { section="" }
    section != "" && /^[[:space:]]+value:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]+value:[[:space:]]*/, "", value)
      if (value != "" && value != "\"\"" && value != "'"'"''"'"'") {
        print FILENAME ":" FNR
      }
    }
  ' "$vaultwarden_values")"

  if [[ -n "$value_hits" ]]; then
    echo "ERROR: plaintext Vaultwarden credential value detected:" >&2
    echo "$value_hits" >&2
    fail=1
  fi
fi

(( fail == 0 )) || exit 1
echo "Secret/config scan passed."
