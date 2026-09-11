#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_FILE="${APPS_FILE:-$ROOT_DIR/recovery/apps.conf}"
LONGHORN_NS=longhorn-system
TEST_NS=longhorn-native-canary
STAMP="$(date +%Y%m%d-%H%M%S)"
RESTORE_VOL="longhorn-native-canary-$STAMP"
PV="${RESTORE_VOL}-pv"
PVC="${RESTORE_VOL}-pvc"
POD="${RESTORE_VOL}-reader"

cleanup() {
  kubectl -n "$TEST_NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$TEST_NS" delete pvc "$PVC" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete pv "$PV" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$LONGHORN_NS" delete volume "$RESTORE_VOL" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "$TEST_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

[[ -f "$APPS_FILE" ]] || { echo "ERROR: missing $APPS_FILE" >&2; exit 1; }
kubectl delete namespace "$TEST_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
kubectl wait --for=delete "namespace/$TEST_NS" --timeout=10m 2>/dev/null || true

selected=""; selected_size=""
while IFS='|' read -r app ns pvc _rest; do
  [[ -z "$app" || "$app" == \#* ]] && continue
  volume="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  size="$(kubectl -n "$LONGHORN_NS" get volume "$volume" -o jsonpath='{.spec.size}' 2>/dev/null || true)"
  [[ "$size" =~ ^[0-9]+$ ]] || continue
  if [[ -z "$selected_size" || "$size" -lt "$selected_size" ]]; then
    selected="$app|$ns|$pvc|$volume"; selected_size="$size"
  fi
done <"$APPS_FILE"
[[ -n "$selected" ]] || { echo "ERROR: no protected Longhorn volume found" >&2; exit 1; }
IFS='|' read -r app ns pvc volume <<<"$selected"
backup="$(kubectl -n "$LONGHORN_NS" get backupvolumes.longhorn.io -o json | python3 -c '
import json,sys
vol=sys.argv[1]; xs=[]
for x in json.load(sys.stdin).get("items",[]):
 s=x.get("status",{}); n=x.get("metadata",{}).get("name","")
 if (n.startswith(vol+"-") or s.get("volumeName")==vol) and s.get("lastBackupName"): xs.append((s.get("lastBackupAt", ""),s["lastBackupName"]))
if not xs: raise SystemExit(1)
print(max(xs)[1])
' "$volume")"
backup_url="$(kubectl -n "$LONGHORN_NS" get backup "$backup" -o jsonpath='{.status.url}')"
capacity="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.resources.requests.storage}')"
[[ -n "$backup_url" && -n "$capacity" ]] || { echo "ERROR: incomplete backup metadata" >&2; exit 1; }

echo "==> Longhorn native restore canary: $app ($volume) from $backup"
kubectl create namespace "$TEST_NS"
kubectl -n "$LONGHORN_NS" apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata: { name: $RESTORE_VOL, namespace: $LONGHORN_NS }
spec:
  fromBackup: "$backup_url"
  numberOfReplicas: 1
  size: "$selected_size"
  frontend: blockdev
  accessMode: rwo
EOF

deadline=$(( $(date +%s) + ${LONGHORN_RESTORE_CANARY_TIMEOUT_SECONDS:-2700} ))
while true; do
  state="$(kubectl -n "$LONGHORN_NS" get volume "$RESTORE_VOL" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  required="$(kubectl -n "$LONGHORN_NS" get volume "$RESTORE_VOL" -o jsonpath='{.status.restoreRequired}' 2>/dev/null || true)"
  echo "    state=$state restoreRequired=$required"
  [[ "$state" == detached && "$required" == false ]] && break
  (( $(date +%s) < deadline )) || { echo "ERROR: Longhorn restore timed out" >&2; exit 1; }
  sleep 15
done

kubectl -n "$TEST_NS" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata: { name: $PV }
spec:
  capacity: { storage: $capacity }
  volumeMode: Filesystem
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi: { driver: driver.longhorn.io, volumeHandle: $RESTORE_VOL }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $PVC, namespace: $TEST_NS }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: $capacity } }
  volumeName: $PV
  storageClassName: longhorn
---
apiVersion: v1
kind: Pod
metadata: { name: $POD, namespace: $TEST_NS }
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: docker.io/library/busybox:1.37.0
      command: [sh, -c, 'set -eu; test -n "\$(find /restore -mindepth 1 -maxdepth 1 -print -quit)"']
      volumeMounts: [{ name: restored, mountPath: /restore, readOnly: true }]
  volumes: [{ name: restored, persistentVolumeClaim: { claimName: $PVC } }]
EOF
kubectl -n "$TEST_NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout=10m
echo "RESULT: LONGHORN CIFS NATIVE RESTORE VERIFIED"
