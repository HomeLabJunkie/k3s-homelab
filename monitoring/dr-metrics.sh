#!/usr/bin/env bash
# Pushes disaster-recovery results to the Pushgateway in the cluster, for the
# "Homelab - Disaster Recovery" Grafana dashboard. The DR timers run on the
# laptop, outside Prometheus's reach, so their results are pushed instead of
# scraped.
#
#   dr-metrics.sh unit UNIT...   push each service's last run, read from systemd
#   dr-metrics.sh push GROUP     push the metrics on stdin as unit=GROUP
#
# The systemd services call `unit %n` from ExecStopPost; the DR monitor calls
# both every morning, which also refills the Pushgateway after a restart.
#
# Pushes go through the Kubernetes API's service proxy with the current
# kubeconfig, so nothing is exposed outside the cluster. A failed push prints
# a warning and exits 0: metrics must never fail a backup.
set -Euo pipefail

PUSHGATEWAY_NAMESPACE="${PUSHGATEWAY_NAMESPACE:-monitoring}"
PUSHGATEWAY_SERVICE="${PUSHGATEWAY_SERVICE:-pushgateway}"
PUSH_JOB=k3s-dr

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# POST replaces only the metrics named in the body, within this one group, so
# a failed run's push leaves the last success time from an earlier run.
push() {
  local group="$1"
  local path="/api/v1/namespaces/${PUSHGATEWAY_NAMESPACE}/services/http:${PUSHGATEWAY_SERVICE}:9091/proxy/metrics/job/${PUSH_JOB}/unit/${group}"
  if ! kubectl create --raw "$path" -f - >/dev/null; then
    echo "WARNING: could not push DR metrics for ${group} to the Pushgateway" >&2
  fi
}

# A unit property as Unix seconds, or nothing if it has not happened since the
# user's systemd manager started.
unit_time() {
  local value
  value="$(systemctl --user show --timestamp=unix -p "$2" --value "$1" 2>/dev/null || true)"
  [[ "$value" == @* ]] && echo "${value#@}"
}

push_unit() {
  local unit="$1" result started exited ok
  started="$(unit_time "$unit" ExecMainStartTimestamp)"
  exited="$(unit_time "$unit" ExecMainExitTimestamp)"
  if [[ -z "$started" || -z "$exited" ]]; then
    echo "No finished run of ${unit} since login; nothing to push."
    return 0
  fi
  # In ExecStopPost the unit's own Result is not final yet; systemd passes it
  # in SERVICE_RESULT instead.
  if [[ -n "${SERVICE_RESULT:-}" && "${DR_METRICS_SINGLE_UNIT:-}" == "$unit" ]]; then
    result="$SERVICE_RESULT"
  else
    result="$(systemctl --user show -p Result --value "$unit" 2>/dev/null || true)"
  fi
  ok=0
  [[ "$result" == success ]] && ok=1

  {
    echo "# TYPE k3s_dr_job_last_run_timestamp_seconds gauge"
    echo "k3s_dr_job_last_run_timestamp_seconds ${exited}"
    echo "# TYPE k3s_dr_job_last_duration_seconds gauge"
    echo "k3s_dr_job_last_duration_seconds $(( exited - started ))"
    echo "# TYPE k3s_dr_job_last_result gauge"
    echo "k3s_dr_job_last_result ${ok}"
    if (( ok == 1 )); then
      echo "# TYPE k3s_dr_job_last_success_timestamp_seconds gauge"
      echo "k3s_dr_job_last_success_timestamp_seconds ${exited}"
    fi
  } | push "$unit"
}

case "${1:-}" in
  unit)
    shift
    (( $# > 0 )) || { usage >&2; exit 2; }
    (( $# == 1 )) && DR_METRICS_SINGLE_UNIT="$1"
    for unit in "$@"; do
      push_unit "$unit"
    done
    ;;
  push)
    [[ -n "${2:-}" ]] || { usage >&2; exit 2; }
    push "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
exit 0
