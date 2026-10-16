#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_FILE="${APPS_FILE:-$ROOT/recovery/apps.conf}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/k3s-dr}"
STATUS_FILE="$STATE_DIR/last-status"
DETAIL_FILE="$STATE_DIR/last-details.txt"
NOTIFY="${NOTIFY:-$ROOT/monitoring/dr-notify.sh}"
BACKUP_VERIFY="${BACKUP_VERIFY:-$ROOT/backup/verify-backup.sh}"
VELERO_VERIFY="${VELERO_VERIFY:-$ROOT/backup/verify-velero.sh}"
METRICS="${METRICS:-$ROOT/monitoring/dr-metrics.sh}"

WARN_BACKUP_AGE_HOURS="${WARN_BACKUP_AGE_HOURS:-24}"
CRIT_BACKUP_AGE_HOURS="${CRIT_BACKUP_AGE_HOURS:-30}"
WARN_APP_BACKUP_AGE_HOURS="${WARN_APP_BACKUP_AGE_HOURS:-24}"
CRIT_APP_BACKUP_AGE_HOURS="${CRIT_APP_BACKUP_AGE_HOURS:-30}"
WARN_VELERO_BACKUP_AGE_HOURS="${WARN_VELERO_BACKUP_AGE_HOURS:-24}"
CRIT_VELERO_BACKUP_AGE_HOURS="${CRIT_VELERO_BACKUP_AGE_HOURS:-30}"

mkdir -p "$STATE_DIR"
severity=0
messages=()
warnings=0
criticals=0
warn(){ (( severity < 1 )) && severity=1; warnings=$(( warnings + 1 )); messages+=("WARNING: $*"); }
crit(){ severity=2; criticals=$(( criticals + 1 )); messages+=("CRITICAL: $*"); }
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

velero_output=""
if velero_output="$(MAX_VELERO_BACKUP_AGE_HOURS="$CRIT_VELERO_BACKUP_AGE_HOURS" "$VELERO_VERIFY" 2>&1)"; then
  velero_age="$(sed -n 's/^==> Velero backup age: \([0-9][0-9]*\)h$/\1/p' <<<"$velero_output" | head -1)"
  if [[ "$velero_age" =~ ^[0-9]+$ ]]; then
    if (( velero_age >= CRIT_VELERO_BACKUP_AGE_HOURS )); then
      crit "Velero S3 backup is ${velero_age}h old"
    elif (( velero_age >= WARN_VELERO_BACKUP_AGE_HOURS )); then
      warn "Velero S3 backup is ${velero_age}h old"
    fi
  else
    crit "Velero S3 backup age could not be determined"
  fi
else
  crit "Velero S3 backup verification failed"
fi

backup_output=""
bundle_verified=0
if backup_output="$("$BACKUP_VERIFY" 2>&1)"; then
  bundle_verified=1
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

timers_enabled=()
timers_active=()
for unit in k3s-dr-backup.timer k3s-dr-verify.timer k3s-dr-monitor.timer \
            k3s-dr-restore-canary.timer k3s-dr-longhorn-restore-canary.timer \
            k3s-dr-smtp-test.timer; do
  enabled=1 active=1
  [[ "$(systemctl --user is-enabled "$unit" 2>/dev/null || true)" == "enabled" ]] || { enabled=0; warn "$unit is not enabled"; }
  [[ "$(systemctl --user is-active "$unit" 2>/dev/null || true)" == "active" ]] || { active=0; crit "$unit is not active"; }
  timers_enabled+=("k3s_dr_timer_enabled{timer=\"$unit\"} $enabled")
  timers_active+=("k3s_dr_timer_active{timer=\"$unit\"} $active")
done

for unit in k3s-dr-backup.service k3s-dr-verify.service \
            k3s-dr-restore-canary.service k3s-dr-longhorn-restore-canary.service; do
  [[ "$(systemctl --user is-failed "$unit" 2>/dev/null || true)" != "failed" ]] || crit "$unit is in failed state"
done

for current in "$ROOT"/recovery/state/*/current; do
  [[ -L "$current" ]] || continue
  app="$(basename "$(dirname "$current")")"
  dir="$(dirname "$current")/$(readlink "$current")"
  status="$(awk -F= '$1=="STATUS"{print $2}' "$dir/state.env" 2>/dev/null | tail -1)"
  case "$status" in ""|rolled_back|completed|cleaned) ;; *) warn "$app has active promotion state: $status" ;; esac
done

# A kept promotion leaves the app on its restore volume; that one is live.
while read -r v; do
  [[ -z "$v" ]] && continue
  [[ "$(kubectl get pv "$v" -o jsonpath='{.status.phase}' 2>/dev/null || true)" == Bound ]] && continue
  warn "Restore-test Longhorn volume still exists: $v"
done < <(kubectl -n longhorn-system get volumes.longhorn.io -o name 2>/dev/null | sed 's#^.*/##' | grep -E -- '-restore-test(-b)?$' || true)

if [[ -f "$APPS_FILE" ]]; then
  bjson="$(kubectl -n longhorn-system get backupvolumes.longhorn.io -o json 2>/dev/null || echo '{"items":[]}')"
  while IFS='|' read -r app ns pvc _; do
    [[ -z "$app" || "$app" == \#* ]] && continue
    vol="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
    [[ -n "$vol" ]] || { crit "$app PVC $ns/$pvc is missing or unbound"; continue; }
    last="$(printf '%s' "$bjson" | python3 -c '
import json,re,sys
vol=sys.argv[1]; d=json.load(sys.stdin); xs=[]
own=re.compile(re.escape(vol)+r"-[0-9a-f]{8}$")  # not APP-restore-test-b for APP-restore-test
for i in d.get("items",[]):
 n=i.get("metadata",{}).get("name",""); s=i.get("status",{})
 if own.match(n) or s.get("volumeName")==vol:
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

# Results for the Grafana DR dashboard. Pushing never changes the outcome.
bundle_created="$(sed -n 's/^==> Backup created: \([0-9][0-9]*\)$/\1/p' <<<"$backup_output" | head -1)"
read -r free_gib free_percent < <(sed -n 's/^==> Backup storage free: \([0-9][0-9]*\) GiB (\([0-9][0-9]*\)%)$/\1 \2/p' <<<"$backup_output" | head -1) || true
{
  echo "# TYPE k3s_dr_status gauge"
  echo "k3s_dr_status $severity"
  echo "# TYPE k3s_dr_problems gauge"
  echo "k3s_dr_problems{severity=\"warning\"} $warnings"
  echo "k3s_dr_problems{severity=\"critical\"} $criticals"
  echo "# TYPE k3s_dr_monitor_last_run_timestamp_seconds gauge"
  echo "k3s_dr_monitor_last_run_timestamp_seconds $now"
  echo "# TYPE k3s_dr_bundle_verified gauge"
  echo "k3s_dr_bundle_verified $bundle_verified"
  if [[ -n "$bundle_created" ]]; then
    echo "# TYPE k3s_dr_bundle_created_timestamp_seconds gauge"
    echo "k3s_dr_bundle_created_timestamp_seconds $bundle_created"
  fi
  if [[ -n "${free_gib:-}" && -n "${free_percent:-}" ]]; then
    echo "# TYPE k3s_dr_backup_storage_free_bytes gauge"
    echo "k3s_dr_backup_storage_free_bytes $(( free_gib * 1024 * 1024 * 1024 ))"
    echo "# TYPE k3s_dr_backup_storage_free_ratio gauge"
    echo "k3s_dr_backup_storage_free_ratio $(awk -v p="$free_percent" 'BEGIN { printf "%.2f", p / 100 }')"
  fi
  echo "# TYPE k3s_dr_longhorn_backup_target_available gauge"
  echo "k3s_dr_longhorn_backup_target_available $([[ "$lh" == "true" ]] && echo 1 || echo 0)"
  echo "# TYPE k3s_dr_timer_enabled gauge"
  printf '%s\n' "${timers_enabled[@]}"
  echo "# TYPE k3s_dr_timer_active gauge"
  printf '%s\n' "${timers_active[@]}"
} | "$METRICS" push k3s-dr-monitor.service || true
"$METRICS" unit k3s-dr-backup.service k3s-dr-verify.service \
  k3s-dr-restore-canary.service k3s-dr-longhorn-restore-canary.service \
  k3s-dr-smtp-test.service || true
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

notification_sent=true
if [[ "$current" != "$previous" ]]; then
  case "$current" in
    OK)
      if [[ "$previous" != "UNKNOWN" ]] &&
         ! "$NOTIFY" "[RECOVERED] K3s DR status is OK" "$DETAIL_FILE"; then
        notification_sent=false
      fi
      ;;
    WARNING)
      "$NOTIFY" "[WARNING] K3s DR needs attention" "$DETAIL_FILE" || notification_sent=false
      ;;
    CRITICAL)
      "$NOTIFY" "[CRITICAL] K3s DR failure detected" "$DETAIL_FILE" || notification_sent=false
      ;;
  esac
fi

cat "$DETAIL_FILE"
if [[ "$notification_sent" != true ]]; then
  echo "ERROR: notification delivery failed; state transition was not persisted" >&2
  exit 1
fi

printf '%s\n' "$current" >"$STATUS_FILE"
[[ "$current" != "CRITICAL" ]]
