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

assert_link() {
    local expected="$1" link_path="$2" actual
    actual="$(readlink -- "$link_path")"
    [[ "$actual" == "$expected" ]] || {
        echo "expected $link_path -> $expected, got $actual" >&2
        exit 1
    }
}

latest="$TEST_ROOT/latest"
ln -s host/old "$latest"

storage_replace_symlink host/new "$latest"
assert_link host/new "$latest"
[[ -z "$(find "$TEST_ROOT" -maxdepth 1 -name '.latest.tmp.*' -print -quit)" ]]

storage_restore_symlink_if_current "$latest" host/new host/old
assert_link host/old "$latest"

# Rollback must not overwrite a newer publisher's link.
storage_replace_symlink host/new "$latest"
storage_replace_symlink host/newer "$latest"
storage_restore_symlink_if_current "$latest" host/new host/old
assert_link host/newer "$latest"

# With no prior link, rollback removes the link instead of leaving it dangling.
storage_replace_symlink host/first "$latest"
storage_restore_symlink_if_current "$latest" host/first ""
[[ ! -e "$latest" && ! -L "$latest" ]]

echo "backup latest-symlink tests passed"
