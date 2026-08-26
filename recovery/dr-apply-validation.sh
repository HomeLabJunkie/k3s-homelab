#!/usr/bin/env bash
set -Eeuo pipefail

KUBECTL="${KUBECTL:-k3s kubectl}"

usage() {
    cat <<'EOF'
Usage:
  dr-apply-validation.sh FILE

Purpose:
  Safely server-side dry-run and then apply a generated DR validation manifest.

Safety:
  - Requires an explicit manifest file.
  - Performs kubectl apply --dry-run=server first.
  - Stops if the dry run fails.
  - Applies only the supplied validation manifest.
  - Does not restore Longhorn volumes.
  - Does not create PV/PVC bindings.
  - Does not perform cleanup.
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

MANIFEST="$1"

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Validation manifest not found: $MANIFEST" >&2
    exit 2
fi

echo "============================================================"
echo " K3S HOMELAB DR VALIDATION WORKLOAD APPLY"
echo "============================================================"
echo
echo "Manifest: $MANIFEST"
echo

echo "===== 1. KUBERNETES API ====="
if ! $KUBECTL get --raw='/readyz' >/dev/null 2>&1; then
    echo "ERROR: Kubernetes API is not ready." >&2
    exit 1
fi
echo "PASS: Kubernetes API ready"

echo
echo "===== 2. SERVER-SIDE DRY RUN ====="
$KUBECTL apply \
    --dry-run=server \
    -f "$MANIFEST"

echo "PASS: Validation manifest server-side dry run"

echo
echo "===== 3. APPLY VALIDATION WORKLOADS ====="
$KUBECTL apply \
    -f "$MANIFEST"

echo
echo "============================================================"
echo " VALIDATION WORKLOADS APPLIED"
echo "============================================================"
