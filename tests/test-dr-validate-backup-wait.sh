#!/usr/bin/env bash
set -Eeuo pipefail

# recovery/dr-validate-generated.sh waits for a DR cluster that has just
# booted to list the backups the restore manifest references, and still fails
# when they never appear.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

cat >"$TEST_ROOT/restore.yaml" <<'EOF'
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: dr-restore-trilium
  namespace: longhorn-system
spec:
  fromBackup: "nfs://nas:/backups?backup=backup-aaa&volume=pvc-1"
  size: "1073741824"
  numberOfReplicas: 1
  frontend: blockdev
  dataEngine: v1
---
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: dr-restore-vaultwarden
  namespace: longhorn-system
spec:
  fromBackup: "nfs://nas:/backups?backup=system-backup-bbb&volume=pvc-2"
  size: "1073741824"
  numberOfReplicas: 1
  frontend: blockdev
  dataEngine: v1
EOF

# The backup list is empty for the first $LIST_EMPTY_FOR calls, as on a DR
# cluster that has not synced yet.
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'/readyz'*) exit 0 ;;
  *'get backuptarget default -o jsonpath={.status.available}'*) printf true ;;
  *'get backuptarget default -o jsonpath={.status.lastSyncedAt}'*) printf '2026-10-23T00:00:00Z' ;;
  *'get backups.longhorn.io -o json'*)
    n=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$COUNTER"
    if (( n <= LIST_EMPTY_FOR )); then
      echo '{"items":[]}'
    else
      echo '{"items":[
        {"metadata":{"name":"backup-aaa"},"status":{"state":"Completed","snapshotCreatedAt":"2026-10-22T02:37:00Z"}},
        {"metadata":{"name":"system-backup-bbb"},"status":{"state":"Completed","snapshotCreatedAt":"2026-10-22T04:20:00Z"}}]}'
    fi
    ;;
  *'get nodes.longhorn.io'*)
    echo '{"status":{"diskStatus":{"d":{"storageAvailable":536870912000}}}}' ;;
  *'get volumes.longhorn.io'*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/kubectl"

run() {
  local empty_for="$1" out="$2"
  rm -f "$TEST_ROOT/counter"
  set +e
  PATH="$TEST_ROOT/bin:$PATH" COUNTER="$TEST_ROOT/counter" LIST_EMPTY_FOR="$empty_for" \
    DR_NODE=k3s-dr BACKUP_WAIT_SECONDS=2 BACKUP_WAIT_INTERVAL=1 \
    "$REPO_ROOT/recovery/dr-validate-generated.sh" "$TEST_ROOT/restore.yaml" >"$out" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

# Listed on the third check: passes after waiting.
run 2 "$TEST_ROOT/late.out"
grep -qF 'PASS: All referenced backups exist and are Completed' "$TEST_ROOT/late.out"
grep -qF 'Backup system-backup-bbb: Completed' "$TEST_ROOT/late.out"
grep -qF 'listed every referenced backup after 2s' "$TEST_ROOT/late.out"
[[ "$(cat "$TEST_ROOT/counter")" == 3 ]]

# Already listed: passes on the first check without waiting.
run 0 "$TEST_ROOT/ready.out"
grep -qF 'PASS: All referenced backups exist and are Completed' "$TEST_ROOT/ready.out"
if grep -q 'Waiting for' "$TEST_ROOT/ready.out"; then
  echo 'FAIL: waited although the backups were listed' >&2
  exit 1
fi

# Never listed: fails after the wait and says what the DR cluster sees.
if run 99 "$TEST_ROOT/never.out"; then
  echo 'FAIL: validation passed with the backups missing' >&2
  exit 1
fi
grep -qF 'Backup backup-aaa: NOT FOUND' "$TEST_ROOT/never.out"
grep -qF 'FAIL: 2 referenced backup(s) are missing or incomplete after waiting 2s' "$TEST_ROOT/never.out"
grep -qF 'The DR cluster lists 0 backup(s); newest snapshot: none; backup target last synced: 2026-10-23T00:00:00Z' "$TEST_ROOT/never.out"

echo 'PASS: DR restore validation waits for the DR cluster to list backups'
