#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATE="$ROOT_DIR/scripts/validate-manifests.sh"

if ! command -v kubeconform >/dev/null 2>&1; then
    echo "SKIP: kubeconform is not installed"
    exit 0
fi

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# Only custom resources are validated here, so no schema is fetched from the
# network and no cluster is contacted.
export MANIFEST_SCHEMA_CACHE="$TEST_ROOT/cache"
export CRD_SOURCE="$TEST_ROOT/crds.json"
export KUBERNETES_VERSION=1.36.5

cat >"$CRD_SOURCE" <<'JSON'
{
  "items": [
    {
      "spec": {
        "group": "example.test",
        "names": {"kind": "Widget"},
        "versions": [
          {
            "name": "v1",
            "schema": {
              "openAPIV3Schema": {
                "type": "object",
                "properties": {
                  "spec": {
                    "type": "object",
                    "properties": {
                      "task": {"type": "string", "enum": ["backup", "system-backup"]},
                      "note": {"type": "string", "nullable": true},
                      "extra": {
                        "type": "object",
                        "x-kubernetes-preserve-unknown-fields": true
                      }
                    }
                  }
                }
              }
            }
          }
        ]
      }
    }
  ]
}
JSON

widget() {
    printf 'apiVersion: example.test/v1\nkind: Widget\nmetadata:\n  name: test\nspec:\n'
    printf '  %s\n' "$@"
}

expect_valid() {
    local name="$1"
    "$VALIDATE" "$TEST_ROOT/$name.yaml" >/dev/null 2>&1 || {
        echo "expected $name to be valid" >&2
        exit 1
    }
}

expect_invalid() {
    local name="$1"
    if "$VALIDATE" "$TEST_ROOT/$name.yaml" >/dev/null 2>&1; then
        echo "expected $name to be rejected" >&2
        exit 1
    fi
}

# A value only the cluster's own CRD knows about is accepted.
widget 'task: system-backup' >"$TEST_ROOT/good.yaml"
expect_valid good

widget 'task: system-backup' 'note: null' >"$TEST_ROOT/nullable.yaml"
expect_valid nullable

# Fields that opt out of pruning may hold anything.
widget 'task: backup' 'extra:' '  anything: goes' >"$TEST_ROOT/open.yaml"
expect_valid open

widget 'task: restore' >"$TEST_ROOT/bad-enum.yaml"
expect_invalid bad-enum

# CRD schemas tolerate unknown fields by default; the check must not.
widget 'taks: backup' >"$TEST_ROOT/misspelt.yaml"
expect_invalid misspelt

# Offline runs reuse the exported schemas without a CRD source or a cluster.
unset CRD_SOURCE
"$VALIDATE" --offline "$TEST_ROOT/good.yaml" >/dev/null
if "$VALIDATE" --offline "$TEST_ROOT/misspelt.yaml" >/dev/null 2>&1; then
    echo "expected the offline run to reject misspelt" >&2
    exit 1
fi

# With nothing cached, an offline run fails instead of validating nothing.
if MANIFEST_SCHEMA_CACHE="$TEST_ROOT/empty" "$VALIDATE" --offline "$TEST_ROOT/good.yaml" >/dev/null 2>&1; then
    echo "expected an offline run without cached schemas to fail" >&2
    exit 1
fi

echo "validate-manifests tests passed"
