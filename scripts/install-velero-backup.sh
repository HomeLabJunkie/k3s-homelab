#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOTTER_VERSION="${SNAPSHOTTER_VERSION:-v8.6.0}"
VELERO_CHART_VERSION="${VELERO_CHART_VERSION:-12.1.0}"
SECRETS_FILE="${SECRETS_FILE:-$ROOT/.secrets.enc}"

for command in helm kubectl sops base64; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $command" >&2
    exit 1
  }
done

[[ -r "$SECRETS_FILE" ]] || {
  echo "ERROR: encrypted secrets file is unavailable: $SECRETS_FILE" >&2
  exit 1
}

set -a
source "${ENV_FILE:-$ROOT/config/cluster.env}"
source <(sops --decrypt "$SECRETS_FILE")
set +a

: "${UNRAID_IP:?UNRAID_IP is not set in config/cluster.env}"
GARAGE_S3_URL="${GARAGE_S3_URL:-http://${UNRAID_IP}:3900}"

for variable in VELERO_GARAGE_ACCESS_KEY VELERO_GARAGE_SECRET_KEY VELERO_REPOSITORY_PASSWORD; do
  [[ -n "${!variable:-}" ]] || {
    echo "ERROR: $variable is missing from $SECRETS_FILE" >&2
    exit 1
  }
done

echo "==> Installing CSI snapshot API ${SNAPSHOTTER_VERSION}"
snapshot_base="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}"
for crd in volumesnapshotclasses volumesnapshotcontents volumesnapshots; do
  kubectl apply -f "${snapshot_base}/client/config/crd/snapshot.storage.k8s.io_${crd}.yaml"
done
kubectl apply -f "${snapshot_base}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
kubectl apply -f "${snapshot_base}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"
kubectl -n kube-system rollout status deployment/snapshot-controller --timeout=300s
kubectl apply -f "$ROOT/manifests/backup/longhorn-csi-snapshot-class.yaml"
kubectl apply -f "$ROOT/manifests/backup/longhorn-velero-temp-storageclass.yaml"

echo "==> Creating Velero secrets from encrypted local values"
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f - >/dev/null
credentials="[default]
aws_access_key_id=${VELERO_GARAGE_ACCESS_KEY}
aws_secret_access_key=${VELERO_GARAGE_SECRET_KEY}"
kubectl -n velero create secret generic velero-garage-credentials \
  --from-literal=cloud="$credentials" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n velero create secret generic velero-repo-credentials \
  --from-literal=repository-password="$VELERO_REPOSITORY_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset credentials

echo "==> Installing Velero ${VELERO_CHART_VERSION} with CSI data mover"
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update >/dev/null
helm upgrade --install velero vmware-tanzu/velero \
  --namespace velero \
  --version "$VELERO_CHART_VERSION" \
  --values "$ROOT/velero-values.yaml" \
  --set "configuration.backupStorageLocation[0].config.s3Url=${GARAGE_S3_URL}" \
  --wait \
  --timeout 10m

kubectl -n velero rollout status deployment/velero --timeout=300s
kubectl -n velero rollout restart daemonset/node-agent >/dev/null
kubectl -n velero rollout status daemonset/node-agent --timeout=600s
kubectl -n velero wait --for=jsonpath='{.status.phase}'=Available \
  backupstoragelocation/garage --timeout=300s

echo "RESULT: VELERO READY (schedule not applied by this installer)"
