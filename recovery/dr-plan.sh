#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFLIGHT="${PREFLIGHT:-$SCRIPT_DIR/dr-preflight.sh}"
INVENTORY="${INVENTORY:-$SCRIPT_DIR/dr-find-backups.sh}"
GENERATOR="${GENERATOR:-$SCRIPT_DIR/dr-generate-restore.sh}"
VALIDATOR="${VALIDATOR:-$SCRIPT_DIR/dr-validate-generated.sh}"

DR_HOST="${DR_HOST:-k3s-dr}"
DR_USER="${DR_USER:-jeff}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/tmp}"

OUTPUT="${OUTPUT:-$SCRIPT_DIR/generated-latest-restore.yaml}"
REMOTE_MANIFEST="$REMOTE_TMP_DIR/$(basename "$OUTPUT")"
REMOTE_VALIDATOR="$REMOTE_TMP_DIR/$(basename "$VALIDATOR")"

SSH="${SSH:-ssh}"
SCP="${SCP:-scp}"

usage() {
    cat <<'EOF'
Usage:
  dr-plan.sh [options]

Options:
  -o, --output FILE     Generated restore manifest path.
                        Default: recovery/generated-latest-restore.yaml
  --dr-host HOST        DR host/IP or SSH alias. Default: k3s-dr
  --dr-user USER        DR SSH user. Default: jeff
  -h, --help            Show this help.

Environment overrides:
  PREFLIGHT        Path to dr-preflight.sh
  INVENTORY        Path to dr-find-backups.sh
  GENERATOR        Path to dr-generate-restore.sh
  VALIDATOR        Path to dr-validate-generated.sh
  DR_HOST          DR host/IP
  DR_USER          DR SSH user
  REMOTE_TMP_DIR   Remote temporary directory. Default: /tmp
  OUTPUT           Generated restore manifest path
  SSH              SSH command. Default: ssh
  SCP              SCP command. Default: scp

Safety:
  This script performs planning only.
  It DOES NOT call dr-apply-restore.sh.
  It DOES NOT create Longhorn volumes.
  It DOES NOT create PVs, PVCs, pods, or services.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        -o|--output)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 2; }
            OUTPUT="$2"
            REMOTE_MANIFEST="$REMOTE_TMP_DIR/$(basename "$OUTPUT")"
            shift 2
            ;;
        --dr-host)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 2; }
            DR_HOST="$2"
            shift 2
            ;;
        --dr-user)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 2; }
            DR_USER="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for FILE in "$PREFLIGHT" "$INVENTORY" "$GENERATOR" "$VALIDATOR"; do
    if [[ ! -x "$FILE" ]]; then
        echo "ERROR: Required helper missing or not executable:" >&2
        echo "       $FILE" >&2
        exit 2
    fi
done

echo "============================================================"
echo " K3S HOMELAB DR PLAN"
echo "============================================================"
echo
echo "Date:        $(date)"
echo "DR target:   ${DR_USER}@${DR_HOST}"
echo "Output:      $OUTPUT"
echo

echo "===== 1. DR PREFLIGHT ====="

"$SCP" "$PREFLIGHT" "${DR_USER}@${DR_HOST}:${REMOTE_TMP_DIR}/"

"$SSH" -t "${DR_USER}@${DR_HOST}" \
    "sudo ${REMOTE_TMP_DIR}/$(basename "$PREFLIGHT")"

echo
echo "PASS: DR preflight completed"

echo
echo "===== 2. PRODUCTION BACKUP INVENTORY ====="

"$INVENTORY"

echo
echo "PASS: Backup inventory completed"

echo
echo "===== 3. GENERATE RESTORE MANIFEST ====="

mkdir -p "$(dirname "$OUTPUT")"

"$GENERATOR" --output "$OUTPUT"

echo
echo "PASS: Restore manifest generated"
echo "Manifest: $OUTPUT"

echo
echo "===== 4. COPY VALIDATION INPUT TO DR ====="

"$SCP" \
    "$VALIDATOR" \
    "$OUTPUT" \
    "${DR_USER}@${DR_HOST}:${REMOTE_TMP_DIR}/"

echo "PASS: Validator and generated manifest copied to DR host"

echo
echo "===== 5. VALIDATE GENERATED RESTORE MANIFEST ====="

"$SSH" -t "${DR_USER}@${DR_HOST}" \
    "sudo env KUBECTL=\"k3s kubectl\" \
     ${REMOTE_VALIDATOR} \
     ${REMOTE_MANIFEST}"

echo
echo "PASS: Generated restore manifest validated"

echo
echo "============================================================"
echo " DR PLAN COMPLETE"
echo "============================================================"
echo
echo "Generated manifest:"
echo "  $OUTPUT"
echo
echo "Next steps:"
echo "  1. Review the generated YAML manually."
echo "  2. If a real restore is intended, run dr-apply-restore.sh separately."
echo
echo "No restore resources were applied by dr-plan.sh."
