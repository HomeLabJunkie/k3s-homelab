#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(basename "$ROOT_DIR")" == "backup" || "$(basename "$ROOT_DIR")" == "recovery" ]]; then
  ROOT_DIR="$(dirname "$ROOT_DIR")"
fi
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi


NAS="${NAS:-${UNRAID_IP:-192.0.2.9}}"
EXPORT="${EXPORT:-${CLUSTER_BACKUP_EXPORT:-/mnt/user/K3S-Backup}}"
MOUNT="${MOUNT:-/mnt/k3s-restore}"
DEST="${DEST:-$HOME/k3s-restored}"
REPO="${REPO:-$ROOT_DIR}"
APPS_FILE="${APPS_FILE:-$REPO/recovery/apps.conf}"
STATE_ROOT="${STATE_ROOT:-$REPO/recovery/state}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-3600}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"

MODE="${1:---preflight}"
APP_NAME="${2:-}"

MOUNTED_BY_SCRIPT=0

cleanup() {
  local rc=$?

  cd / || true

  if [[ "$MOUNTED_BY_SCRIPT" == "1" ]] &&
     mountpoint -q "$MOUNT" 2>/dev/null; then
    sudo umount "$MOUNT" || true
  fi

  return "$rc"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  restore.sh --preflight
  restore.sh --restore-repo
  restore.sh --list-longhorn
  restore.sh --show-etcd
  restore.sh --show-manifest
  restore.sh --list-apps
  restore.sh --inspect-app APP
  restore.sh --restore-app APP
  restore.sh --cleanup-test APP
  restore.sh --promote-app APP --confirm
  restore.sh --rollback-app APP --confirm
  restore.sh --promotion-status APP
  restore.sh --plan APP
  restore.sh --health-check APP
  restore.sh --archive-state APP

--restore-app is non-destructive:
  * finds the live PVC and Longhorn volume
  * finds the latest completed Longhorn backup for that volume
  * restores it into APP-restore-test
  * creates a temporary PV/PVC
  * mounts it read-only in APP-restore-inspect
  * leaves the live workload and PVC unchanged

Promotion safety:
  * Deployment and single-replica StatefulSet workloads are supported
  * --confirm is mandatory
  * original workload/PVC metadata is saved under recovery/state/
  * rollback retains the restored PVC/volume until cleanup
EOF
}

mount_backup() {
  sudo mkdir -p "$MOUNT"

  if ! mountpoint -q "$MOUNT"; then
    sudo mount -t nfs4 -o vers=4.2,proto=tcp "${NAS}:${EXPORT}" "$MOUNT"
    MOUNTED_BY_SCRIPT=1
  fi

  mountpoint -q "$MOUNT" || {
    echo "ERROR: recovery backup target is not mounted: $MOUNT" >&2
    return 1
  }
}

latest_bundle() {
  local link="${MOUNT}/cluster/latest"
  local raw=""
  local candidate=""

  if [[ -L "$link" ]]; then
    raw="$(readlink "$link" || true)"
    if [[ "$raw" = /* ]]; then
      case "$raw" in
        */cluster/*) candidate="${MOUNT}/cluster/${raw#*/cluster/}" ;;
      esac
    elif [[ -n "$raw" ]]; then
      candidate="${MOUNT}/cluster/${raw}"
    fi
  fi

  if [[ -n "$candidate" && -d "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  find "${MOUNT}/cluster" \
    -mindepth 2 -maxdepth 2 -type d \
    -name '20????????-??????' \
    -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    head -1 |
    cut -d' ' -f2-
}

verify_bundle() {
  local latest="$1"
  [[ -d "$latest" ]] || { echo "ERROR: recovery bundle missing: $latest"; return 1; }
  [[ -s "$latest/SHA256SUMS" ]] || { echo "ERROR: SHA256SUMS missing"; return 1; }
  [[ -s "$latest/repo/k3s-repository.tar.gz" ]] || { echo "ERROR: repository archive missing"; return 1; }

  (
    cd "$latest"
    sudo sha256sum -c SHA256SUMS >/dev/null
  )
  sudo tar -tzf "$latest/repo/k3s-repository.tar.gz" >/dev/null
}

app_line() {
  local app="$1"
  awk -F'|' -v app="$app" '
    $0 !~ /^#/ && NF >= 5 && $1 == app { print; found=1; exit }
    END { if (!found) exit 1 }
  ' "$APPS_FILE"
}

app_field() {
  local app="$1"
  local field="$2"
  local line
  line="$(app_line "$app")" || return 1
  awk -F'|' -v n="$field" '{print $n}' <<<"$line"
}

list_apps() {
  printf "%-12s %-14s %-55s %-12s %s\n" "APP" "NAMESPACE" "PVC" "KIND" "WORKLOAD"
  printf "%-12s %-14s %-55s %-12s %s\n" "------------" "--------------" "-------------------------------------------------------" "------------" "------------------------------"
  awk -F'|' '
    $0 !~ /^#/ && NF >= 5 {
      printf "%-12s %-14s %-55s %-12s %s\n", $1,$2,$3,$4,$5
    }
  ' "$APPS_FILE"
}

inspect_app() {
  local app="$1"
  local ns pvc kind workload service ingress volume

  ns="$(app_field "$app" 2)"
  pvc="$(app_field "$app" 3)"
  kind="$(app_field "$app" 4)"
  workload="$(app_field "$app" 5)"
  service="$(app_field "$app" 6)"
  ingress="$(app_field "$app" 7)"

  echo "==> App: $app"
  echo "    namespace: $ns"
  echo "    pvc:       $pvc"
  echo "    workload:  $kind/$workload"
  [[ -n "$service" ]] && echo "    service:   $service"
  [[ -n "$ingress" ]] && echo "    ingress:   $ingress"

  echo
  echo "==> PVC:"
  kubectl -n "$ns" get pvc "$pvc" -o wide

  volume="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')"
  echo
  echo "==> Longhorn volume:"
  kubectl -n longhorn-system get volume "$volume"

  echo
  echo "==> Latest backup:"
  latest_backup_for_volume "$volume"
}

latest_backup_for_volume() {
  local volume="$1"

  kubectl -n longhorn-system get backupvolumes.longhorn.io -o json |
  python3 -c '
import json,sys
vol=sys.argv[1]
data=json.load(sys.stdin)
matches=[]
for item in data.get("items",[]):
    name=item["metadata"]["name"]
    st=item.get("status",{})
    if name.startswith(vol+"-") or st.get("volumeName")==vol:
        lb=st.get("lastBackupName","")
        lat=st.get("lastBackupAt","")
        if lb:
            matches.append((lat,lb,name))
if not matches:
    raise SystemExit(1)
matches.sort(reverse=True)
lat,lb,name=matches[0]
print(f"{lb} {lat} {name}")
' "$volume"
}


plan_app() {
  local app="$1"
  app_line "$app" >/dev/null || { echo "ERROR: unknown app: $app"; return 1; }

  local ns pvc kind workload service ingress volume backup_line
  ns="$(app_field "$app" 2)"
  pvc="$(app_field "$app" 3)"
  kind="$(app_field "$app" 4)"
  workload="$(app_field "$app" 5)"
  service="$(app_field "$app" 6)"
  ingress="$(app_field "$app" 7)"
  volume="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')"
  backup_line="$(latest_backup_for_volume "$volume" 2>/dev/null || true)"

  echo "==> DR PLAN: $app"
  echo "    namespace:      $ns"
  echo "    workload:       $kind/$workload"
  echo "    live PVC:       $pvc"
  echo "    live volume:    $volume"
  echo "    latest backup:  ${backup_line:-NONE}"
  echo "    test volume:    ${app}-restore-test"
  echo "    test PVC:       ${app}-restore-test"
  echo "    inspect pod:    ${app}-restore-inspect"
  [[ -n "$service" ]] && echo "    service:         $service"
  [[ -n "$ingress" ]] && echo "    ingress:         $ingress"

  echo
  case "$kind" in
    deployment)
      cat <<EOF
Promotion plan:
  1. Require a completed non-destructive restore test.
  2. Save Deployment/PVC state under recovery/state/${app}/.
  3. Delete inspection pod and wait for restored volume to detach.
  4. Scale Deployment to 0.
  5. Patch claimName ${pvc} -> ${app}-restore-test.
  6. Restore replica count and wait for rollout.
  7. Run health checks.
Rollback reverses the claimName patch.
EOF
      ;;
    statefulset)
      local parent
      parent="$(operator_parent_for_app "$app" 2>/dev/null || true)"
      cat <<EOF
Promotion plan:
  1. Require a completed non-destructive restore test.
  2. Save StatefulSet/PVC/PV/Longhorn state under recovery/state/${app}/.
  3. Remove inspection objects but preserve ${app}-restore-test.
  4. Scale workload to 0.
EOF
      if [[ -n "$parent" ]]; then
        echo "     Scaling is performed through Operator resource ${parent%%|*}/${parent##*|}."
      else
        echo "     Scaling is performed directly on StatefulSet/$workload."
      fi
      cat <<EOF
  5. Change original PV reclaim policy to Retain.
  6. Rebind the generated PVC name to a PV backed by ${app}-restore-test.
  7. Restore replicas and wait for rollout.
  8. Run health checks.
Rollback rebinds the generated PVC to the original retained PV.
EOF
      ;;
  esac
}

http_health_check() {
  local app="$1" ns="$2"
  local url=""
  case "$app" in
    trilium)      url="http://trilium:8080/" ;;
    vaultwarden)  url="http://vaultwarden/alive" ;;
    portainer)    url="http://portainer:9000/api/status" ;;
    grafana)      url="http://monitoring-grafana/api/health" ;;
    loki)         url="http://loki-gateway/loki/api/v1/status/buildinfo" ;;
    prometheus)   url="http://monitoring-kube-prometheus-prometheus:9090/-/ready" ;;
    alertmanager) url="http://monitoring-kube-prometheus-alertmanager:9093/-/ready" ;;
    *) return 0 ;;
  esac

  local pod="dr-health-${app}-$$"
  echo "==> HTTP health check: $url"

  kubectl -n "$ns" run "$pod" \
    --restart=Never \
    --image=curlimages/curl:latest \
    --command -- sh -c "curl --connect-timeout 10 --max-time 30 -fsS '$url'" >/dev/null

  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  local phase=""
  while (( $(date +%s) < deadline )); do
    phase="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 2
  done

  kubectl -n "$ns" logs "$pod" 2>/dev/null || true
  kubectl -n "$ns" delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  if [[ "$phase" != "Succeeded" ]]; then
    echo "WARNING: application HTTP health check failed for $app (phase=${phase:-unknown})."
    return 1
  fi
}

health_check_app() {
  local app="$1"
  app_line "$app" >/dev/null || { echo "ERROR: unknown app: $app"; return 1; }

  local ns kind workload service ingress
  ns="$(app_field "$app" 2)"
  kind="$(app_field "$app" 4)"
  workload="$(app_field "$app" 5)"
  service="$(app_field "$app" 6)"
  ingress="$(app_field "$app" 7)"

  echo "==> Health check: $app"

  case "$kind" in
    deployment)
      kubectl -n "$ns" rollout status "deployment/$workload" --timeout="${ROLLOUT_TIMEOUT}s"
      ;;
    statefulset)
      kubectl -n "$ns" rollout status "statefulset/$workload" --timeout="${ROLLOUT_TIMEOUT}s"
      ;;
  esac

  [[ -z "$service" ]] || verify_service_endpoints "$ns" "$service"

  if [[ -n "$ingress" ]]; then
    kubectl -n "$ns" get ingress "$ingress" >/dev/null
  fi

  http_health_check "$app" "$ns" || {
    echo "WARNING: Kubernetes readiness passed but the optional HTTP probe failed."
    return 2
  }

  echo "==> Health check passed: $app"
}

archive_state() {
  local app="$1"
  local current="${STATE_ROOT}/${app}/current"
  [[ -L "$current" ]] || {
    echo "No current promotion state to archive for $app."
    return 0
  }

  local raw dir status archive
  raw="$(readlink "$current")"
  dir="${STATE_ROOT}/${app}/${raw}"
  [[ -f "$dir/state.env" ]] || {
    echo "ERROR: state file missing: $dir/state.env"
    return 1
  }

  status="$(awk -F= '$1=="STATUS"{print $2}' "$dir/state.env" | tail -1)"
  case "$status" in
    rolled_back|completed|cleaned) ;;
    *)
      echo "ERROR: refusing to archive active state with STATUS=$status"
      return 1
      ;;
  esac

  archive="${STATE_ROOT}/${app}/archive"
  mkdir -p "$archive"
  mv "$dir" "$archive/$raw"
  rm -f "$current"
  echo "Archived $app state to $archive/$raw"
}

wait_restore_complete() {
  local restore_vol="$1"
  local deadline=$(( $(date +%s) + RESTORE_TIMEOUT ))

  while true; do
    local state req condition
    state="$(kubectl -n longhorn-system get volume "$restore_vol" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    req="$(kubectl -n longhorn-system get volume "$restore_vol" -o jsonpath='{.status.restoreRequired}' 2>/dev/null || true)"
    condition="$(kubectl -n longhorn-system get volume "$restore_vol" -o jsonpath='{range .status.conditions[?(@.type=="Restore")]}{.status}{": "}{.message}{end}' 2>/dev/null || true)"
    echo "  state=$state restoreRequired=$req${condition:+ restoreCondition=[$condition]}"

    if [[ "$state" == "detached" && "$req" == "false" ]]; then
      return 0
    fi

    if (( $(date +%s) >= deadline )); then
      echo "ERROR: Longhorn restore timed out after ${RESTORE_TIMEOUT}s."
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

restore_app() {
  local app="$1"
  local ns pvc volume backup_line backup backup_url restore_vol pv pod cap size_bytes replicas frontend access_mode

  app_line "$app" >/dev/null || { echo "ERROR: unknown app: $app"; exit 1; }

  ns="$(app_field "$app" 2)"
  pvc="$(app_field "$app" 3)"
  volume="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')"

  backup_line="$(latest_backup_for_volume "$volume")" || {
    echo "ERROR: no completed Longhorn backup found for $ns/$pvc ($volume)"
    exit 1
  }

  backup="$(awk '{print $1}' <<<"$backup_line")"
  backup_url="$(kubectl -n longhorn-system get backup "$backup" -o jsonpath='{.status.url}')"

  restore_vol="${app}-restore-test"
  pv="${restore_vol}-pv"
  pod="${app}-restore-inspect"
  cap="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.resources.requests.storage}')"
  size_bytes="$(kubectl -n longhorn-system get volume "$volume" -o jsonpath='{.spec.size}')"
  replicas="$(kubectl -n longhorn-system get volume "$volume" -o jsonpath='{.spec.numberOfReplicas}')"
  frontend="$(kubectl -n longhorn-system get volume "$volume" -o jsonpath='{.spec.frontend}')"
  access_mode="$(kubectl -n longhorn-system get volume "$volume" -o jsonpath='{.spec.accessMode}')"

  [[ -n "$frontend" ]] || frontend="blockdev"
  [[ -n "$access_mode" ]] || access_mode="rwo"

  [[ "$size_bytes" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Longhorn volume size is not a byte integer: $size_bytes"
    exit 1
  }

  [[ "$replicas" =~ ^[0-9]+$ ]] || replicas=3

  echo "==> App:      $app"
  echo "    PVC:      $ns/$pvc"
  echo "    volume:   $volume"
  echo "    backup:   $backup"
  echo "    restore:  $restore_vol"
  echo "    size:     $size_bytes bytes"
  echo "    replicas: $replicas"
  echo "    frontend: $frontend"
  echo "    access:   $access_mode"

  if kubectl -n "$ns" get pod "$pod" >/dev/null 2>&1 &&
     [[ "$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]]; then
    echo "==> Existing inspection pod is already Ready; treating restore as resumable."
    kubectl -n "$ns" logs "$pod" || true
    return 0
  fi

  if kubectl -n longhorn-system get volume "$restore_vol" >/dev/null 2>&1; then
    echo "==> Existing Longhorn restore volume found; resuming instead of recreating it."
  else
    cat <<EOF | kubectl apply -f -
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: ${restore_vol}
  namespace: longhorn-system
spec:
  fromBackup: "${backup_url}"
  numberOfReplicas: ${replicas}
  size: "${size_bytes}"
  frontend: "${frontend}"
  accessMode: "${access_mode}"
EOF
  fi

  echo "==> Waiting for Longhorn restore (timeout=${RESTORE_TIMEOUT}s)..."
  wait_restore_complete "$restore_vol"

  echo "==> Creating inspection PV/PVC and read-only pod..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${pv}
spec:
  capacity:
    storage: ${cap}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    volumeHandle: ${restore_vol}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${restore_vol}
  namespace: ${ns}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${cap}
  volumeName: ${pv}
  storageClassName: longhorn
---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${ns}
spec:
  restartPolicy: Never
  containers:
    - name: inspect
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          echo "=== RESTORED FILES ==="
          ls -lah /restore
          echo
          echo "=== DISK USAGE ==="
          du -sh /restore
          echo
          echo "=== FILE TREE ==="
          find /restore -maxdepth 2 -print | head -100
          sleep 3600
      volumeMounts:
        - name: restored
          mountPath: /restore
          readOnly: true
  volumes:
    - name: restored
      persistentVolumeClaim:
        claimName: ${restore_vol}
EOF

  kubectl -n "$ns" wait --for=condition=Ready "pod/${pod}" --timeout=300s

  echo
  kubectl -n "$ns" logs "$pod"

  echo
  echo "============================================"
  echo " NON-DESTRUCTIVE RESTORE TEST READY"
  echo "============================================"
  echo "Inspect:"
  echo "  kubectl -n ${ns} exec -it ${pod} -- sh"
  echo
  echo "Cleanup:"
  echo "  $0 --cleanup-test ${app}"
}

cleanup_test() {
  local app="$1"
  local ns restore_vol pv promoted_pv pod

  app_line "$app" >/dev/null || { echo "ERROR: unknown app: $app"; exit 1; }

  ns="$(app_field "$app" 2)"
  restore_vol="${app}-restore-test"
  pv="${restore_vol}-pv"
  promoted_pv="${app}-restore-promoted-pv"
  pod="${app}-restore-inspect"

  local current_dir current_status
  current_dir="$(promotion_state_dir "$app" 2>/dev/null || true)"
  if [[ -n "$current_dir" && -f "$current_dir/state.env" ]]; then
    current_status="$(awk -F= '$1=="STATUS"{print $2}' "$current_dir/state.env" | tail -1)"
    case "$current_status" in
      promoted|patched|bound_restored|preparing)
        echo "ERROR: refusing cleanup while promotion state is $current_status."
        echo "Rollback first: $0 --rollback-app $app --confirm"
        return 1
        ;;
    esac
  fi

  echo "==> Cleaning test restore for $app..."
  kubectl -n "$ns" delete pod "$pod" --ignore-not-found
  kubectl -n "$ns" delete pvc "$restore_vol" --ignore-not-found
  kubectl delete pv "$pv" --ignore-not-found
  kubectl delete pv "$promoted_pv" --ignore-not-found
  kubectl -n longhorn-system delete volume "$restore_vol" --ignore-not-found

  if [[ -n "${current_status:-}" && "$current_status" == "rolled_back" ]]; then
    sed -i 's/^STATUS=.*/STATUS=cleaned/' "$current_dir/state.env"
    archive_state "$app" || true
  fi
}


deployment_claim_patch() {
  local ns="$1" deploy="$2" old_pvc="$3" new_pvc="$4"
  local patch
  patch="$(
    kubectl -n "$ns" get deployment "$deploy" -o json |
    python3 -c '
import json,sys
old,new=sys.argv[1],sys.argv[2]
d=json.load(sys.stdin)
ops=[]
for i,v in enumerate(d.get("spec",{}).get("template",{}).get("spec",{}).get("volumes",[])):
    pvc=v.get("persistentVolumeClaim",{})
    if pvc.get("claimName")==old:
        ops.append({"op":"replace","path":f"/spec/template/spec/volumes/{i}/persistentVolumeClaim/claimName","value":new})
if not ops:
    raise SystemExit(2)
print(json.dumps(ops,separators=(",",":")))
' "$old_pvc" "$new_pvc"
  )" || {
    echo "ERROR: deployment $ns/$deploy has no PVC reference to $old_pvc"
    return 1
  }
  kubectl -n "$ns" patch deployment "$deploy" --type=json -p "$patch"
}

wait_deployment_scaled_zero() {
  local ns="$1" deploy="$2"
  for i in {1..60}; do
    local replicas ready
    replicas="$(kubectl -n "$ns" get deployment "$deploy" -o jsonpath='{.status.replicas}' 2>/dev/null || true)"
    ready="$(kubectl -n "$ns" get deployment "$deploy" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ -z "$replicas" || "$replicas" == "0" ]] && [[ -z "$ready" || "$ready" == "0" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: deployment $ns/$deploy did not scale to zero"
  return 1
}

wait_longhorn_detached() {
  local vol="$1"
  for i in {1..90}; do
    local state
    state="$(kubectl -n longhorn-system get volume "$vol" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    [[ "$state" == "detached" ]] && return 0
    sleep 2
  done
  echo "ERROR: Longhorn volume $vol did not detach"
  return 1
}

verify_service_endpoints() {
  local ns="$1" service="$2"
  [[ -z "$service" ]] && return 0
  local addresses
  addresses="$(
    kubectl -n "$ns" get endpointslice \
      -l "kubernetes.io/service-name=${service}" \
      -o go-template='{{range .items}}{{range .endpoints}}{{range .addresses}}{{.}}{{"\n"}}{{end}}{{end}}{{end}}' \
      2>/dev/null || true
  )"
  [[ -n "$addresses" ]] || {
    echo "WARNING: service $ns/$service has no EndpointSlice addresses."
    return 1
  }
  echo "==> Service endpoints:"
  printf '%s\n' "$addresses"
}

promotion_state_dir() {
  local app="$1"
  local current="${STATE_ROOT}/${app}/current"
  if [[ -L "$current" ]]; then
    local raw
    raw="$(readlink "$current" || true)"
    [[ -n "$raw" ]] && printf '%s/%s\n' "${STATE_ROOT}/${app}" "$raw"
  fi
}

promotion_status() {
  local app="$1"
  local dir
  dir="$(promotion_state_dir "$app" || true)"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    echo "No promotion state recorded for $app."
    return 0
  fi
  echo "==> Promotion state: $dir"
  cat "$dir/state.env"
}

promote_deployment_app() {
  local app="$1" confirm="${2:-}"
  [[ "$confirm" == "--confirm" ]] || {
    echo "ERROR: promotion requires --confirm"
    echo "Usage: $0 --promote-app $app --confirm"
    exit 2
  }

  app_line "$app" >/dev/null || { echo "ERROR: unknown app: $app"; exit 1; }

  local ns pvc kind workload service ingress restore_vol pod replicas stamp state_dir old_volume
  ns="$(app_field "$app" 2)"
  pvc="$(app_field "$app" 3)"
  kind="$(app_field "$app" 4)"
  workload="$(app_field "$app" 5)"
  service="$(app_field "$app" 6)"
  ingress="$(app_field "$app" 7)"
  restore_vol="${app}-restore-test"
  pod="${app}-restore-inspect"

  [[ "$kind" == "deployment" ]] || {
    echo "ERROR: promotion currently supports Deployment workloads only."
    echo "$app uses $kind/$workload."
    exit 1
  }

  kubectl -n "$ns" get pvc "$restore_vol" >/dev/null 2>&1 || {
    echo "ERROR: test restore PVC $ns/$restore_vol does not exist."
    echo "Run: $0 --restore-app $app"
    exit 1
  }

  [[ "$(kubectl -n "$ns" get pvc "$restore_vol" -o jsonpath='{.status.phase}')" == "Bound" ]] || {
    echo "ERROR: test restore PVC is not Bound."
    exit 1
  }

  kubectl -n longhorn-system get volume "$restore_vol" >/dev/null 2>&1 || {
    echo "ERROR: restored Longhorn volume $restore_vol does not exist."
    exit 1
  }

  [[ "$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]] || {
    echo "ERROR: inspection pod $ns/$pod is not Ready."
    echo "Run and verify a non-destructive restore first."
    exit 1
  }

  old_volume="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')"
  replicas="$(kubectl -n "$ns" get deployment "$workload" -o jsonpath='{.spec.replicas}')"
  [[ -n "$replicas" ]] || replicas=1

  stamp="$(date +%Y%m%d-%H%M%S)"
  state_dir="${STATE_ROOT}/${app}/${stamp}"
  mkdir -p "$state_dir"

  kubectl -n "$ns" get deployment "$workload" -o yaml > "$state_dir/deployment-before.yaml"
  kubectl -n "$ns" get pvc "$pvc" -o yaml > "$state_dir/live-pvc-before.yaml"
  kubectl -n "$ns" get pvc "$restore_vol" -o yaml > "$state_dir/restored-pvc-before.yaml"

  cat > "$state_dir/state.env" <<EOF
APP=${app}
NAMESPACE=${ns}
WORKLOAD=${workload}
KIND=${kind}
ORIGINAL_PVC=${pvc}
ORIGINAL_VOLUME=${old_volume}
RESTORED_PVC=${restore_vol}
RESTORED_VOLUME=${restore_vol}
ORIGINAL_REPLICAS=${replicas}
PROMOTED_AT=$(date -Iseconds)
STATUS=preparing
EOF

  save_operator_parent "$app" "$ns" "$state_dir"

  ln -sfn "$stamp" "${STATE_ROOT}/${app}/current"

  echo "==> Removing inspection pod..."
  kubectl -n "$ns" delete pod "$pod" --wait=true
  wait_longhorn_detached "$restore_vol"

  echo "==> Scaling deployment/$workload to zero..."
  kubectl -n "$ns" scale deployment "$workload" --replicas=0
  wait_deployment_scaled_zero "$ns" "$workload"

  echo "==> Switching PVC $pvc -> $restore_vol..."
  deployment_claim_patch "$ns" "$workload" "$pvc" "$restore_vol"
  sed -i 's/^STATUS=.*/STATUS=patched/' "$state_dir/state.env"

  echo "==> Scaling deployment/$workload back to $replicas..."
  kubectl -n "$ns" scale deployment "$workload" --replicas="$replicas"

  if ! kubectl -n "$ns" rollout status deployment/"$workload" --timeout=300s; then
    echo "ERROR: promoted workload failed to roll out."
    echo "Rollback with: $0 --rollback-app $app --confirm"
    exit 1
  fi

  sed -i 's/^STATUS=.*/STATUS=promoted/' "$state_dir/state.env"

  echo
  echo "==> Promotion completed."
  kubectl -n "$ns" get deployment "$workload"
  kubectl -n "$ns" get pvc "$pvc" "$restore_vol" -o wide
  verify_service_endpoints "$ns" "$service" || true
  [[ -n "$ingress" ]] && kubectl -n "$ns" get ingress "$ingress" || true

  echo
  echo "Rollback state: $state_dir"
  health_check_app "$app" || echo "WARNING: promotion completed but health verification reported a warning."
  echo "Rollback: $0 --rollback-app $app --confirm"
}

rollback_deployment_app() {
  local app="$1" confirm="${2:-}"
  [[ "$confirm" == "--confirm" ]] || {
    echo "ERROR: rollback requires --confirm"
    echo "Usage: $0 --rollback-app $app --confirm"
    exit 2
  }

  local dir
  dir="$(promotion_state_dir "$app" || true)"
  [[ -n "$dir" && -f "$dir/state.env" ]] || {
    echo "ERROR: no promotion state found for $app."
    exit 1
  }

  # shellcheck disable=SC1090
  source "$dir/state.env"

  [[ "$STATUS" == "promoted" || "$STATUS" == "patched" ]] || {
    echo "ERROR: promotion state is $STATUS; rollback not applicable."
    exit 1
  }

  echo "==> Rolling back $APP..."
  kubectl -n "$NAMESPACE" scale deployment "$WORKLOAD" --replicas=0
  wait_deployment_scaled_zero "$NAMESPACE" "$WORKLOAD"

  deployment_claim_patch "$NAMESPACE" "$WORKLOAD" "$RESTORED_PVC" "$ORIGINAL_PVC"

  kubectl -n "$NAMESPACE" scale deployment "$WORKLOAD" --replicas="$ORIGINAL_REPLICAS"
  kubectl -n "$NAMESPACE" rollout status deployment/"$WORKLOAD" --timeout=300s

  sed -i 's/^STATUS=.*/STATUS=rolled_back/' "$dir/state.env"
  echo "ROLLED_BACK_AT=$(date -Iseconds)" >> "$dir/state.env"

  echo
  echo "==> Rollback completed."
  kubectl -n "$NAMESPACE" get deployment "$WORKLOAD"
  kubectl -n "$NAMESPACE" get pvc "$ORIGINAL_PVC" "$RESTORED_PVC" -o wide
  echo
  health_check_app "$app" || echo "WARNING: rollback completed but health verification reported a warning."
  echo "Restored PVC retained. Cleanup when satisfied:"
  echo "  $0 --cleanup-test $app"
}


wait_statefulset_scaled_zero() {
  local ns="$1" sts="$2"
  for i in {1..90}; do
    local current ready
    current="$(kubectl -n "$ns" get statefulset "$sts" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || true)"
    ready="$(kubectl -n "$ns" get statefulset "$sts" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ -z "$current" || "$current" == "0" ]] && [[ -z "$ready" || "$ready" == "0" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: statefulset $ns/$sts did not scale to zero"
  return 1
}

wait_pv_phase() {
  local pv="$1" desired="$2"
  for i in {1..60}; do
    local phase
    phase="$(kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "$desired" ]] && return 0
    sleep 2
  done
  echo "ERROR: PV $pv did not reach phase $desired"
  return 1
}

wait_pvc_bound_to_pv() {
  local ns="$1" pvc="$2" pv="$3"
  for i in {1..90}; do
    local phase bound
    phase="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    bound="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
    [[ "$phase" == "Bound" && "$bound" == "$pv" ]] && return 0
    sleep 2
  done
  echo "ERROR: PVC $ns/$pvc did not bind to PV $pv"
  return 1
}

stateful_claim_template_name() {
  local ns="$1" sts="$2" pvc="$3"
  kubectl -n "$ns" get statefulset "$sts" -o json |
    python3 -c '
import json,sys
pvc=sys.argv[1]
d=json.load(sys.stdin)
name=d["metadata"]["name"]
for t in d.get("spec",{}).get("volumeClaimTemplates",[]):
    tname=t["metadata"]["name"]
    if pvc == f"{tname}-{name}-0":
        print(tname)
        raise SystemExit(0)
raise SystemExit(2)
' "$pvc"
}

create_prebound_pvc() {
  local ns="$1" pvc="$2" pv="$3" cap="$4" sc="$5"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
  namespace: ${ns}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${cap}
  storageClassName: ${sc}
  volumeMode: Filesystem
  volumeName: ${pv}
EOF
}

create_longhorn_pv() {
  local pv="$1" cap="$2" handle="$3" replicas="$4" sc="$5"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${pv}
spec:
  capacity:
    storage: ${cap}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${sc}
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeAttributes:
      numberOfReplicas: "${replicas}"
      staleReplicaTimeout: "30"
    volumeHandle: ${handle}
EOF
}


operator_parent_for_app() {
  local app="$1"
  case "$app" in
    prometheus)
      printf '%s|%s\n' "prometheus.monitoring.coreos.com" "monitoring-kube-prometheus-prometheus"
      ;;
    alertmanager)
      printf '%s|%s\n' "alertmanager.monitoring.coreos.com" "monitoring-kube-prometheus-alertmanager"
      ;;
    *)
      return 1
      ;;
  esac
}

scale_stateful_app() {
  local app="$1" ns="$2" sts="$3" replicas="$4"
  local parent kind name

  if parent="$(operator_parent_for_app "$app" 2>/dev/null)"; then
    kind="${parent%%|*}"
    name="${parent##*|}"
    echo "==> Scaling operator resource ${kind}/${name} to ${replicas}..."
    kubectl -n "$ns" patch "$kind" "$name" \
      --type merge \
      -p "{\"spec\":{\"replicas\":${replicas}}}"
  else
    echo "==> Scaling statefulset/${sts} to ${replicas}..."
    kubectl -n "$ns" scale statefulset "$sts" --replicas="$replicas"
  fi
}

get_stateful_desired_replicas() {
  local app="$1" ns="$2" sts="$3"
  local parent kind name replicas

  if parent="$(operator_parent_for_app "$app" 2>/dev/null)"; then
    kind="${parent%%|*}"
    name="${parent##*|}"
    replicas="$(kubectl -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.replicas}')"
  else
    replicas="$(kubectl -n "$ns" get statefulset "$sts" -o jsonpath='{.spec.replicas}')"
  fi

  [[ -n "$replicas" ]] || replicas=1
  printf '%s\n' "$replicas"
}

save_operator_parent() {
  local app="$1" ns="$2" state_dir="$3"
  local parent kind name

  if parent="$(operator_parent_for_app "$app" 2>/dev/null)"; then
    kind="${parent%%|*}"
    name="${parent##*|}"
    kubectl -n "$ns" get "$kind" "$name" -o yaml > "${state_dir}/operator-parent-before.yaml"
    {
      echo "OPERATOR_KIND=${kind}"
      echo "OPERATOR_NAME=${name}"
    } >> "${state_dir}/state.env"
  else
    {
      echo "OPERATOR_KIND="
      echo "OPERATOR_NAME="
    } >> "${state_dir}/state.env"
  fi
}

promote_stateful_app() {
  local app="$1" confirm="${2:-}"
  [[ "$confirm" == "--confirm" ]] || {
    echo "ERROR: StatefulSet promotion requires --confirm"
    echo "Usage: $0 --promote-app $app --confirm"
    exit 2
  }

  app_line "$app" >/dev/null || { echo "ERROR: unknown app: $app"; exit 1; }

  local ns pvc kind sts service restore_vol inspect_pod original_pv original_volume
  local replicas cap sc lh_replicas promoted_pv stamp state_dir template_name

  ns="$(app_field "$app" 2)"
  pvc="$(app_field "$app" 3)"
  kind="$(app_field "$app" 4)"
  sts="$(app_field "$app" 5)"
  service="$(app_field "$app" 6)"
  restore_vol="${app}-restore-test"
  inspect_pod="${app}-restore-inspect"
  promoted_pv="${app}-restore-promoted-pv"

  [[ "$kind" == "statefulset" ]] || {
    echo "ERROR: $app is not a StatefulSet app."
    exit 1
  }

  replicas="$(get_stateful_desired_replicas "$app" "$ns" "$sts")"
  [[ "$replicas" == "1" ]] || {
    echo "ERROR: v9 StatefulSet promotion supports exactly 1 replica; $sts has $replicas."
    exit 1
  }

  template_name="$(stateful_claim_template_name "$ns" "$sts" "$pvc")" || {
    echo "ERROR: $pvc does not match a volumeClaimTemplate for $sts ordinal 0."
    exit 1
  }

  kubectl -n "$ns" get pvc "$restore_vol" >/dev/null 2>&1 || {
    echo "ERROR: test restore PVC $ns/$restore_vol does not exist."
    echo "Run: $0 --restore-app $app"
    exit 1
  }

  [[ "$(kubectl -n "$ns" get pod "$inspect_pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]] || {
    echo "ERROR: inspection pod is not Ready; verify the restore first."
    exit 1
  }

  original_pv="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')"
  original_volume="$(kubectl get pv "$original_pv" -o jsonpath='{.spec.csi.volumeHandle}')"
  cap="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.resources.requests.storage}')"
  sc="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.storageClassName}')"
  lh_replicas="$(kubectl -n longhorn-system get volume "$restore_vol" -o jsonpath='{.spec.numberOfReplicas}')"

  stamp="$(date +%Y%m%d-%H%M%S)"
  state_dir="${STATE_ROOT}/${app}/${stamp}"
  mkdir -p "$state_dir"

  kubectl -n "$ns" get statefulset "$sts" -o yaml > "$state_dir/statefulset-before.yaml"
  kubectl -n "$ns" get pvc "$pvc" -o yaml > "$state_dir/live-pvc-before.yaml"
  kubectl get pv "$original_pv" -o yaml > "$state_dir/original-pv-before.yaml"
  kubectl -n longhorn-system get volume "$original_volume" -o yaml > "$state_dir/original-longhorn-before.yaml"
  kubectl -n "$ns" get pvc "$restore_vol" -o yaml > "$state_dir/restored-pvc-before.yaml"

  cat > "$state_dir/state.env" <<EOF
APP=${app}
NAMESPACE=${ns}
WORKLOAD=${sts}
KIND=statefulset
PVC=${pvc}
CLAIM_TEMPLATE=${template_name}
ORIGINAL_PV=${original_pv}
ORIGINAL_VOLUME=${original_volume}
RESTORED_VOLUME=${restore_vol}
PROMOTED_PV=${promoted_pv}
ORIGINAL_REPLICAS=${replicas}
CAPACITY=${cap}
STORAGE_CLASS=${sc}
PROMOTED_AT=$(date -Iseconds)
STATUS=preparing
EOF

  ln -sfn "$stamp" "${STATE_ROOT}/${app}/current"

  echo "==> Removing inspection pod/PVC/PV while preserving restored Longhorn volume..."
  kubectl -n "$ns" delete pod "$inspect_pod" --ignore-not-found --wait=true
  wait_longhorn_detached "$restore_vol"
  kubectl -n "$ns" delete pvc "$restore_vol" --ignore-not-found
  kubectl delete pv "${restore_vol}-pv" --ignore-not-found

  scale_stateful_app "$app" "$ns" "$sts" 0
  wait_statefulset_scaled_zero "$ns" "$sts"
  wait_longhorn_detached "$original_volume"

  echo "==> Protecting original PV with Retain..."
  kubectl patch pv "$original_pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

  echo "==> Deleting generated PVC $ns/$pvc (original PV/Longhorn volume retained)..."
  kubectl -n "$ns" delete pvc "$pvc" --wait=true
  wait_pv_phase "$original_pv" "Released"

  echo "==> Creating restored PV $promoted_pv..."
  create_longhorn_pv "$promoted_pv" "$cap" "$restore_vol" "$lh_replicas" "$sc"

  echo "==> Recreating StatefulSet PVC name $pvc bound to restored PV..."
  create_prebound_pvc "$ns" "$pvc" "$promoted_pv" "$cap" "$sc"
  wait_pvc_bound_to_pv "$ns" "$pvc" "$promoted_pv"

  sed -i 's/^STATUS=.*/STATUS=bound_restored/' "$state_dir/state.env"

  scale_stateful_app "$app" "$ns" "$sts" "$replicas"
  kubectl -n "$ns" rollout status statefulset/"$sts" --timeout=300s

  sed -i 's/^STATUS=.*/STATUS=promoted/' "$state_dir/state.env"

  echo
  echo "==> StatefulSet promotion completed."
  kubectl -n "$ns" get statefulset "$sts"
  kubectl -n "$ns" get pvc "$pvc" -o wide
  kubectl get pv "$original_pv" "$promoted_pv" -o wide
  kubectl -n longhorn-system get volume "$original_volume" "$restore_vol"
  verify_service_endpoints "$ns" "$service" || true

  echo
  echo "Rollback: $0 --rollback-app $app --confirm"
}

rollback_stateful_app() {
  local app="$1" confirm="${2:-}"
  [[ "$confirm" == "--confirm" ]] || {
    echo "ERROR: StatefulSet rollback requires --confirm"
    exit 2
  }

  local dir
  dir="$(promotion_state_dir "$app" || true)"
  [[ -n "$dir" && -f "$dir/state.env" ]] || {
    echo "ERROR: no promotion state found for $app."
    exit 1
  }

  # shellcheck disable=SC1090
  source "$dir/state.env"

  [[ "$KIND" == "statefulset" ]] || {
    echo "ERROR: saved state is not a StatefulSet promotion."
    exit 1
  }
  [[ "$STATUS" == "promoted" || "$STATUS" == "bound_restored" ]] || {
    echo "ERROR: promotion state is $STATUS; rollback not applicable."
    exit 1
  }

  scale_stateful_app "$APP" "$NAMESPACE" "$WORKLOAD" 0
  wait_statefulset_scaled_zero "$NAMESPACE" "$WORKLOAD"
  wait_longhorn_detached "$RESTORED_VOLUME"

  echo "==> Protecting promoted PV with Retain..."
  kubectl patch pv "$PROMOTED_PV" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

  echo "==> Removing restored binding..."
  kubectl -n "$NAMESPACE" delete pvc "$PVC" --wait=true
  wait_pv_phase "$PROMOTED_PV" "Released"

  echo "==> Clearing old claimRef from original PV so it can bind again..."
  kubectl patch pv "$ORIGINAL_PV" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' || true

  echo "==> Recreating original StatefulSet PVC binding..."
  create_prebound_pvc "$NAMESPACE" "$PVC" "$ORIGINAL_PV" "$CAPACITY" "$STORAGE_CLASS"
  wait_pvc_bound_to_pv "$NAMESPACE" "$PVC" "$ORIGINAL_PV"

  scale_stateful_app "$APP" "$NAMESPACE" "$WORKLOAD" "$ORIGINAL_REPLICAS"
  kubectl -n "$NAMESPACE" rollout status statefulset/"$WORKLOAD" --timeout=300s

  sed -i 's/^STATUS=.*/STATUS=rolled_back/' "$dir/state.env"
  echo "ROLLED_BACK_AT=$(date -Iseconds)" >> "$dir/state.env"

  echo
  echo "==> StatefulSet rollback completed."
  kubectl -n "$NAMESPACE" get statefulset "$WORKLOAD"
  kubectl -n "$NAMESPACE" get pvc "$PVC" -o wide
  kubectl get pv "$ORIGINAL_PV" "$PROMOTED_PV" -o wide
  kubectl -n longhorn-system get volume "$ORIGINAL_VOLUME" "$RESTORED_VOLUME"

  echo
  health_check_app "$app" || echo "WARNING: rollback completed but health verification reported a warning."
  echo "Restored PV/volume retained for inspection."
  echo "Cleanup after verification: $0 --cleanup-test $app"
}

promote_app() {
  local app="$1" confirm="${2:-}"
  local kind
  kind="$(app_field "$app" 4)"
  case "$kind" in
    deployment) promote_deployment_app "$app" "$confirm" ;;
    statefulset) promote_stateful_app "$app" "$confirm" ;;
    *) echo "ERROR: unsupported workload kind: $kind"; exit 1 ;;
  esac
}

rollback_app() {
  local app="$1" confirm="${2:-}"
  local kind
  kind="$(app_field "$app" 4)"
  case "$kind" in
    deployment) rollback_deployment_app "$app" "$confirm" ;;
    statefulset) rollback_stateful_app "$app" "$confirm" ;;
    *) echo "ERROR: unsupported workload kind: $kind"; exit 1 ;;
  esac
}

mount_backup
LATEST="$(latest_bundle)"
[[ -n "$LATEST" ]] || { echo "ERROR: no recovery bundle found"; exit 1; }

case "$MODE" in
  --preflight)
    echo "==> Selected recovery bundle:"
    echo "$LATEST"
    verify_bundle "$LATEST"
    echo "RECOVERY PREFLIGHT PASSED"
    ;;
  --restore-repo)
    verify_bundle "$LATEST"
    [[ ! -e "$DEST" ]] || { echo "ERROR: $DEST already exists"; exit 1; }
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"; cleanup' EXIT
    sudo tar -xzf "$LATEST/repo/k3s-repository.tar.gz" -C "$tmpdir"
    mkdir -p "$DEST"
    cp -a "$tmpdir/k3s/." "$DEST/"
    echo "Repository restored to $DEST"
    ;;
  --list-longhorn)
    kubectl -n longhorn-system get backuptarget default -o wide
    kubectl -n longhorn-system get backupvolumes.longhorn.io
    kubectl -n longhorn-system get backups.longhorn.io
    ;;
  --show-etcd)
    sudo find "$LATEST/etcd" -maxdepth 1 -type f -printf '%p\n'
    ;;
  --show-manifest)
    sudo cat "$LATEST/BACKUP-MANIFEST.txt"
    ;;
  --list-apps)
    list_apps
    ;;
  --inspect-app)
    [[ -n "$APP_NAME" ]] || { usage; exit 2; }
    inspect_app "$APP_NAME"
    ;;
  --restore-app)
    [[ -n "$APP_NAME" ]] || { usage; exit 2; }
    restore_app "$APP_NAME"
    ;;
  --cleanup-test)
    [[ -n "$APP_NAME" ]] || { usage; exit 2; }
    cleanup_test "$APP_NAME"
    ;;
  --promote-app)
    [[ -n "$APP_NAME" ]] || { usage; exit 2; }
    promote_app "$APP_NAME" "${3:-}"
    ;;
  --rollback-app)
    [[ -n "$APP_NAME" ]] || { usage; exit 2; }
    rollback_app "$APP_NAME" "${3:-}"
    ;;
  --promotion-status)
    [[ -n "$APP_NAME" ]] || { usage; exit 2; }
    promotion_status "$APP_NAME"
    ;;
  --plan)
    [[ -n "$APP_NAME" ]] || { usage; exit 2; }
    plan_app "$APP_NAME"
    ;;
  --health-check)
    [[ -n "$APP_NAME" ]] || { usage; exit 2; }
    health_check_app "$APP_NAME"
    ;;
  --archive-state)
    [[ -n "$APP_NAME" ]] || { usage; exit 2; }
    archive_state "$APP_NAME"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
