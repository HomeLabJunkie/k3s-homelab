#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_FILE="${APPS_FILE:-$ROOT/recovery/apps.conf}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/k3s-dr}"
STATUS_FILE="$STATE_DIR/last-status"
DETAIL_FILE="$STATE_DIR/last-details.txt"
NOTIFY="${NOTIFY:-$ROOT/monitoring/dr-notify.sh}"
BACKUP_VERIFY="${BACKUP_VERIFY:-$ROOT/backup/verify-backup.sh}"

WARN_BACKUP_AGE_HOURS="${WARN_BACKUP_AGE_HOURS:-24}"
CRIT_BACKUP_AGE_HOURS="${CRIT_BACKUP_AGE_HOURS:-30}"
WARN_APP_BACKUP_AGE_HOURS="${WARN_APP_BACKUP_AGE_HOURS:-24}"
CRIT_APP_BACKUP_AGE_HOURS="${CRIT_APP_BACKUP_AGE_HOURS:-30}"

mkdir -p "$STATE_DIR"
severity=0
messages=()
warn(){ (( severity < 1 )) && severity=1; messages+=("WARNING: $*"); }
crit(){ severity=2; messages+=("CRITICAL: $*"); }
now="$(date +%s)"

if ! kubectl get --raw=/readyz >/dev/null 2>&1; then crit "Kubernetes API /readyz failed"; fi

while read -r node ready; do
  [[ -z "$node" ]] && continue
  [[ "$ready" == "True" ]] || crit "Node $node is not Ready"
done < <(kubectl get nodes -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for n in d.get("items",[]):
 r="Unknown"
 for c in n.get("status",{}).get("conditions",[]):
  if c.get("type")=="Ready": r=c.get("status","Unknown")
 print(n["metadata"]["name"], r)
' 2>/dev/null || true)

lh="$(kubectl -n longhorn-system get backuptarget default -o jsonpath='{.status.available}' 2>/dev/null || true)"
[[ "$lh" == "true" ]] || crit "Longhorn backup target is unavailable"

backup_output=""
if backup_output="$("$BACKUP_VERIFY" 2>&1)"; then
  bundle_age="$(sed -n 's/^==> Backup age: \([0-9][0-9]*\)h.*/\1/p' <<<"$backup_output" | head -1)"
  if [[ "$bundle_age" =~ ^[0-9]+$ ]]; then
    if (( bundle_age >= CRIT_BACKUP_AGE_HOURS )); then
      crit "Cluster recovery bundle is ${bundle_age}h old"
    elif (( bundle_age >= WARN_BACKUP_AGE_HOURS )); then
      warn "Cluster recovery bundle is ${bundle_age}h old"
    fi
  else
    crit "Cluster recovery bundle age could not be determined"
  fi
else
  bundle_age="$(sed -n 's/^==> Backup age: \([0-9][0-9]*\)h.*/\1/p' <<<"$backup_output" | head -1)"
  if [[ "$bundle_age" =~ ^[0-9]+$ ]]; then
    crit "Cluster recovery bundle verification failed at age ${bundle_age}h"
  else
    crit "Cluster recovery bundle verification failed"
  fi
fi

for unit in k3s-dr-backup.timer k3s-dr-verify.timer k3s-dr-monitor.timer; do
  [[ "$(systemctl --user is-enabled "$unit" 2>/dev/null || true)" == "enabled" ]] || warn "$unit is not enabled"
  [[ "$(systemctl --user is-active "$unit" 2>/dev/null || true)" == "active" ]] || crit "$unit is not active"
done

for unit in k3s-dr-backup.service k3s-dr-verify.service; do
  [[ "$(systemctl --user is-failed "$unit" 2>/dev/null || true)" != "failed" ]] || crit "$unit is in failed state"
done

for current in "$ROOT"/recovery/state/*/current; do
  [[ -L "$current" ]] || continue
  app="$(basename "$(dirname "$current")")"
  dir="$(dirname "$current")/$(readlink "$current")"
  status="$(awk -F= '$1=="STATUS"{print $2}' "$dir/state.env" 2>/dev/null | tail -1)"
  case "$status" in ""|rolled_back|completed|cleaned) ;; *) warn "$app has active promotion state: $status" ;; esac
done

while read -r v; do
  [[ -z "$v" ]] && continue
  warn "Restore-test Longhorn volume still exists: $v"
done < <(kubectl -n longhorn-system get volumes.longhorn.io -o name 2>/dev/null | sed 's#^.*/##' | grep -- '-restore-test$' || true)

if [[ -f "$APPS_FILE" ]]; then
  bjson="$(kubectl -n longhorn-system get backupvolumes.longhorn.io -o json 2>/dev/null || echo '{"items":[]}')"
  while IFS='|' read -r app ns pvc kind workload service ingress; do
    [[ -z "$app" || "$app" == \#* ]] && continue
    vol="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
    [[ -n "$vol" ]] || { crit "$app PVC $ns/$pvc is missing or unbound"; continue; }
    last="$(printf '%s' "$bjson" | python3 -c '
import json,sys
vol=sys.argv[1]; d=json.load(sys.stdin); xs=[]
for i in d.get("items",[]):
 n=i.get("metadata",{}).get("name",""); s=i.get("status",{})
 if n.startswith(vol+"-") or s.get("volumeName")==vol:
  t=s.get("lastBackupAt","")
  if t: xs.append(t)
print(max(xs) if xs else "")
' "$vol")"
    [[ -n "$last" ]] || { crit "$app has no Longhorn backup timestamp"; continue; }
    age=$(( (now - $(date -d "$last" +%s)) / 3600 ))
    if (( age >= CRIT_APP_BACKUP_AGE_HOURS )); then
      crit "$app Longhorn backup is ${age}h old"
    elif (( age >= WARN_APP_BACKUP_AGE_HOURS )); then
      warn "$app Longhorn backup is ${age}h old"
    fi
  done <"$APPS_FILE"
else
  crit "Missing $APPS_FILE"
fi

case "$severity" in 0) current="OK";; 1) current="WARNING";; 2) current="CRITICAL";; esac
previous="$(cat "$STATUS_FILE" 2>/dev/null || echo UNKNOWN)"

{
  echo "K3s disaster-recovery monitor"
  echo "Time: $(date -Iseconds)"
  echo "Host: $(hostname -s)"
  echo "Status: $current"
  echo
  if (( ${#messages[@]} == 0 )); then
    echo "All monitored DR checks passed."
  else
    printf '%s\n' "${messages[@]}"
  fi
} >"$DETAIL_FILE"

if [[ "$current" != "$previous" ]]; then
  case "$current" in
    OK)
      [[ "$previous" == "UNKNOWN" ]] || "$NOTIFY" "[RECOVERED] K3s DR status is OK" "$DETAIL_FILE" || true
      ;;
    WARNING) "$NOTIFY" "[WARNING] K3s DR needs attention" "$DETAIL_FILE" || true ;;
    CRITICAL) "$NOTIFY" "[CRITICAL] K3s DR failure detected" "$DETAIL_FILE" || true ;;
  esac
fi

printf '%s\n' "$current" >"$STATUS_FILE"
cat "$DETAIL_FILE"
[[ "$current" != "CRITICAL" ]]
