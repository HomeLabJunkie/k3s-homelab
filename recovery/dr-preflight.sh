#!/usr/bin/env bash

# Validation reporter: checks tally PASS/WARN/FAIL and must all run, so -e is
# intentionally omitted (matches the other recovery/dr-validate-*.sh scripts).
set -u
set -o pipefail

KUBECTL="${KUBECTL:-sudo k3s kubectl}"
DR_NODE="${DR_NODE:-k3s-dr-test}"
LONGHORN_NS="${LONGHORN_NS:-longhorn-system}"
MIN_FREE_GIB="${MIN_FREE_GIB:-150}"

PASS=0
WARN=0
FAIL=0

pass() {
    printf 'PASS: %s\n' "$*"
    PASS=$((PASS + 1))
}

warn() {
    printf 'WARN: %s\n' "$*"
    WARN=$((WARN + 1))
}

fail() {
    printf 'FAIL: %s\n' "$*"
    FAIL=$((FAIL + 1))
}

section() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
}

echo "============================================================"
echo " K3S HOMELAB DISASTER RECOVERY PREFLIGHT"
echo "============================================================"
echo
echo "Date:    $(date)"
echo "Host:    $(hostname)"
echo "DR node: $DR_NODE"


section "1. HOST STORAGE"

ROOT_AVAIL_KB=$(df -Pk / | awk 'NR==2 {print $4}')

if [[ "$ROOT_AVAIL_KB" =~ ^[0-9]+$ ]]; then
    ROOT_AVAIL_GIB=$((ROOT_AVAIL_KB / 1024 / 1024))
    echo "Root filesystem available: ${ROOT_AVAIL_GIB} GiB"

    if (( ROOT_AVAIL_GIB >= MIN_FREE_GIB )); then
        pass "Host has at least ${MIN_FREE_GIB} GiB free"
    else
        fail "Host has less than ${MIN_FREE_GIB} GiB free"
    fi
else
    fail "Unable to determine root filesystem free space"
fi

if [[ -d /var/lib/longhorn ]]; then
    pass "/var/lib/longhorn exists"
    df -h /var/lib/longhorn
else
    fail "/var/lib/longhorn does not exist"
fi


section "2. KUBERNETES API"

if $KUBECTL get --raw='/readyz' >/tmp/dr-readyz.$$ 2>&1; then
    READYZ=$(cat /tmp/dr-readyz.$$)
    echo "$READYZ"

    if grep -q '^ok' /tmp/dr-readyz.$$; then
        pass "Kubernetes API reports ready"
    else
        warn "Kubernetes API responded but did not return simple 'ok'"
    fi
else
    cat /tmp/dr-readyz.$$
    fail "Kubernetes API readiness check failed"
fi

rm -f /tmp/dr-readyz.$$


section "3. KUBERNETES NODE"

NODE_READY=$(
    $KUBECTL get node "$DR_NODE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || true
)

if [[ "$NODE_READY" == "True" ]]; then
    pass "Kubernetes node $DR_NODE is Ready"
else
    fail "Kubernetes node $DR_NODE is not Ready"
fi

$KUBECTL get node "$DR_NODE" -o wide 2>/dev/null || true


section "4. CORE CLUSTER PODS"

echo
echo "--- kube-system ---"
$KUBECTL -n kube-system get pods -o wide 2>/dev/null || true

BAD_CORE=$(
    $KUBECTL -n kube-system get pods \
        --no-headers 2>/dev/null |
    awk '$3 != "Running" && $3 != "Completed" {count++} END {print count+0}'
)

if (( BAD_CORE == 0 )); then
    pass "No non-running kube-system pods detected"
else
    warn "$BAD_CORE kube-system pod(s) are not Running/Completed"
fi


section "5. LONGHORN SYSTEM"

LH_MANAGER_COUNT=$(
    $KUBECTL -n "$LONGHORN_NS" get pods \
        -l app=longhorn-manager \
        --field-selector=status.phase=Running \
        --no-headers 2>/dev/null |
    wc -l
)

if (( LH_MANAGER_COUNT > 0 )); then
    pass "Longhorn manager is running"
else
    fail "No running Longhorn manager found"
fi


section "6. LONGHORN NODE"

LH_READY=$(
    $KUBECTL -n "$LONGHORN_NS" get \
        nodes.longhorn.io "$DR_NODE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || true
)

if [[ "$LH_READY" == "True" ]]; then
    pass "Longhorn node $DR_NODE is Ready"
else
    fail "Longhorn node $DR_NODE is not Ready"
fi

LH_SCHED=$(
    $KUBECTL -n "$LONGHORN_NS" get \
        nodes.longhorn.io "$DR_NODE" \
        -o jsonpath='{.spec.allowScheduling}' \
        2>/dev/null || true
)

if [[ "$LH_SCHED" == "true" ]]; then
    pass "Longhorn node allows scheduling"
else
    fail "Longhorn node does not allow scheduling"
fi


section "7. LONGHORN DISKS"

DISK_JSON=$(
    $KUBECTL -n "$LONGHORN_NS" get \
        nodes.longhorn.io "$DR_NODE" \
        -o json 2>/dev/null || true
)

if [[ -n "$DISK_JSON" ]]; then

    echo "$DISK_JSON" |
    jq -r '
      .status.diskStatus
      | to_entries[]
      | [
          "disk=" + .key,
          "path=" + .value.diskPath,
          "maximum=" +
            ((.value.storageMaximum / 1073741824) | floor | tostring) +
            " GiB",
          "available=" +
            ((.value.storageAvailable / 1073741824) | floor | tostring) +
            " GiB",
          "scheduled=" +
            ((.value.storageScheduled / 1073741824) | floor | tostring) +
            " GiB"
        ]
      | .[]
    '

    echo

    DISK_READY=$(
        echo "$DISK_JSON" |
        jq -r '
          [
            .status.diskStatus
            | to_entries[]
            | .value.conditions[]
            | select(.type=="Ready")
            | .status
          ]
          | all(. == "True")
        '
    )

    DISK_SCHED=$(
        echo "$DISK_JSON" |
        jq -r '
          [
            .status.diskStatus
            | to_entries[]
            | .value.conditions[]
            | select(.type=="Schedulable")
            | .status
          ]
          | all(. == "True")
        '
    )

    if [[ "$DISK_READY" == "true" ]]; then
        pass "All Longhorn disks report Ready"
    else
        fail "One or more Longhorn disks are not Ready"
    fi

    if [[ "$DISK_SCHED" == "true" ]]; then
        pass "All Longhorn disks report Schedulable"
    else
        fail "One or more Longhorn disks are not Schedulable"
    fi

else
    fail "Unable to retrieve Longhorn disk information"
fi


section "8. LONGHORN BACKUP TARGET"

BACKUP_AVAILABLE=$(
    $KUBECTL -n "$LONGHORN_NS" get \
        backuptarget default \
        -o jsonpath='{.status.available}' \
        2>/dev/null || true
)

if [[ "$BACKUP_AVAILABLE" == "true" ]]; then
    pass "Longhorn backup target is available"
else
    fail "Longhorn backup target is not available"
fi

$KUBECTL -n "$LONGHORN_NS" get \
    backuptarget default -o wide 2>/dev/null || true


section "9. LONGHORN BACKUPS"

COMPLETED_BACKUPS=$(
    $KUBECTL -n "$LONGHORN_NS" get \
        backups.longhorn.io -o json 2>/dev/null |
    jq '[.items[] | select(.status.state=="Completed")] | length' \
        2>/dev/null || echo 0
)

if [[ "$COMPLETED_BACKUPS" =~ ^[0-9]+$ ]] &&
   (( COMPLETED_BACKUPS > 0 )); then
    pass "$COMPLETED_BACKUPS completed Longhorn backup(s) visible"
else
    fail "No completed Longhorn backups visible"
fi


section "10. RESTORE CAPACITY"

if [[ -n "${DISK_JSON:-}" ]]; then

    LH_AVAILABLE_BYTES=$(
        echo "$DISK_JSON" |
        jq '[.status.diskStatus | to_entries[].value.storageAvailable] | add'
    )

    if [[ "$LH_AVAILABLE_BYTES" =~ ^[0-9]+$ ]]; then
        LH_AVAILABLE_GIB=$((LH_AVAILABLE_BYTES / 1073741824))

        echo "Longhorn available capacity: ${LH_AVAILABLE_GIB} GiB"

        if (( LH_AVAILABLE_GIB >= MIN_FREE_GIB )); then
            pass "Longhorn has at least ${MIN_FREE_GIB} GiB available"
        else
            fail "Longhorn has less than ${MIN_FREE_GIB} GiB available"
        fi
    else
        fail "Unable to determine Longhorn available capacity"
    fi
fi


section "11. EXISTING DR RESOURCES"

DR_RESOURCES=$(
    {
        $KUBECTL get pods -A --no-headers 2>/dev/null
        $KUBECTL get pvc -A --no-headers 2>/dev/null
        $KUBECTL get pv --no-headers 2>/dev/null
        $KUBECTL get svc -A --no-headers 2>/dev/null
        $KUBECTL get configmap -A --no-headers 2>/dev/null
        $KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io \
            --no-headers 2>/dev/null
    } |
    grep -E -- '-dr-|dr-realdata' || true
)

if [[ -z "$DR_RESOURCES" ]]; then
    pass "No leftover DR test resources detected"
else
    warn "Existing DR resources detected:"
    echo "$DR_RESOURCES"
fi


section "PREFLIGHT SUMMARY"

echo
echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"
echo

if (( FAIL == 0 )); then
    echo "============================================================"
    echo " DR PREFLIGHT PASSED"
    echo "============================================================"

    if (( WARN > 0 )); then
        echo
        echo "Review warnings before beginning a restore."
    fi

    exit 0
else
    echo "============================================================"
    echo " DR PREFLIGHT FAILED"
    echo "============================================================"
    echo
    echo "Correct failed checks before beginning a restore."

    exit 1
fi
