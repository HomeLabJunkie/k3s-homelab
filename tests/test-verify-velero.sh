#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

cat >"$TEST_ROOT/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

case "$*" in
  *"get backupstoragelocation garage"*) printf '%s' Available ;;
  *"get backupstoragelocation rustfs"*) printf '%s' Available ;;
  *"get schedules.velero.io protected-apps-daily"*) printf '%s' Enabled ;;
  *"get backups.velero.io"*)
    printf '%s\n' "${BACKUPS_JSON:?}"
    ;;
  *"get daemonset node-agent"*)
    printf '%s\n' '{"status":{"desiredNumberScheduled":6,"numberReady":6}}'
    ;;
  *)
    echo "unexpected kubectl arguments: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_ROOT/kubectl"

completed="$(date -u -Iseconds)"
export BACKUPS_JSON="$(jq -cn --arg completed "$completed" '{items:[
  {metadata:{name:"newer-rustfs"},spec:{storageLocation:"rustfs"},status:{phase:"Completed",completionTimestamp:$completed}},
  {metadata:{name:"garage-current"},spec:{storageLocation:"garage"},status:{phase:"Completed",completionTimestamp:$completed}}
]}')"

output="$(PATH="$TEST_ROOT:$PATH" "$ROOT_DIR/backup/verify-velero.sh")"
grep -q '^==> Latest Velero backup: garage-current$' <<<"$output"
grep -q '^==> Velero storage location: garage$' <<<"$output"

output="$(PATH="$TEST_ROOT:$PATH" VELERO_STORAGE_LOCATION=rustfs \
  "$ROOT_DIR/backup/verify-velero.sh")"
grep -q '^==> Latest Velero backup: newer-rustfs$' <<<"$output"
grep -q '^==> Velero storage location: rustfs$' <<<"$output"

echo "Velero storage-location verifier tests passed"
