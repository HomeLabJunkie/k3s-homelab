#!/usr/bin/env bash
set -Eeuo pipefail

KUBECTL="${KUBECTL:-kubectl}"
LONGHORN_NS="${LONGHORN_NS:-longhorn-system}"
DR_NODE="${DR_NODE:-k3s-dr-test}"
VALIDATOR="${VALIDATOR:-}"
POLL_SECONDS="${POLL_SECONDS:-10}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-3600}"
API_GRACE_SECONDS="${API_GRACE_SECONDS:-180}"
MANIFEST=""

usage() {
cat <<'EOF'
Usage:
  dr-apply-restore.sh --manifest FILE

Environment:
  KUBECTL           Default: kubectl
  LONGHORN_NS       Default: longhorn-system
  DR_NODE           Default: k3s-dr-test
  VALIDATOR         Path to dr-validate-generated.sh
  POLL_SECONDS      Default: 10
  TIMEOUT_SECONDS   Per-volume restore timeout, default: 3600
  API_GRACE_SECONDS How long to tolerate transient API unavailability, default: 180

Safety:
  - validates the manifest before apply
  - resumes matching existing restore volumes
  - skips matching completed restore volumes
  - aborts on mismatched existing volumes
  - restores new volumes sequentially
  - tolerates transient API outages during heavy restores
  - requires typing RESTORE exactly
  - does not create PVs/PVCs or start applications
EOF
}

while (( $# )); do
  case "$1" in
    -m|--manifest) MANIFEST="${2:?missing manifest}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

[[ -n "$MANIFEST" && -f "$MANIFEST" ]] || { echo "ERROR: valid --manifest required" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "$VALIDATOR" ]] || VALIDATOR="$SCRIPT_DIR/dr-validate-generated.sh"
[[ -x "$VALIDATOR" ]] || { echo "ERROR: validator missing: $VALIDATOR" >&2; exit 2; }

api_ready(){ $KUBECTL get --raw='/readyz' >/dev/null 2>&1; }
vol_json(){ $KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$1" -o json 2>/dev/null; }
vol_exists(){ $KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "$1" >/dev/null 2>&1; }

wait_api_grace() {
  local start now elapsed
  start="$(date +%s)"

  while ! api_ready; do
    now="$(date +%s)"
    elapsed=$((now - start))

    if (( elapsed >= API_GRACE_SECONDS )); then
      echo "ERROR: Kubernetes API remained unavailable for ${API_GRACE_SECONDS}s." >&2
      return 1
    fi

    echo "WARN: Kubernetes API unavailable; retrying in ${POLL_SECONDS}s (${elapsed}s/${API_GRACE_SECONDS}s)"
    sleep "$POLL_SECONDS"
  done

  return 0
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "============================================================"
echo " K3S HOMELAB DR SEQUENTIAL LONGHORN RESTORE"
echo "============================================================"
echo "Manifest: $MANIFEST"
echo "DR node:  $DR_NODE"
echo

wait_api_grace || exit 1

"$VALIDATOR" "$MANIFEST" || true

awk -v dir="$TMPDIR" '
BEGIN {n=1; f=sprintf("%s/doc-%03d.yaml",dir,n)}
/^---[[:space:]]*$/ {n++; f=sprintf("%s/doc-%03d.yaml",dir,n); next}
{print >> f}
' "$MANIFEST"

mapfile -t DOCS < <(find "$TMPDIR" -maxdepth 1 -type f -name 'doc-*.yaml' -size +0c | sort)
(( ${#DOCS[@]} > 0 )) || { echo "ERROR: no restore docs" >&2; exit 1; }

declare -a NAMES URLS SIZES ACTIONS
TOTAL_BYTES=0

for DOC in "${DOCS[@]}"; do
  NAME="$(awk '$0=="metadata:"{m=1;next} m&&$1=="name:"{print $2;exit}' "$DOC")"
  URL="$(sed -n 's/^  fromBackup: "\(.*\)"$/\1/p' "$DOC" | head -1)"
  SIZE="$(sed -n 's/^  size: "\([0-9][0-9]*\)"$/\1/p' "$DOC" | head -1)"
  [[ -n "$NAME" && -n "$URL" && "$SIZE" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: malformed doc $DOC" >&2; exit 1; }

  ACTION="CREATE"
  if vol_exists "$NAME"; then
    J="$(vol_json "$NAME")"
    ACT_URL="$(jq -r '.spec.fromBackup // ""' <<<"$J")"
    ACT_SIZE="$(jq -r '.spec.size // ""' <<<"$J")"

    [[ "$ACT_URL" == "$URL" && "$ACT_SIZE" == "$SIZE" ]] || {
      echo "ERROR: existing volume $NAME does not match manifest" >&2
      exit 1
    }

    STATE="$(jq -r '.status.state // "unknown"' <<<"$J")"
    RR="$(jq -r '.status.restoreRequired // false' <<<"$J")"
    NODE="$(jq -r '.status.currentNodeID // ""' <<<"$J")"

    if [[ "$STATE" == "detached" && "$RR" == "false" && -z "$NODE" ]]; then
      ACTION="SKIP-COMPLETE"
    else
      ACTION="RESUME"
    fi
  fi

  NAMES+=("$NAME")
  URLS+=("$URL")
  SIZES+=("$SIZE")
  ACTIONS+=("$ACTION")
  TOTAL_BYTES=$((TOTAL_BYTES + SIZE))
done

echo "===== RESTORE PLAN ====="
for i in "${!NAMES[@]}"; do
  printf '%d. %-38s %s\n' "$((i+1))" "${NAMES[$i]}" "${ACTIONS[$i]}"
done

TOTAL_GIB="$(awk -v B="$TOTAL_BYTES" 'BEGIN{printf "%.1f",B/1073741824}')"
echo "Total capacity: ${TOTAL_GIB} GiB"
echo
printf 'Type RESTORE exactly to continue: '
read -r CONFIRM
[[ "$CONFIRM" == "RESTORE" ]] || { echo "Confirmation not received. Nothing new was applied."; exit 3; }

wait_restore() {
  local NAME="$1" START NOW ELAPSED J STATE ROB RR NODE SSTAT SREASON SMSG STABLE=0
  START="$(date +%s)"

  while true; do
    NOW="$(date +%s)"
    ELAPSED=$((NOW-START))
    (( ELAPSED <= TIMEOUT_SECONDS )) || { echo "ERROR: timeout restoring $NAME" >&2; return 1; }

    if ! api_ready; then
      echo "WARN: API readiness failed during $NAME; entering grace period."
      wait_api_grace || return 1
    fi

    J="$(vol_json "$NAME" || true)"
    if [[ -z "$J" ]]; then
      echo "WARN: Could not read $NAME immediately; retrying after ${POLL_SECONDS}s."
      sleep "$POLL_SECONDS"
      continue
    fi

    STATE="$(jq -r '.status.state // "unknown"' <<<"$J")"
    ROB="$(jq -r '.status.robustness // "unknown"' <<<"$J")"
    RR="$(jq -r '.status.restoreRequired // false' <<<"$J")"
    NODE="$(jq -r '.status.currentNodeID // ""' <<<"$J")"
    SSTAT="$(jq -r '[.status.conditions[]? | select(.type=="Scheduled") | .status][0] // ""' <<<"$J")"
    SREASON="$(jq -r '[.status.conditions[]? | select(.type=="Scheduled") | .reason][0] // ""' <<<"$J")"
    SMSG="$(jq -r '[.status.conditions[]? | select(.type=="Scheduled") | .message][0] // ""' <<<"$J")"

    printf '  elapsed=%4ss state=%-10s robustness=%-10s restoreRequired=%-5s node=%s\n' \
      "$ELAPSED" "$STATE" "$ROB" "$RR" "${NODE:--}"

    [[ "$ROB" != "faulted" ]] || { echo "ERROR: volume faulted: $NAME" >&2; return 1; }

    if [[ "$SSTAT" == "False" ]]; then
      echo "ERROR: volume unschedulable: reason=${SREASON:-unknown} message=${SMSG:-none}" >&2
      return 1
    fi

    if [[ "$RR" == "false" && "$STATE" == "detached" && -z "$NODE" ]]; then
      STABLE=$((STABLE+1))
    else
      STABLE=0
    fi

    (( STABLE >= 2 )) && { echo "PASS: Restore completed: $NAME"; return 0; }
    sleep "$POLL_SECONDS"
  done
}

echo
echo "===== SEQUENTIAL RESTORE / RESUME ====="

DONE=0
for i in "${!DOCS[@]}"; do
  NAME="${NAMES[$i]}"
  ACTION="${ACTIONS[$i]}"

  echo
  echo "------------------------------------------------------------"
  echo " Restore $((i+1))/${#DOCS[@]}: $NAME"
  echo " Action: $ACTION"
  echo "------------------------------------------------------------"

  case "$ACTION" in
    SKIP-COMPLETE)
      echo "PASS: Already restored and complete: $NAME"
      DONE=$((DONE+1))
      continue
      ;;
    RESUME)
      echo "Monitoring existing matching restore volume..."
      ;;
    CREATE)
      wait_api_grace || exit 1
      echo "Applying Longhorn volume..."
      $KUBECTL apply -f "${DOCS[$i]}"
      ;;
  esac

  wait_restore "$NAME"
  DONE=$((DONE+1))

  if (( i+1 < ${#DOCS[@]} )); then
    echo "Cooling down for ${POLL_SECONDS}s before next restore..."
    sleep "$POLL_SECONDS"
  fi
done

echo
echo "============================================================"
echo " DR SEQUENTIAL RESTORE COMPLETE"
echo "============================================================"
echo "Restored volumes: $DONE/${#NAMES[@]}"
echo "Total capacity:   ${TOTAL_GIB} GiB"
echo

$KUBECTL -n "$LONGHORN_NS" get volumes.longhorn.io "${NAMES[@]}" \
  -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,RESTORE:.status.restoreRequired,SIZE:.spec.size'
