#!/usr/bin/env bash
# Which backup recovery/restore.sh picks on a rebuilt cluster, where the claim
# is bound to a new volume and the old volume's backups are in the store.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$TEST_ROOT/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *"get pvc trilium-data -o jsonpath={.spec.volumeName}"*) printf '%s' pvc-new ;;
  *"get backups.longhorn.io -o json"*) printf '%s\n' "${BACKUPS_JSON:?}" ;;
  *"get backupvolumes.longhorn.io -o json"*) printf '%s\n' "${BACKUPVOLUMES_JSON:?}" ;;
  *) echo "unexpected kubectl arguments: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/kubectl"

printf 'trilium|trilium|trilium-data|deployment|trilium|trilium|trilium\n' >"$TEST_ROOT/apps.conf"

backup() { # name volume created [pvcName]
  jq -cn --arg n "$1" --arg v "$2" --arg at "$3" --arg pvc "${4:-trilium-data}" '{
    metadata:{name:$n},
    status:{state:"Completed", volumeName:$v, backupCreatedAt:$at,
      labels:{KubernetesStatus:({namespace:"trilium", pvcName:$pvc}|tojson)}}}'
}
backupvolume() { # volume last-backup last-at
  jq -cn --arg v "$1" --arg b "$2" --arg at "$3" \
    '{metadata:{name:($v+"-0a1b2c3d")}, status:{lastBackupName:$b, lastBackupAt:$at}}'
}

run() {
  PATH="$TEST_ROOT:$PATH" ENV_FILE=/dev/null APPS_FILE="$TEST_ROOT/apps.conf" \
    "$ROOT_DIR/recovery/restore.sh" "$@" 2>&1
}

# Just rebuilt: the new volume has no backups, the old one has two, and an
# unrelated claim's backup is in the store too.
export BACKUPS_JSON BACKUPVOLUMES_JSON
BACKUPS_JSON="$(jq -sc '{items:.}' <(
  backup old-1 pvc-old 2026-10-01T02:37:00Z
  backup old-2 pvc-old 2026-10-02T02:37:00Z
  backup other pvc-other 2026-10-03T02:37:00Z other-claim))"
BACKUPVOLUMES_JSON="$(jq -sc '{items:.}' <(
  backupvolume pvc-old old-2 2026-10-02T02:37:00Z
  backupvolume pvc-other other 2026-10-03T02:37:00Z))"

out="$(run --plan trilium)"
grep -q 'latest backup:  old-2 2026-10-02T02:37:00Z pvc-old-' <<<"$out" ||
  fail "a rebuilt cluster's plan does not use the old volume's newest backup: $out"

out="$(run --list-backups trilium)"
grep -q '^pvc-old .* 2026-10-02T02:37:00Z  2 ' <<<"$out" || fail "the old volume is not listed with its two backups: $out"
grep -q 'pvc-other' <<<"$out" && fail "another claim's backups are listed"

# A nightly backup of the new, empty volume has run since: it is the default
# now, the list shows both, and --from-volume reaches the old one.
BACKUPS_JSON="$(jq -c --argjson b "$(backup new-1 pvc-new 2026-10-03T02:37:00Z)" '.items += [$b]' <<<"$BACKUPS_JSON")"
BACKUPVOLUMES_JSON="$(jq -c --argjson b "$(backupvolume pvc-new new-1 2026-10-03T02:37:00Z)" '.items += [$b]' <<<"$BACKUPVOLUMES_JSON")"

out="$(run --plan trilium)"
grep -q 'latest backup:  new-1 ' <<<"$out" || fail "the live volume's own backup is not the default: $out"

out="$(run --list-backups trilium)"
grep -q '^pvc-new .*(live volume)' <<<"$out" || fail "the live volume is not marked: $out"
grep -q '^pvc-old ' <<<"$out" || fail "the old volume is missing once the new one has a backup: $out"

out="$(run --plan trilium --from-volume pvc-old)"
grep -q 'latest backup:  old-2 ' <<<"$out" || fail "--from-volume did not pick the old volume: $out"

out="$(run --plan trilium --from-volume pvc-missing)"
grep -q 'latest backup:  NONE' <<<"$out" || fail "a volume with no backups did not show NONE: $out"

echo "PASS: restore.sh backup choice"
