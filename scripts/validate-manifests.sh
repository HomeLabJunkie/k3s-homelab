#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="${MANIFEST_SCHEMA_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/k3s-homelab/manifest-schemas}"
CRD_DIR="$CACHE_DIR/crds"
NATIVE_DIR="$CACHE_DIR/native"
VERSION_FILE="$CACHE_DIR/kubernetes-version"
# A file holding `kubectl get crd -o json` output, used instead of the cluster.
CRD_SOURCE="${CRD_SOURCE:-}"
OFFLINE=false

usage() {
  cat <<'EOF'
Usage:
  scripts/validate-manifests.sh [--offline] [FILE...]

Validates Kubernetes manifests with kubeconform, in strict mode, against the
cluster's own Kubernetes version and the CRDs installed in it. With no FILE,
every manifest in the repository is checked, including rendered ones that Git
ignores. Read-only: nothing is applied to the cluster.

Options:
  --offline   Do not contact the cluster; reuse the schemas cached by the
              last online run.

Environment overrides:
  MANIFEST_SCHEMA_CACHE   Schema cache directory.
                          Default: ~/.cache/k3s-homelab/manifest-schemas
  KUBERNETES_VERSION      Validate against this version instead of the
                          cluster's, for example 1.36.5.
  CRD_SOURCE              Read CRDs from this `kubectl get crd -o json` file
                          instead of the cluster.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

FILES=()
while (( $# > 0 )); do
  case "$1" in
    --offline) OFFLINE=true ;;
    -h|--help) usage; exit 0 ;;
    --) shift; FILES+=("$@"); break ;;
    -*) usage >&2; fail "unknown option: $1" ;;
    *) FILES+=("$1") ;;
  esac
  shift
done

for command in kubeconform python3; do
  command -v "$command" >/dev/null 2>&1 || fail "$command command is required"
done

# Write one JSON schema per CRD version where kubeconform looks for it. CRD
# schemas allow unknown fields unless told otherwise, so close every object
# that does not opt out; strict mode then catches misspelt fields.
export_crd_schemas() {
  local source="$1" destination="$2"
  python3 - "$source" "$destination" <<'PY'
import json, os, sys

source, destination = sys.argv[1], sys.argv[2]


def close(schema):
    if not isinstance(schema, dict):
        return
    if schema.get("nullable") and isinstance(schema.get("type"), str):
        schema["type"] = [schema["type"], "null"]
    properties = schema.get("properties")
    if isinstance(properties, dict):
        if ("additionalProperties" not in schema
                and not schema.get("x-kubernetes-preserve-unknown-fields")):
            schema["additionalProperties"] = False
        for child in properties.values():
            close(child)
    for key in ("items", "additionalProperties", "not"):
        close(schema.get(key))
    for key in ("allOf", "anyOf", "oneOf"):
        for child in schema.get(key) or []:
            close(child)


with open(source, encoding="utf-8") as handle:
    crds = json.load(handle).get("items", [])

count = 0
for crd in crds:
    group = crd["spec"]["group"]
    kind = crd["spec"]["names"]["kind"].lower()
    for version in crd["spec"].get("versions", []):
        schema = (version.get("schema") or {}).get("openAPIV3Schema")
        if not schema:
            continue
        root = schema.setdefault("properties", {})
        root.setdefault("apiVersion", {"type": "string"})
        root.setdefault("kind", {"type": "string"})
        root.setdefault("metadata", {"type": "object"})
        close(schema)
        os.makedirs(os.path.join(destination, group), exist_ok=True)
        path = os.path.join(destination, group, f"{kind}_{version['name']}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(schema, handle)
        count += 1

if count == 0:
    sys.exit("no CRD schemas found in " + source)
print(count)
PY
}

refresh_crd_schemas() {
  local source="$1" staging count
  staging="$(mktemp -d "$CACHE_DIR/crds.XXXXXX")"
  if ! count="$(export_crd_schemas "$source" "$staging")"; then
    rm -rf -- "$staging"
    fail "could not export CRD schemas"
  fi
  rm -rf -- "$CRD_DIR"
  mv -- "$staging" "$CRD_DIR"
  echo "==> Exported $count CRD schemas."
}

mkdir -p "$CACHE_DIR" "$NATIVE_DIR"

if [[ -n "$CRD_SOURCE" ]]; then
  [[ -r "$CRD_SOURCE" ]] || fail "CRD_SOURCE is not readable: $CRD_SOURCE"
  refresh_crd_schemas "$CRD_SOURCE"
elif [[ "$OFFLINE" != true ]]; then
  command -v kubectl >/dev/null 2>&1 || fail "kubectl command is required (or use --offline)"
  crd_dump="$(mktemp "$CACHE_DIR/crds.json.XXXXXX")"
  trap 'rm -f -- "$crd_dump"' EXIT
  if kubectl get crd -o json --request-timeout=20s >"$crd_dump" 2>/dev/null; then
    refresh_crd_schemas "$crd_dump"
    kubectl version -o json --request-timeout=20s 2>/dev/null |
      python3 -c 'import json,re,sys; print(re.match(r"v?([0-9.]+)", json.load(sys.stdin)["serverVersion"]["gitVersion"]).group(1))' \
        >"$VERSION_FILE.tmp" && mv -- "$VERSION_FILE.tmp" "$VERSION_FILE"
  else
    echo "WARNING: cluster is unreachable; using the schemas cached earlier." >&2
  fi
fi

[[ -d "$CRD_DIR" ]] ||
  fail "no cached CRD schemas; run once without --offline while the cluster is reachable"

if [[ -z "${KUBERNETES_VERSION:-}" ]]; then
  [[ -s "$VERSION_FILE" ]] ||
    fail "Kubernetes version is unknown; set KUBERNETES_VERSION or run once against the cluster"
  KUBERNETES_VERSION="$(<"$VERSION_FILE")"
fi
[[ "$KUBERNETES_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "unexpected Kubernetes version: $KUBERNETES_VERSION"

# Manifests carry top-level apiVersion and kind; Helm values, playbooks and
# workflows do not. Vendored trees, Ansible content and unrendered templates
# are never descended into.
if (( ${#FILES[@]} == 0 )); then
  cd "$REPO_DIR"
  while IFS= read -r -d '' file; do
    [[ "$(basename "$file")" == kustomization.y*ml ]] && continue
    grep -qE '^apiVersion:' "$file" || continue
    grep -qE '^kind:' "$file" || continue
    FILES+=("${file#./}")
  done < <(
    find . \
      \( -name '.?*' -o -name node_modules -o -name collections -o -name roles \
         -o -name inventory -o -name molecule -o -name logs -o -name templates \
         -o -path './recovery/state' -o -path './apps/*/src' \) -prune \
      -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z
  )
  (( ${#FILES[@]} > 0 )) || fail "no manifests found under $REPO_DIR"
fi

echo "==> Validating ${#FILES[@]} file(s) against Kubernetes $KUBERNETES_VERSION..."
kubeconform -strict -summary \
  -kubernetes-version "$KUBERNETES_VERSION" \
  -cache "$NATIVE_DIR" \
  -schema-location default \
  -schema-location "$CRD_DIR/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -- "${FILES[@]}"
