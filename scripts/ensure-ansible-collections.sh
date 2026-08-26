#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REQUIREMENTS="${ANSIBLE_COLLECTION_REQUIREMENTS:-$REPO_DIR/collections/requirements.yml}"
COLLECTION_ROOT="${ANSIBLE_COLLECTION_ROOT:-$REPO_DIR/.ansible/collections}"
COLLECTION_TREE="$COLLECTION_ROOT/ansible_collections"

fail(){ echo "ERROR: $*" >&2; exit 1; }
command -v ansible-galaxy >/dev/null 2>&1 || fail "ansible-galaxy is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[[ -r "$REQUIREMENTS" ]] || fail "missing requirements file: $REQUIREMENTS"
mkdir -p "$COLLECTION_ROOT"

check_versions() {
python3 - "$REQUIREMENTS" "$COLLECTION_TREE" <<'PY'
from pathlib import Path
import json, re, sys
req = Path(sys.argv[1]); tree = Path(sys.argv[2])
entries=[]; current=None
for raw in req.read_text().splitlines():
    line=raw.strip()
    m=re.match(r"-\s+name:\s*([A-Za-z0-9_.-]+)\s*$", line)
    if m:
        current=m.group(1); continue
    m=re.match(r"version:\s*[\"']?([^\"']+)[\"']?\s*$", line)
    if m and current:
        entries.append((current,m.group(1))); current=None
if not entries:
    print("ERROR: no pinned collections found"); raise SystemExit(1)
bad=False
for fqcn,wanted in entries:
    ns,name=fqcn.split('.',1)
    manifest=tree/ns/name/'MANIFEST.json'
    if not manifest.exists():
        print(f"MISSING {fqcn} expected={wanted}"); bad=True; continue
    data=json.loads(manifest.read_text())
    actual=data.get('collection_info',{}).get('version')
    if actual==wanted:
        print(f"OK {fqcn} {actual}")
    else:
        print(f"MISMATCH {fqcn} expected={wanted} actual={actual}"); bad=True
raise SystemExit(1 if bad else 0)
PY
}

if CHECK_OUTPUT="$(check_versions 2>&1)"; then
  echo "==> Ansible collections already match pinned requirements."
  printf '%s\n' "$CHECK_OUTPUT"
  exit 0
fi

echo "==> Project-local Ansible collections are missing or mismatched:"
printf '%s\n' "$CHECK_OUTPUT"
echo "==> Installing pinned Ansible collections..."
ansible-galaxy collection install -r "$REQUIREMENTS" -p "$COLLECTION_ROOT" --force
check_versions
echo "==> Ansible collection bootstrap complete."
