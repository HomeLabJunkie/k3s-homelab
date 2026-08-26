#!/usr/bin/env bash
set -Eeuo pipefail

KUBECTL="${KUBECTL:-kubectl}"
OUTPUT="${OUTPUT:-recovery/generated-latest-validation.yaml}"

usage() {
    cat <<'EOF'
Usage:
  dr-generate-validation.sh [--output FILE]

Options:
  -o, --output FILE   Generated validation manifest.
                      Default: recovery/generated-latest-validation.yaml
  -h, --help          Show this help.

Safety:
  This script only reads production Kubernetes objects and generates YAML.
  It does NOT apply resources.
  It does NOT start pods.
  It does NOT modify PVCs or Longhorn volumes.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        -o|--output)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 2; }
            OUTPUT="$2"
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

if ! $KUBECTL get --raw='/readyz' >/dev/null 2>&1; then
    echo "ERROR: Kubernetes API is not ready or cannot be reached." >&2
    exit 1
fi

get_image() {
    local ns="$1"
    local type="$2"
    local name="$3"
    local container="$4"

    $KUBECTL -n "$ns" get "$type" "$name" -o json |
    jq -r --arg C "$container" '
      .spec.template.spec.containers[]
      | select(.name==$C)
      | .image
    '
}

TRILIUM_IMAGE="$(get_image trilium deployment trilium trilium)"
VAULTWARDEN_IMAGE="$(get_image vaultwarden deployment vaultwarden vaultwarden)"
PORTAINER_IMAGE="$(get_image portainer deployment portainer portainer)"
GRAFANA_IMAGE="$(get_image monitoring deployment monitoring-grafana grafana)"
PROM_IMAGE="$(get_image monitoring statefulset prometheus-monitoring-kube-prometheus-prometheus prometheus)"
ALERT_IMAGE="$(get_image monitoring statefulset alertmanager-monitoring-kube-prometheus-alertmanager alertmanager)"
LOKI_IMAGE="$(get_image logging statefulset loki loki)"

for VAR in \
    TRILIUM_IMAGE VAULTWARDEN_IMAGE PORTAINER_IMAGE GRAFANA_IMAGE \
    PROM_IMAGE ALERT_IMAGE LOKI_IMAGE
do
    if [[ -z "${!VAR}" || "${!VAR}" == "null" ]]; then
        echo "ERROR: Could not determine image for $VAR" >&2
        exit 1
    fi
done

LOKI_CONFIG="$(
    $KUBECTL -n logging get configmap loki \
        -o jsonpath='{.data.config\.yaml}'
)"

if [[ -z "$LOKI_CONFIG" ]]; then
    echo "ERROR: Could not retrieve Loki config." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

cat > "$OUTPUT" <<EOF
# ============================================================
# GENERATED DR APPLICATION VALIDATION WORKLOADS
# ============================================================
#
# SAFETY:
# - Generated only; nothing has been applied.
# - These resources use isolated *-dr PVCs.
# - Review before applying.
# - Do not apply until restored Longhorn volumes are bound.
#
# Production images captured at generation time:
# Trilium:      $TRILIUM_IMAGE
# Vaultwarden:  $VAULTWARDEN_IMAGE
# Portainer:    $PORTAINER_IMAGE
# Grafana:      $GRAFANA_IMAGE
# Prometheus:   $PROM_IMAGE
# Alertmanager: $ALERT_IMAGE
# Loki:         $LOKI_IMAGE
#
EOF

cat >> "$OUTPUT" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-dr-validation-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 60s
    scrape_configs: []
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: alertmanager-dr-validation-config
  namespace: monitoring
data:
  alertmanager.yml: |
    route:
      receiver: noop
    receivers:
      - name: noop
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-dr-validation-runtime
  namespace: logging
data:
  runtime-config.yaml: |
    {}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-dr-validation-config
  namespace: logging
data:
  config.yaml: |
EOF

printf '%s\n' "$LOKI_CONFIG" |
sed \
  -e 's/loki-memberlist\.logging\.svc\.cluster\.local/loki-dr-validation-memberlist.logging.svc.cluster.local/g' \
  -e "s/^/    /" >> "$OUTPUT"

cat >> "$OUTPUT" <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: trilium-dr-validation
  namespace: trilium
spec:
  selector:
    app: trilium-dr-validation
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: trilium-dr-validation
  namespace: trilium
  labels:
    app: trilium-dr-validation
spec:
  restartPolicy: Never
  enableServiceLinks: false
  containers:
    - name: trilium
      image: $TRILIUM_IMAGE
      ports:
        - containerPort: 8080
      volumeMounts:
        - name: data
          mountPath: /home/node/trilium-data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: trilium-dr
---
apiVersion: v1
kind: Service
metadata:
  name: vaultwarden-dr-validation
  namespace: vaultwarden
spec:
  selector:
    app: vaultwarden-dr-validation
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: vaultwarden-dr-validation
  namespace: vaultwarden
  labels:
    app: vaultwarden-dr-validation
spec:
  restartPolicy: Never
  enableServiceLinks: false
  containers:
    - name: vaultwarden
      image: $VAULTWARDEN_IMAGE
      ports:
        - containerPort: 80
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: vaultwarden-dr
---
apiVersion: v1
kind: Service
metadata:
  name: portainer-dr-validation
  namespace: portainer
spec:
  selector:
    app: portainer-dr-validation
  ports:
    - port: 9000
      targetPort: 9000
---
apiVersion: v1
kind: Pod
metadata:
  name: portainer-dr-validation
  namespace: portainer
  labels:
    app: portainer-dr-validation
spec:
  restartPolicy: Never
  enableServiceLinks: false
  containers:
    - name: portainer
      image: $PORTAINER_IMAGE
      ports:
        - containerPort: 9000
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: portainer-dr
---
apiVersion: v1
kind: Service
metadata:
  name: grafana-dr-validation
  namespace: monitoring
spec:
  selector:
    app: grafana-dr-validation
  ports:
    - port: 3000
      targetPort: 3000
---
apiVersion: v1
kind: Pod
metadata:
  name: grafana-dr-validation
  namespace: monitoring
  labels:
    app: grafana-dr-validation
spec:
  restartPolicy: Never
  enableServiceLinks: false
  securityContext:
    fsGroup: 472
  containers:
    - name: grafana
      image: $GRAFANA_IMAGE
      ports:
        - containerPort: 3000
      volumeMounts:
        - name: data
          mountPath: /var/lib/grafana
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: grafana-dr
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-dr-validation
  namespace: monitoring
spec:
  selector:
    app: prometheus-dr-validation
  ports:
    - port: 9090
      targetPort: 9090
---
apiVersion: v1
kind: Pod
metadata:
  name: prometheus-dr-validation
  namespace: monitoring
  labels:
    app: prometheus-dr-validation
spec:
  restartPolicy: Never
  enableServiceLinks: false
  securityContext:
    runAsUser: 1000
    runAsGroup: 2000
    fsGroup: 2000
  containers:
    - name: prometheus
      image: $PROM_IMAGE
      args:
        - --config.file=/etc/prometheus/prometheus.yml
        - --storage.tsdb.path=/prometheus
        - --storage.tsdb.wal-compression
        - --web.listen-address=:9090
      ports:
        - containerPort: 9090
      volumeMounts:
        - name: data
          mountPath: /prometheus
          subPath: prometheus-db
        - name: config
          mountPath: /etc/prometheus
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: prometheus-dr
    - name: config
      configMap:
        name: prometheus-dr-validation-config
---
apiVersion: v1
kind: Service
metadata:
  name: alertmanager-dr-validation
  namespace: monitoring
spec:
  selector:
    app: alertmanager-dr-validation
  ports:
    - port: 9093
      targetPort: 9093
---
apiVersion: v1
kind: Pod
metadata:
  name: alertmanager-dr-validation
  namespace: monitoring
  labels:
    app: alertmanager-dr-validation
spec:
  restartPolicy: Never
  enableServiceLinks: false
  securityContext:
    runAsUser: 1000
    runAsGroup: 2000
    fsGroup: 2000
  containers:
    - name: alertmanager
      image: $ALERT_IMAGE
      args:
        - --config.file=/etc/alertmanager/alertmanager.yml
        - --storage.path=/alertmanager
        - --cluster.listen-address=
        - --web.listen-address=:9093
      ports:
        - containerPort: 9093
      volumeMounts:
        - name: data
          mountPath: /alertmanager
          subPath: alertmanager-db
        - name: config
          mountPath: /etc/alertmanager
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: alertmanager-dr
    - name: config
      configMap:
        name: alertmanager-dr-validation-config
---
apiVersion: v1
kind: Service
metadata:
  name: loki-dr-validation-memberlist
  namespace: logging
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: loki-dr-validation
  ports:
    - name: memberlist
      port: 7946
      targetPort: 7946
---
apiVersion: v1
kind: Service
metadata:
  name: loki-dr-validation
  namespace: logging
spec:
  selector:
    app: loki-dr-validation
  ports:
    - name: http
      port: 3100
      targetPort: 3100
---
apiVersion: v1
kind: Pod
metadata:
  name: loki-dr-validation
  namespace: logging
  labels:
    app: loki-dr-validation
spec:
  restartPolicy: Never
  enableServiceLinks: false
  securityContext:
    fsGroup: 10001
    fsGroupChangePolicy: OnRootMismatch
    runAsGroup: 10001
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: loki
      image: $LOKI_IMAGE
      args:
        - -config.file=/etc/loki/config/config.yaml
        - -config.expand-env=true
        - -memberlist.advertise-addr=\$(POD_IP)
        - -target=all
      env:
        - name: GOGC
          value: "80"
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
      ports:
        - containerPort: 3100
        - containerPort: 9095
        - containerPort: 7946
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
        readOnlyRootFilesystem: true
        seccompProfile:
          type: RuntimeDefault
      volumeMounts:
        - name: storage
          mountPath: /var/loki
        - name: config
          mountPath: /etc/loki/config
        - name: runtime-config
          mountPath: /etc/loki/runtime-config
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: storage
      persistentVolumeClaim:
        claimName: loki-dr
    - name: config
      configMap:
        name: loki-dr-validation-config
    - name: runtime-config
      configMap:
        name: loki-dr-validation-runtime
    - name: tmp
      emptyDir: {}
EOF

echo "Generated: $OUTPUT"
echo
echo "Captured images:"
printf '  %-14s %s\n' "Trilium" "$TRILIUM_IMAGE"
printf '  %-14s %s\n' "Vaultwarden" "$VAULTWARDEN_IMAGE"
printf '  %-14s %s\n' "Portainer" "$PORTAINER_IMAGE"
printf '  %-14s %s\n' "Grafana" "$GRAFANA_IMAGE"
printf '  %-14s %s\n' "Prometheus" "$PROM_IMAGE"
printf '  %-14s %s\n' "Alertmanager" "$ALERT_IMAGE"
printf '  %-14s %s\n' "Loki" "$LOKI_IMAGE"
echo
echo "No Kubernetes resources were applied."
