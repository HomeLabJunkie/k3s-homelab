#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${1:-$(pwd)}"; cd "$ROOT"
echo "== Secret-bearing filenames =="
find . -type f \( -iname '*.key' -o -iname '*.pem' -o -iname '*secret*' -o -iname '*token*' -o -iname '*password*' -o -iname 'k3s.yaml' -o -iname '*kubeconfig*' \) -not -path './.git/*' -print || true
echo "== Domain references =="
grep -RInE --exclude-dir=.git --exclude-dir=rendered '([A-Za-z0-9_-]+\.)+[A-Za-z]{2,}' . 2>/dev/null | head -200 || true
echo "== Private IPv4 references =="
grep -RInE --exclude-dir=.git --exclude-dir=rendered '\b(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})\b' . 2>/dev/null | head -200 || true
echo "== Likely credential assignments =="
grep -RInEi --exclude-dir=.git --exclude-dir=rendered '(password|passwd|token|api[_-]?key|secret|credential)[[:space:]]*[:=][[:space:]]*[^[:space:]$<{]+' . 2>/dev/null | head -200 || true
echo "== Private key/token signatures =="
grep -RInE --exclude-dir=.git --exclude-dir=rendered '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|CF_API_TOKEN|CLOUDFLARE_API_TOKEN)' . 2>/dev/null | head -200 || true
