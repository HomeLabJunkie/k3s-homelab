#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR}"

ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"
APPS_FILE="${APPS_FILE:-$ROOT_DIR/recovery/apps.conf}"
BACKUP_VERIFY="${BACKUP_VERIFY:-$ROOT_DIR/backup/verify-backup.sh}"

DR_HOST="${DR_HOST:-k3s-dr}"
DR_PREFLIGHT="${DR_PREFLIGHT:-/usr/local/libexec/k3s-dr/dr-preflight.sh}"

MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-30}"
MAX_APP_BACKUP_AGE_HOURS="${MAX_APP_BACKUP_AGE_HOURS:-30}"
CAPACITY_HEADROOM_PERCENT="${CAPACITY_HEADROOM_PERCENT:-20}"

PASS=0
WARN=0
FAIL=0

pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf 'WARN: %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }

section() {
    echo
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

usage() {
    cat <<'EOF'
Usage:
  ./dr-status.sh

Environment overrides:
  ENV_FILE                  Cluster environment file.
  APPS_FILE                 Protected application list.
  BACKUP_VERIFY             Production backup verifier.
  DR_HOST                   SSH host/alias for DR server. Default: k3s-dr
  DR_PREFLIGHT              Protected DR preflight helper.
  MAX_BACKUP_AGE_HOURS      Max cluster recovery-bundle age. Default: 30
  MAX_APP_BACKUP_AGE_HOURS  Max protected Longhorn backup age. Default: 30
  CAPACITY_HEADROOM_PERCENT Additional restore capacity required. Default: 20

Exit codes:
  0  DR READY
  1  DR NOT READY
  2  DR READY WITH WARNINGS

Safety:
  Read-only readiness/status checks only.
  Does not restore, bind, start validation workloads, or clean up DR resources.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if (( $# != 0 )); then
    usage >&2
    exit 2
fi

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

echo "============================================================"
echo " K3S HOMELAB DR READINESS"
echo "============================================================"
echo
echo "Date:       $(date)"
echo "Repository: $ROOT_DIR"
echo "DR host:    $DR_HOST"
echo

# ---------------------------------------------------------------------------
section "1. LOCAL REPOSITORY"

if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch="$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true)"
    head="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    echo "Branch: ${branch:-unknown}"
    echo "HEAD:   ${head:-unknown}"

    if [[ -z "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]]; then
        pass "Repository working tree is clean"
    else
        warn "Repository has uncommitted changes"
    fi
else
    fail "Repository root is not a Git working tree"
fi

if [[ -r "$APPS_FILE" ]]; then
    protected_count="$(
        awk -F'|' '
          /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
          { n++ }
          END { print n+0 }
        ' "$APPS_FILE"
    )"
    echo "Protected workloads: $protected_count"
    (( protected_count > 0 )) \
        && pass "Protected application inventory is readable" \
        || fail "Protected application inventory is empty"
else
    protected_count=0
    fail "Protected application inventory missing: $APPS_FILE"
fi

# ---------------------------------------------------------------------------
section "2. PRODUCTION KUBERNETES"

if kubectl get --raw='/readyz' >/dev/null 2>&1; then
    pass "Production Kubernetes API is ready"
else
    fail "Production Kubernetes API is unavailable"
fi

node_total="$(kubectl get nodes -o json 2>/dev/null | jq '.items | length' 2>/dev/null || echo 0)"
node_ready="$(
    kubectl get nodes -o json 2>/dev/null |
    jq '[.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length' \
      2>/dev/null || echo 0
)"

echo "Nodes Ready: ${node_ready}/${node_total}"

if [[ "$node_total" =~ ^[0-9]+$ && "$node_ready" =~ ^[0-9]+$ ]] &&
   (( node_total > 0 && node_ready == node_total )); then
    pass "All production Kubernetes nodes are Ready"
else
    fail "Not all production Kubernetes nodes are Ready"
fi

# ---------------------------------------------------------------------------
section "3. PRODUCTION CLUSTER RECOVERY BUNDLE"

backup_output=""
backup_rc=1

if [[ -x "$BACKUP_VERIFY" ]]; then
    set +e
    backup_output="$("$BACKUP_VERIFY" 2>&1)"
    backup_rc=$?
    set -e

    latest_path="$(
        awk '
          /^==> Latest backup:/ { getline; print; exit }
        ' <<<"$backup_output"
    )"
    age_hours="$(
        sed -n 's/^==> Backup age: \([0-9][0-9]*\)h.*/\1/p' <<<"$backup_output" |
        head -1
    )"

    [[ -n "$latest_path" ]] && echo "Latest bundle: $latest_path"
    [[ -n "$age_hours" ]] && echo "Bundle age:    ${age_hours}h"

    if (( backup_rc == 0 )); then
        pass "Production cluster recovery bundle passes verification"
    else
        fail "Production cluster recovery bundle verification failed"
    fi

    if [[ "$age_hours" =~ ^[0-9]+$ ]]; then
        if (( age_hours <= MAX_BACKUP_AGE_HOURS )); then
            pass "Cluster recovery bundle is within ${MAX_BACKUP_AGE_HOURS}h freshness threshold"
        else
            fail "Cluster recovery bundle is ${age_hours}h old (max ${MAX_BACKUP_AGE_HOURS}h)"
        fi
    else
        warn "Could not determine cluster recovery bundle age"
    fi
else
    fail "Backup verifier is missing or not executable: $BACKUP_VERIFY"
fi

# ---------------------------------------------------------------------------
section "4. LONGHORN BACKUP TARGET"

target_available="$(
    kubectl -n longhorn-system get backuptarget default \
      -o jsonpath='{.status.available}' 2>/dev/null || true
)"
target_url="$(
    kubectl -n longhorn-system get backuptarget default \
      -o jsonpath='{.spec.backupTargetURL}' 2>/dev/null || true
)"
target_synced="$(
    kubectl -n longhorn-system get backuptarget default \
      -o jsonpath='{.status.lastSyncedAt}' 2>/dev/null || true
)"

echo "Target:      ${target_url:-unknown}"
echo "Last synced: ${target_synced:-unknown}"

if [[ "$target_available" == "true" ]]; then
    pass "Longhorn backup target is available"
else
    fail "Longhorn backup target is unavailable"
fi

completed_backups="$(
    kubectl -n longhorn-system get backups.longhorn.io -o json 2>/dev/null |
    jq '[.items[] | select(.status.state=="Completed")] | length' 2>/dev/null || echo 0
)"
echo "Completed Longhorn backups: $completed_backups"

if [[ "$completed_backups" =~ ^[0-9]+$ ]] && (( completed_backups > 0 )); then
    pass "Completed Longhorn backups are visible"
else
    fail "No completed Longhorn backups are visible"
fi

# ---------------------------------------------------------------------------
section "5. PROTECTED WORKLOAD BACKUP COVERAGE"

printf '%-13s %-14s %-10s %-22s %s\n' \
    "APPLICATION" "NAMESPACE" "SIZE" "LATEST BACKUP" "AGE"

coverage_total=0
coverage_ok=0
coverage_stale=0
coverage_missing=0
restore_bytes=0
now_epoch="$(date +%s)"

backupvolumes_json="$(
    kubectl -n longhorn-system get backupvolumes.longhorn.io -o json 2>/dev/null || echo '{"items":[]}'
)"

while IFS='|' read -r app ns pvc kind workload service ingress; do
    [[ -z "$app" || "$app" == \#* ]] && continue
    coverage_total=$((coverage_total + 1))

    pvc_json="$(kubectl -n "$ns" get pvc "$pvc" -o json 2>/dev/null || true)"
    if [[ -z "$pvc_json" ]]; then
        printf '%-13s %-14s %-10s %-22s %s\n' \
            "$app" "$ns" "-" "PVC-MISSING" "-"
        coverage_missing=$((coverage_missing + 1))
        continue
    fi

    volume="$(jq -r '.spec.volumeName // ""' <<<"$pvc_json")"
    size_bytes="$(
        kubectl get pv "$volume" -o json 2>/dev/null |
        jq -r '.spec.capacity.storage // ""' 2>/dev/null |
        python3 -c '
import re,sys
s=sys.stdin.read().strip()
m=re.fullmatch(r"([0-9]+)(Ki|Mi|Gi|Ti)?",s)
if not m:
    print(0); raise SystemExit
n=int(m.group(1)); u=m.group(2) or ""
mul={"":1,"Ki":2**10,"Mi":2**20,"Gi":2**30,"Ti":2**40}[u]
print(n*mul)
' 2>/dev/null || echo 0
    )"

    if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
        restore_bytes=$((restore_bytes + size_bytes))
    else
        size_bytes=0
    fi

    size_gib="$(awk -v b="$size_bytes" 'BEGIN { printf "%.1fGi", b/1073741824 }')"

    line="$(
        jq -r --arg v "$volume" '
          [
            .items[]
            | select(
                ((.metadata.name | startswith($v + "-")))
                or ((.status.volumeName // "") == $v)
            )
            | select((.status.lastBackupName // "") != "")
            | [(.status.lastBackupAt // ""), .status.lastBackupName]
          ]
          | sort_by(.[0])
          | reverse
          | .[0] // []
          | @tsv
        ' <<<"$backupvolumes_json" 2>/dev/null || true
    )"

    if [[ -z "$line" ]]; then
        printf '%-13s %-14s %-10s %-22s %s\n' \
            "$app" "$ns" "$size_gib" "NONE" "-"
        coverage_missing=$((coverage_missing + 1))
        continue
    fi

    backup_at="${line%%$'\t'*}"
    backup_name="${line#*$'\t'}"

    if [[ "$backup_at" == "$line" ]]; then
        backup_name="-"
    fi

    if backup_epoch="$(date -d "$backup_at" +%s 2>/dev/null)"; then
        age_h=$(( (now_epoch - backup_epoch) / 3600 ))
        (( age_h < 0 )) && age_h=0
        printf '%-13s %-14s %-10s %-22s %sh\n' \
            "$app" "$ns" "$size_gib" "$backup_name" "$age_h"

        if (( age_h <= MAX_APP_BACKUP_AGE_HOURS )); then
            coverage_ok=$((coverage_ok + 1))
        else
            coverage_stale=$((coverage_stale + 1))
        fi
    else
        printf '%-13s %-14s %-10s %-22s %s\n' \
            "$app" "$ns" "$size_gib" "$backup_name" "UNKNOWN"
        coverage_stale=$((coverage_stale + 1))
    fi
done < "$APPS_FILE"

echo
echo "Protected workloads: $coverage_total"
echo "Fresh backups:       $coverage_ok"
echo "Stale backups:       $coverage_stale"
echo "Missing backups:     $coverage_missing"

restore_gib="$(awk -v b="$restore_bytes" 'BEGIN { printf "%.1f", b/1073741824 }')"
required_with_headroom="$(
    awk -v b="$restore_bytes" -v p="$CAPACITY_HEADROOM_PERCENT" \
      'BEGIN { printf "%.1f", (b * (100+p)/100) / 1073741824 }'
)"

echo "Restore capacity:    ${restore_gib} GiB"
echo "With ${CAPACITY_HEADROOM_PERCENT}% headroom: ${required_with_headroom} GiB"

if (( coverage_total > 0 &&
      coverage_ok == coverage_total &&
      coverage_stale == 0 &&
      coverage_missing == 0 )); then
    pass "All protected workloads have fresh Longhorn backups"
else
    fail "Protected workload backup coverage is incomplete or stale"
fi

# ---------------------------------------------------------------------------
section "6. DR HOST CONNECTIVITY"

if ssh -o BatchMode=yes -o ConnectTimeout=8 "$DR_HOST" 'true' >/dev/null 2>&1; then
    pass "Passwordless SSH to DR host works"
    dr_ssh_ok=1
else
    fail "Cannot reach DR host with passwordless SSH"
    dr_ssh_ok=0
fi

# ---------------------------------------------------------------------------
section "7. DR PREFLIGHT"

dr_output=""
dr_rc=1
dr_available_gib=""

if (( dr_ssh_ok == 1 )); then
    set +e
    dr_output="$(
        ssh -o BatchMode=yes "$DR_HOST" \
          "sudo -n '$DR_PREFLIGHT'" 2>&1
    )"
    dr_rc=$?
    set -e

    dr_pass="$(sed -n 's/^PASS: \([0-9][0-9]*\)$/\1/p' <<<"$dr_output" | tail -1)"
    dr_warn="$(sed -n 's/^WARN: \([0-9][0-9]*\)$/\1/p' <<<"$dr_output" | tail -1)"
    dr_fail="$(sed -n 's/^FAIL: \([0-9][0-9]*\)$/\1/p' <<<"$dr_output" | tail -1)"
    dr_available_gib="$(
        sed -n 's/^Longhorn available capacity: \([0-9.][0-9.]*\) GiB$/\1/p' \
          <<<"$dr_output" | tail -1
    )"

    echo "DR preflight PASS: ${dr_pass:-unknown}"
    echo "DR preflight WARN: ${dr_warn:-unknown}"
    echo "DR preflight FAIL: ${dr_fail:-unknown}"
    [[ -n "$dr_available_gib" ]] && \
        echo "DR Longhorn available: ${dr_available_gib} GiB"

    if (( dr_rc == 0 )) && [[ "${dr_fail:-0}" == "0" ]]; then
        pass "DR preflight passed"
    elif [[ "${dr_fail:-0}" == "0" && "${dr_warn:-0}" =~ ^[1-9] ]]; then
        warn "DR preflight passed with warnings"
    else
        fail "DR preflight failed"
    fi
else
    fail "DR preflight could not run because SSH failed"
fi

# ---------------------------------------------------------------------------
section "8. RESTORE CAPACITY HEADROOM"

if [[ "$dr_available_gib" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    capacity_ok="$(
        awk -v a="$dr_available_gib" -v r="$required_with_headroom" \
          'BEGIN { print (a >= r) ? 1 : 0 }'
    )"

    echo "Required with headroom: ${required_with_headroom} GiB"
    echo "DR available:           ${dr_available_gib} GiB"

    if [[ "$capacity_ok" == "1" ]]; then
        pass "DR Longhorn capacity covers protected restore set plus headroom"
    else
        fail "DR Longhorn capacity is below protected restore requirement"
    fi
else
    warn "Could not independently evaluate DR restore-capacity headroom"
fi

# ---------------------------------------------------------------------------
section "DR READINESS SUMMARY"

printf '%-8s %s\n' "PASS:" "$PASS"
printf '%-8s %s\n' "WARN:" "$WARN"
printf '%-8s %s\n' "FAIL:" "$FAIL"
echo

if (( FAIL > 0 )); then
    echo "RESULT: DR NOT READY"
    exit 1
fi

if (( WARN > 0 )); then
    echo "RESULT: DR READY WITH WARNINGS"
    exit 2
fi

echo "RESULT: DR READY"
exit 0
