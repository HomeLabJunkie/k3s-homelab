#!/usr/bin/env bash
set -u
set -o pipefail

KUBECTL="${KUBECTL:-kubectl}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
POLL_SECONDS="${POLL_SECONDS:-5}"
HTTP_RETRIES="${HTTP_RETRIES:-6}"
HTTP_RETRY_DELAY="${HTTP_RETRY_DELAY:-5}"

PASS=0
WARN=0
FAIL=0

pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf 'WARN: %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }

usage() {
    cat <<'EOF'
Usage:
  dr-validate-apps.sh

Environment overrides:
  KUBECTL          Kubernetes CLI command. Default: kubectl
  CURL_IMAGE       Curl image used for isolated HTTP checks.
                   Default: curlimages/curl:latest
  TIMEOUT_SECONDS  Maximum wait per validation pod. Default: 180
  POLL_SECONDS     Seconds between readiness checks. Default: 5
  HTTP_RETRIES     HTTP retries for transient readiness failures. Default: 6
  HTTP_RETRY_DELAY Delay between HTTP retries. Default: 5

Safety:
  - Performs read-only health and restored-data checks.
  - Does not modify application data.
  - Does not create or delete DR application workloads.
  - Temporary curl check pods are created and removed.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if (( $# != 0 )); then
    echo "ERROR: This script takes no positional arguments." >&2
    usage >&2
    exit 2
fi

if ! $KUBECTL get --raw='/readyz' >/dev/null 2>&1; then
    echo "FAIL: Kubernetes API is not ready or cannot be reached."
    exit 1
fi
pass "Kubernetes API reachable"

declare -a APPS=(
    "trilium:trilium-dr-validation"
    "vaultwarden:vaultwarden-dr-validation"
    "portainer:portainer-dr-validation"
    "monitoring:grafana-dr-validation"
    "monitoring:prometheus-dr-validation"
    "monitoring:alertmanager-dr-validation"
    "logging:loki-dr-validation"
)

echo
echo "===== VALIDATION WORKLOADS ====="

for entry in "${APPS[@]}"; do
    ns="${entry%%:*}"
    pod="${entry#*:}"

    if ! $KUBECTL -n "$ns" get pod "$pod" >/dev/null 2>&1; then
        fail "$ns/$pod does not exist"
        continue
    fi

    elapsed=0
    while true; do
        phase="$($KUBECTL -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        ready="$($KUBECTL -n "$ns" get pod "$pod" -o jsonpath='{range .status.containerStatuses[*]}{.ready}{" "}{end}' 2>/dev/null || true)"

        if [[ "$phase" == "Running" && "$ready" != *false* && -n "$ready" ]]; then
            pass "$ns/$pod is Running and Ready"
            break
        fi

        if [[ "$phase" == "Failed" || "$phase" == "Succeeded" ]]; then
            fail "$ns/$pod entered phase $phase"
            break
        fi

        if (( elapsed >= TIMEOUT_SECONDS )); then
            fail "$ns/$pod did not become Ready within ${TIMEOUT_SECONDS}s"
            break
        fi

        sleep "$POLL_SECONDS"
        elapsed=$((elapsed + POLL_SECONDS))
    done
done

run_http_raw() {
    local ns="$1"
    local url="$2"
    local tries="${3:-1}"
    local delay="${4:-0}"
    local pod out rc i

    for ((i=1; i<=tries; i++)); do
        pod="dr-http-check-$(date +%s)-$RANDOM"

        if ! $KUBECTL -n "$ns" run "$pod" \
            --restart=Never \
            --image="$CURL_IMAGE" \
            --command -- sh -c \
            "curl -fsS --max-time 20 '$url'" >/dev/null 2>&1; then
            out="could not create HTTP check pod"
            rc=1
        else
            rc=0
            if ! $KUBECTL -n "$ns" wait \
                --for=jsonpath='{.status.phase}'=Succeeded \
                "pod/$pod" --timeout=45s >/dev/null 2>&1; then
                rc=1
            fi

            out="$($KUBECTL -n "$ns" logs "$pod" 2>&1 || true)"
            $KUBECTL -n "$ns" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
        fi

        if (( rc == 0 )); then
            printf '%s' "$out"
            return 0
        fi

        if (( i < tries )); then
            sleep "$delay"
        fi
    done

    printf '%s' "$out"
    return 1
}

run_http_contains() {
    local ns="$1"
    local label="$2"
    local url="$3"
    local expect="$4"
    local out

    if ! out="$(run_http_raw "$ns" "$url" "$HTTP_RETRIES" "$HTTP_RETRY_DELAY")"; then
        fail "$label HTTP request failed: ${out:-no output}"
        return
    fi

    if [[ -n "$expect" && "$out" != *"$expect"* ]]; then
        fail "$label returned unexpected response: $out"
        return
    fi

    pass "$label"
}

echo
echo "===== APPLICATION HEALTH ====="

run_http_contains trilium \
    "Trilium web endpoint reachable" \
    "http://trilium-dr-validation:8080/" ""

run_http_contains vaultwarden \
    "Vaultwarden /alive reachable" \
    "http://vaultwarden-dr-validation/alive" ""

run_http_contains portainer \
    "Portainer /api/status reachable" \
    "http://portainer-dr-validation:9000/api/status" ""

GRAFANA_JSON="$(run_http_raw monitoring \
    "http://grafana-dr-validation:3000/api/health" \
    "$HTTP_RETRIES" "$HTTP_RETRY_DELAY" || true)"

if jq -e '.database=="ok"' >/dev/null 2>&1 <<< "$GRAFANA_JSON"; then
    pass "Grafana database health is OK"
else
    fail "Grafana database health check failed: ${GRAFANA_JSON:-no output}"
fi

run_http_contains monitoring \
    "Prometheus is Ready" \
    "http://prometheus-dr-validation:9090/-/ready" \
    "Prometheus Server is Ready"

run_http_contains monitoring \
    "Alertmanager is Ready" \
    "http://alertmanager-dr-validation:9093/-/ready" \
    "OK"

LOKI_READY="$(run_http_raw logging \
    "http://loki-dr-validation:3100/ready" \
    "$HTTP_RETRIES" "$HTTP_RETRY_DELAY" || true)"

if [[ "$LOKI_READY" == *"ready"* ]]; then
    pass "Loki is Ready"
else
    warn "Loki /ready did not return 200 after retries; continuing with restored-data query"
fi

echo
echo "===== RESTORED DATA CHECKS ====="

if $KUBECTL -n trilium exec trilium-dr-validation -- \
    sh -c 'test -s /home/node/trilium-data/document.db' >/dev/null 2>&1; then
    pass "Trilium restored document.db is present and non-empty"
else
    fail "Trilium restored document.db is missing or empty"
fi

if $KUBECTL -n vaultwarden exec vaultwarden-dr-validation -- \
    sh -c 'test -s /data/db.sqlite3' >/dev/null 2>&1; then
    pass "Vaultwarden restored db.sqlite3 is present and non-empty"
else
    fail "Vaultwarden restored db.sqlite3 is missing or empty"
fi

if $KUBECTL -n portainer exec portainer-dr-validation -- \
    sh -c 'test -s /data/portainer.db' >/dev/null 2>&1; then
    pass "Portainer restored portainer.db is present and non-empty"
else
    warn "Portainer portainer.db could not be verified from inside the container"
fi

# An instant query at "now" is not a valid DR historical-data test because
# the restored TSDB stops receiving samples at backup time.  Query a recent
# historical range instead.  Production backup policy is expected to keep
# recovery points comfortably inside this 36-hour window.
PROM_END="$(date -u +%s)"
PROM_START="$((PROM_END - 129600))"

PROM_JSON="$(run_http_raw monitoring \
    "http://prometheus-dr-validation:9090/api/v1/query_range?query=count%28up%29&start=${PROM_START}&end=${PROM_END}&step=300" \
    "$HTTP_RETRIES" "$HTTP_RETRY_DELAY" || true)"

if jq -e '
    .status=="success"
    and (.data.result | length > 0)
    and ([.data.result[].values[]?] | length > 0)
' >/dev/null 2>&1 <<< "$PROM_JSON"; then
    pass "Prometheus restored TSDB contains historical samples"
else
    fail "Prometheus restored TSDB historical range query returned no samples: ${PROM_JSON:-no output}"
fi

LOKI_JSON="$(run_http_raw logging \
    "http://loki-dr-validation:3100/loki/api/v1/label/namespace/values" \
    "$HTTP_RETRIES" "$HTTP_RETRY_DELAY" || true)"

if jq -e '.status=="success" and (.data | length > 0)' >/dev/null 2>&1 <<< "$LOKI_JSON"; then
    pass "Loki restored data exposes namespace labels"
else
    fail "Loki restored-data query returned no namespace labels: ${LOKI_JSON:-no output}"
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
    echo " DR APPLICATION VALIDATION FAILED"
    echo "============================================================"
    exit 1
fi

if (( WARN > 0 )); then
    echo "============================================================"
    echo " DR APPLICATION VALIDATION PASSED WITH WARNINGS"
    echo "============================================================"
    exit 2
fi

echo "============================================================"
echo " DR APPLICATION VALIDATION PASSED"
echo "============================================================"
exit 0
