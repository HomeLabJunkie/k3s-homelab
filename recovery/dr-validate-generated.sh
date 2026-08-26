#!/usr/bin/env bash
set -u
set -o pipefail

KUBECTL="${KUBECTL:-kubectl}"
LONGHORN_NS="${LONGHORN_NS:-longhorn-system}"
DR_NODE="${DR_NODE:-k3s-dr-test}"

PASS=0
WARN=0
FAIL=0

pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf 'WARN: %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }

usage() {
    cat <<'EOF'
Usage:
  dr-validate-generated.sh FILE

Environment overrides:
  KUBECTL      Kubernetes CLI command. Default: kubectl
  LONGHORN_NS  Longhorn namespace. Default: longhorn-system
  DR_NODE      DR Longhorn node. Default: k3s-dr-test

Resume-aware collision behavior:
  - Existing matching completed restore volume: PASS / SKIP-COMPLETE
  - Existing matching in-progress restore volume: PASS / RESUME
  - Existing volume with mismatched backup URL or size: FAIL
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if (( $# != 1 )); then
    usage >&2
    exit 2
fi

INPUT="$1"

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: Input file not found: $INPUT" >&2
    exit 2
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "============================================================"
echo " K3S HOMELAB DR GENERATED RESTORE VALIDATION"
echo "============================================================"
echo
echo "Date:    $(date)"
echo "Input:   $INPUT"
echo "DR node: $DR_NODE"
echo

# Split YAML documents.
awk -v dir="$TMPDIR" '
BEGIN {
    n=1
    f=sprintf("%s/doc-%03d.yaml", dir, n)
}
/^---[[:space:]]*$/ {
    n++
    f=sprintf("%s/doc-%03d.yaml", dir, n)
    next
}
{
    print >> f
}
' "$INPUT"

mapfile -t DOCS < <(
    find "$TMPDIR" -maxdepth 1 -type f -name 'doc-*.yaml' -size +0c | sort
)

echo "============================================================"
echo " 1. YAML BASIC CHECKS"
echo "============================================================"

if grep -q '^apiVersion:[[:space:]]*longhorn.io/v1beta2[[:space:]]*$' "$INPUT"; then
    pass "Longhorn Volume manifests detected"
else
    fail "No longhorn.io/v1beta2 manifests detected"
fi

if grep -q '^kind:[[:space:]]*Volume[[:space:]]*$' "$INPUT"; then
    pass "Volume kind detected"
else
    fail "No Volume kind detected"
fi

DOC_COUNT="${#DOCS[@]}"
echo "Restore documents: $DOC_COUNT"

if (( DOC_COUNT > 0 )); then
    pass "$DOC_COUNT restore volume document(s) found"
else
    fail "No restore volume documents found"
fi

declare -a NAMES URLS SIZES REPLICAS
TOTAL_BYTES=0

extract_name() {
    awk '
      $0=="metadata:" {m=1; next}
      m && $1=="name:" {print $2; exit}
    ' "$1"
}

extract_field() {
    local doc="$1"
    local key="$2"
    sed -n "s/^  ${key}: \"\\(.*\\)\"$/\\1/p" "$doc" | head -1
}

extract_plain_field() {
    local doc="$1"
    local key="$2"
    sed -n "s/^  ${key}:[[:space:]]*\\([^[:space:]].*\\)$/\\1/p" "$doc" | head -1
}

for doc in "${DOCS[@]}"; do
    name="$(extract_name "$doc")"
    url="$(extract_field "$doc" fromBackup)"
    size="$(extract_field "$doc" size)"
    replicas="$(extract_plain_field "$doc" numberOfReplicas)"

    NAMES+=("$name")
    URLS+=("$url")
    SIZES+=("$size")
    REPLICAS+=("$replicas")

    if [[ "$size" =~ ^[0-9]+$ ]]; then
        TOTAL_BYTES=$((TOTAL_BYTES + size))
    fi
done

echo
echo "============================================================"
echo " 2. RESTORE NAMES"
echo "============================================================"

bad=0
for name in "${NAMES[@]}"; do
    [[ -n "$name" ]] || bad=$((bad + 1))
done

if (( bad == 0 )); then
    pass "Extracted all restore volume names"
else
    fail "$bad restore document(s) missing metadata.name"
fi

dups="$(
    printf '%s\n' "${NAMES[@]}" |
    sed '/^$/d' |
    sort |
    uniq -d
)"

if [[ -z "$dups" ]]; then
    pass "No duplicate restore volume names"
else
    fail "Duplicate restore volume names detected: $dups"
fi

bad_dns=0
for name in "${NAMES[@]}"; do
    if [[ ! "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        bad_dns=$((bad_dns + 1))
    fi
done

if (( bad_dns == 0 )); then
    pass "All restore volume names are DNS-safe"
else
    fail "$bad_dns restore volume name(s) are not DNS-safe"
fi

echo
echo "============================================================"
echo " 3. BACKUP URLS"
echo "============================================================"

missing_urls=0
bad_urls=0

for url in "${URLS[@]}"; do
    [[ -n "$url" ]] || missing_urls=$((missing_urls + 1))

    if [[ -n "$url" && ! "$url" =~ ^nfs://.+\?backup=.+\&volume=.+$ ]]; then
        bad_urls=$((bad_urls + 1))
    fi
done

if (( missing_urls == 0 )); then
    pass "Every restore volume has a backup URL"
else
    fail "$missing_urls restore volume(s) missing backup URL"
fi

if (( bad_urls == 0 )); then
    pass "All backup URLs have expected Longhorn NFS format"
else
    fail "$bad_urls backup URL(s) have unexpected format"
fi

echo
echo "============================================================"
echo " 4. SIZES"
echo "============================================================"

bad_sizes=0
for size in "${SIZES[@]}"; do
    [[ "$size" =~ ^[1-9][0-9]*$ ]] || bad_sizes=$((bad_sizes + 1))
done

if (( bad_sizes == 0 )); then
    pass "Every restore volume has a numeric size"
else
    fail "$bad_sizes restore volume(s) have invalid size"
fi

TOTAL_GIB="$(
    awk -v B="$TOTAL_BYTES" 'BEGIN { printf "%.1f", B / 1073741824 }'
)"
echo "Requested restore capacity: ${TOTAL_GIB} GiB"

if (( bad_sizes == 0 )); then
    pass "All restore sizes are valid"
fi

echo
echo "============================================================"
echo " 5. REPLICA COUNTS"
echo "============================================================"

missing_replicas=0
bad_replicas=0

for r in "${REPLICAS[@]}"; do
    [[ -n "$r" ]] || missing_replicas=$((missing_replicas + 1))
    [[ "$r" =~ ^[1-9][0-9]*$ ]] || bad_replicas=$((bad_replicas + 1))
done

if (( missing_replicas == 0 )); then
    pass "Every restore volume has a replica count"
else
    fail "$missing_replicas restore volume(s) missing replica count"
fi

if (( bad_replicas == 0 )); then
    pass "All replica counts are positive integers"
else
    fail "$bad_replicas restore volume(s) have invalid replica count"
fi

echo
echo "============================================================"
echo " 6. LONGHORN STATIC FIELDS"
echo "============================================================"

bad_frontend=0
bad_engine=0

for doc in "${DOCS[@]}"; do
    frontend="$(extract_plain_field "$doc" frontend)"
    engine="$(extract_plain_field "$doc" dataEngine)"

    [[ "$frontend" == "blockdev" ]] || bad_frontend=$((bad_frontend + 1))
    [[ "$engine" == "v1" ]] || bad_engine=$((bad_engine + 1))
done

if (( bad_frontend == 0 )); then
    pass "All restore volumes use frontend=blockdev"
else
    fail "$bad_frontend restore volume(s) do not use frontend=blockdev"
fi

if (( bad_engine == 0 )); then
    pass "All restore volumes use dataEngine=v1"
else
    fail "$bad_engine restore volume(s) do not use dataEngine=v1"
fi

echo
echo "============================================================"
echo " 7. CLUSTER ACCESS"
echo "============================================================"

if $KUBECTL get --raw='/readyz' >/dev/null 2>&1; then
    pass "Kubernetes API reachable"
else
    fail "Kubernetes API is not ready"
fi

TARGET_AVAILABLE="$(
    $KUBECTL -n "$LONGHORN_NS" get backuptarget default \
        -o jsonpath='{.status.available}' 2>/dev/null || true
)"

if [[ "$TARGET_AVAILABLE" == "true" ]]; then
    pass "Longhorn backup target available"
else
    fail "Longhorn backup target unavailable"
fi

echo
echo "============================================================"
echo " 8. BACKUP OBJECT PRESENCE"
echo "============================================================"

BACKUPS_JSON="$TMPDIR/backups.json"

if $KUBECTL -n "$LONGHORN_NS" get backups.longhorn.io -o json > "$BACKUPS_JSON" 2>/dev/null; then
    backup_fail=0

    for url in "${URLS[@]}"; do
        backup_name="$(
            sed -n 's/.*[?&]backup=\([^&]*\).*/\1/p' <<< "$url"
        )"

        state="$(
            jq -r --arg B "$backup_name" '
              [
                .items[]
                | select(.metadata.name==$B)
                | .status.state
              ][0] // ""
            ' "$BACKUPS_JSON"
        )"

        if [[ "$state" == "Completed" ]]; then
            echo "Backup $backup_name: Completed"
        else
            echo "Backup $backup_name: ${state:-NOT FOUND}"
            backup_fail=$((backup_fail + 1))
        fi
    done

    if (( backup_fail == 0 )); then
        pass "All referenced backups exist and are Completed"
    else
        fail "$backup_fail referenced backup(s) are missing or incomplete"
    fi
else
    fail "Unable to retrieve Longhorn Backup objects"
fi

echo
echo "============================================================"
echo " 9. DR NODE CAPACITY"
echo "============================================================"

AVAILABLE_BYTES="$(
    $KUBECTL -n "$LONGHORN_NS" get nodes.longhorn.io "$DR_NODE" -o json 2>/dev/null |
    jq -r '
      [
        .status.diskStatus
        | to_entries[]
        | .value.storageAvailable
      ]
      | add // 0
    ' 2>/dev/null || echo 0
)"

AVAILABLE_GIB="$(
    awk -v B="$AVAILABLE_BYTES" 'BEGIN { printf "%.1f", B / 1073741824 }'
)"

echo "Longhorn available capacity: ${AVAILABLE_GIB} GiB"

if [[ "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] && (( AVAILABLE_BYTES >= TOTAL_BYTES )); then
    pass "Requested restore capacity fits on DR node"
else
    fail "Requested restore capacity exceeds available Longhorn capacity"
fi

echo
echo "============================================================"
echo " 10. EXISTING RESTORE VOLUMES / RESUME SAFETY"
echo "============================================================"

collision_fail=0
existing_count=0
complete_count=0
resume_count=0

for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    expected_url="${URLS[$i]}"
    expected_size="${SIZES[$i]}"

    if ! $KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$name" >/dev/null 2>&1; then
        continue
    fi

    existing_count=$((existing_count + 1))

    vol_json="$(
        $KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$name" -o json 2>/dev/null
    )"

    actual_url="$(jq -r '.spec.fromBackup // ""' <<< "$vol_json")"
    actual_size="$(jq -r '.spec.size // ""' <<< "$vol_json")"
    state="$(jq -r '.status.state // "unknown"' <<< "$vol_json")"
    restore_required="$(jq -r '.status.restoreRequired // false' <<< "$vol_json")"
    node="$(jq -r '.status.currentNodeID // ""' <<< "$vol_json")"

    if [[ "$actual_url" != "$expected_url" || "$actual_size" != "$expected_size" ]]; then
        echo "MISMATCH: $name"
        echo "  expected backup: $expected_url"
        echo "  actual backup:   $actual_url"
        echo "  expected size:   $expected_size"
        echo "  actual size:     $actual_size"
        collision_fail=$((collision_fail + 1))
        continue
    fi

    if [[ "$state" == "detached" && "$restore_required" == "false" && -z "$node" ]]; then
        echo "Existing matching volume: $name -> SKIP-COMPLETE"
        complete_count=$((complete_count + 1))
    else
        echo "Existing matching volume: $name -> RESUME"
        resume_count=$((resume_count + 1))
    fi
done

if (( collision_fail > 0 )); then
    fail "$collision_fail existing restore volume(s) do not match the generated manifest"
elif (( existing_count == 0 )); then
    pass "No generated restore volume names already exist"
else
    pass "All $existing_count existing restore volume(s) match the generated manifest"
    echo "Completed/skippable: $complete_count"
    echo "In-progress/resumable: $resume_count"
fi

echo
echo "============================================================"
echo " VALIDATION SUMMARY"
echo "============================================================"
echo
echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"
echo

if (( FAIL > 0 )); then
    echo "============================================================"
    echo " GENERATED RESTORE VALIDATION FAILED"
    echo "============================================================"
    echo
    echo "Do not apply the generated manifest."
    exit 1
fi

if (( WARN > 0 )); then
    echo "============================================================"
    echo " GENERATED RESTORE VALIDATION PASSED WITH WARNINGS"
    echo "============================================================"
    exit 2
fi

echo "============================================================"
echo " GENERATED RESTORE VALIDATION PASSED"
echo "============================================================"
echo
echo "The manifest passed validation."
echo "Existing matching restore volumes may be safely skipped/resumed."
exit 0
