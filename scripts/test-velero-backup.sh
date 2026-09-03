#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_NAMESPACE="velero-canary"
RESTORE_NAMESPACE="velero-canary-restore"
BACKUP_NAME="velero-canary-$(date +%Y%m%d-%H%M%S)"
RESTORE_NAME="${BACKUP_NAME}-restore"
MARKER="velero-csi-data-mover-$(date +%s)"

cleanup() {
  kubectl delete namespace "$SOURCE_NAMESPACE" "$RESTORE_NAMESPACE" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
for namespace in "$SOURCE_NAMESPACE" "$RESTORE_NAMESPACE"; do
  kubectl wait --for=delete "namespace/$namespace" --timeout=10m 2>/dev/null || true
done
kubectl create namespace "$SOURCE_NAMESPACE"
kubectl -n "$SOURCE_NAMESPACE" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: canary-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: canary-writer
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: docker.io/library/busybox:1.37.0
      command: [sh, -c, "printf '%s\\n' '$MARKER' > /data/marker && sync"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: canary-data
EOF
kubectl -n "$SOURCE_NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/canary-writer --timeout=300s

kubectl -n velero apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: $BACKUP_NAME
spec:
  includedNamespaces: [$SOURCE_NAMESPACE]
  snapshotMoveData: true
  storageLocation: rustfs
  ttl: 168h
EOF
kubectl -n velero wait --for=jsonpath='{.status.phase}'=Completed "backups.velero.io/$BACKUP_NAME" --timeout=30m

kubectl delete namespace "$SOURCE_NAMESPACE" --wait=true --timeout=10m
kubectl -n velero apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $RESTORE_NAME
spec:
  backupName: $BACKUP_NAME
  namespaceMapping:
    $SOURCE_NAMESPACE: $RESTORE_NAMESPACE
EOF
kubectl -n velero wait --for=jsonpath='{.status.phase}'=Completed "restores.velero.io/$RESTORE_NAME" --timeout=30m
kubectl -n "$RESTORE_NAMESPACE" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: canary-reader
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: docker.io/library/busybox:1.37.0
      command: [sh, -c, "grep -qx '$MARKER' /data/marker"]
      volumeMounts:
        - name: data
          mountPath: /data
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: canary-data
EOF
kubectl -n "$RESTORE_NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/canary-reader --timeout=300s

echo "RESULT: VELERO CSI DATA MOVER RESTORE VERIFIED"

