#!/usr/bin/env bash
set -Eeuo pipefail
src=/tmp/k3s-dr-sync
dst=/usr/local/libexec/k3s-dr
for name in dr-preflight.sh dr-validate-generated.sh dr-apply-restore.sh \
            dr-bind-restores.sh dr-apply-validation.sh dr-validate-apps.sh dr-cleanup.sh; do
  [[ -f "$src/$name" ]] || { echo "ERROR: missing $src/$name" >&2; exit 1; }
  install -o root -g root -m 0755 "$src/$name" "$dst/$name"
done
echo 'RESULT: DR HELPERS SYNCHRONIZED'
