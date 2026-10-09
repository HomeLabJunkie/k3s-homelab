#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=backup/remote-storage.sh
source "$ROOT_DIR/backup/remote-storage.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# Exercise the remote snippets locally without SSH or root privileges.
storage_root_script() {
    bash -s -- "$@"
}

# A bundle published under a permissive umask must end up private.
bundle="$TEST_ROOT/bundle"
(
    umask 022
    mkdir -p "$bundle/etcd" "$bundle/repo" "$bundle/cluster-state"
    echo snapshot >"$bundle/etcd/manual-snapshot"
    echo secrets >"$bundle/repo/k3s-secrets.enc"
    echo manifest >"$bundle/BACKUP-MANIFEST.txt"
)
chmod 777 "$bundle/cluster-state"
[[ -n "$(find "$bundle" -perm /077 -print -quit)" ]]

storage_restrict_bundle "$bundle"

exposed="$(find "$bundle" -perm /077 -print)"
[[ -z "$exposed" ]] || {
    echo "bundle entries are still group- or world-accessible:" >&2
    echo "$exposed" >&2
    exit 1
}
[[ "$(stat -c %a "$bundle")" == 700 ]]
[[ "$(stat -c %a "$bundle/etcd/manual-snapshot")" == 600 ]]
[[ "$(cat "$bundle/etcd/manual-snapshot")" == snapshot ]]

# A missing or symlinked bundle path is refused rather than followed.
if storage_restrict_bundle "$TEST_ROOT/missing" 2>/dev/null; then
    echo "expected a missing bundle to be refused" >&2
    exit 1
fi
ln -s bundle "$TEST_ROOT/link"
if storage_restrict_bundle "$TEST_ROOT/link" 2>/dev/null; then
    echo "expected a symlinked bundle to be refused" >&2
    exit 1
fi

# backup.sh must stage privately and restrict the bundle before it is verified
# and published as latest.
grep -qx 'umask 077' "$ROOT_DIR/backup/backup.sh"
restrict_line="$(grep -n '^storage_restrict_bundle "\$DEST"$' "$ROOT_DIR/backup/backup.sh" | cut -d: -f1)"
latest_line="$(grep -n '^storage_replace_symlink ' "$ROOT_DIR/backup/backup.sh" | cut -d: -f1)"
[[ -n "$restrict_line" && -n "$latest_line" ]]
(( restrict_line < latest_line ))

echo "backup bundle-permission tests passed"
