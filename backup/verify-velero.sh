#!/usr/bin/env bash
set -Eeuo pipefail

SCHEDULE="${VELERO_SCHEDULE:-protected-apps-daily}"
MAX_AGE_HOURS="${MAX_VELERO_BACKUP_AGE_HOURS:-30}"
NAMESPACE="${VELERO_NAMESPACE:-velero}"

location="$(kubectl -n "$NAMESPACE" get backupstoragelocation rustfs -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$location" == "Available" ]] || {
  echo "ERROR: Velero RustFS backup location is not available" >&2
  exit 1
}

schedule_status="$(kubectl -n "$NAMESPACE" get schedules.velero.io "$SCHEDULE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$schedule_status" == "Enabled" ]] || {
  echo "ERROR: Velero schedule $SCHEDULE is not enabled" >&2
  exit 1
}

backup_json="$(kubectl -n "$NAMESPACE" get backups.velero.io -l "velero.io/schedule-name=$SCHEDULE" -o json)"
latest="$({ jq -r '
  [.items[] | select(.status.phase == "Completed")]
  | sort_by(.status.completionTimestamp // "")
  | last // empty
' <<<"$backup_json"; })"
[[ -n "$latest" ]] || {
  echo "ERROR: no completed Velero backup exists for schedule $SCHEDULE" >&2
  exit 1
}

name="$(jq -r '.metadata.name' <<<"$latest")"
completed="$(jq -r '.status.completionTimestamp' <<<"$latest")"
completed_epoch="$(date -d "$completed" +%s)"
age_hours=$(( ($(date +%s) - completed_epoch) / 3600 ))
(( age_hours < 0 )) && age_hours=0

agents="$(kubectl -n "$NAMESPACE" get daemonset node-agent -o json)"
desired="$(jq -r '.status.desiredNumberScheduled // 0' <<<"$agents")"
ready="$(jq -r '.status.numberReady // 0' <<<"$agents")"
[[ "$desired" =~ ^[0-9]+$ && "$desired" -gt 0 && "$ready" == "$desired" ]] || {
  echo "ERROR: Velero node agents are not all ready (${ready}/${desired})" >&2
  exit 1
}

echo "==> Latest Velero backup: $name"
echo "==> Velero backup age: ${age_hours}h"
echo "==> Velero node agents: ${ready}/${desired} Ready"

(( age_hours <= MAX_AGE_HOURS )) || {
  echo "ERROR: Velero backup is ${age_hours}h old (max ${MAX_AGE_HOURS}h)" >&2
  exit 1
}

echo "VELERO BACKUP VERIFICATION PASSED"
