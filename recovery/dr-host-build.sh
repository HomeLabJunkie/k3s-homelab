#!/usr/bin/env bash
set -Eeuo pipefail

# Build the single-node K3s + Cilium + Longhorn DR host that dr-rehearsal.sh
# restores into. Run from the operator laptop against a freshly installed
# Ubuntu machine. Safe to re-run: every step converges.
#
# The versions and the Longhorn backup target are read from production, so the
# DR host always matches the cluster it has to recover.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DR_HOST="${DR_HOST:-k3s-dr}"
DR_NODE_NAME="${DR_NODE_NAME:-k3s-dr}"
LONGHORN_BACKUP_SECRET="${LONGHORN_BACKUP_SECRET:-longhorn-backup-cifs}"
HELPER_DIR=/usr/local/libexec/k3s-dr
HELPERS=(dr-preflight.sh dr-validate-generated.sh dr-apply-restore.sh
         dr-bind-restores.sh dr-apply-validation.sh dr-validate-apps.sh
         dr-cleanup.sh dr-sync-helpers.sh dr-migrate-longhorn-target.sh)
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$DR_HOST")

usage() {
  cat <<'EOF'
Usage:
  recovery/dr-host-build.sh [--lock-sudo]

Builds or converges the DR host named by DR_HOST (default: the k3s-dr SSH
alias). The host needs Ubuntu, key-based SSH and passwordless sudo while it
is being built.

Options:
  --lock-sudo   After a successful build, restrict passwordless sudo on the
                DR host to the DR helpers. General sudo then needs a
                password, so set one first if you want to keep it.

Environment overrides:
  DR_HOST                 SSH host or alias. Default: k3s-dr
  DR_NODE_NAME            Kubernetes node name. Default: k3s-dr
  K3S_VERSION             Default: the production server version
  CILIUM_VERSION          Default: the production Cilium chart version
  LONGHORN_VERSION        Default: the production Longhorn chart version
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

LOCK_SUDO=false
while (( $# > 0 )); do
  case "$1" in
    --lock-sudo) LOCK_SUDO=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown option: $1" ;;
  esac
  shift
done

for command in kubectl helm jq ssh scp; do
  command -v "$command" >/dev/null 2>&1 || fail "$command command is required"
done

release_version() {
  helm list -A -o json | jq -r --arg name "$1" '.[] | select(.name == $name) | .app_version' | sed 's/^v//'
}

echo "==> Reading versions and backup target from production..."
K3S_VERSION="${K3S_VERSION:-$(kubectl version -o json | jq -r .serverVersion.gitVersion)}"
CILIUM_VERSION="${CILIUM_VERSION:-$(release_version cilium)}"
LONGHORN_VERSION="${LONGHORN_VERSION:-$(release_version longhorn)}"
BACKUP_TARGET="$(kubectl -n longhorn-system get backuptarget default -o jsonpath='{.spec.backupTargetURL}')"
[[ "$K3S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || fail "unexpected K3s version: $K3S_VERSION"
[[ "$CILIUM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unexpected Cilium version: $CILIUM_VERSION"
[[ "$LONGHORN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unexpected Longhorn version: $LONGHORN_VERSION"
[[ -n "$BACKUP_TARGET" ]] || fail "production has no Longhorn backup target"
echo "    K3s $K3S_VERSION, Cilium $CILIUM_VERSION, Longhorn $LONGHORN_VERSION"
echo "    backup target: $BACKUP_TARGET"

"${SSH[@]}" 'sudo -n true' || fail "passwordless sudo is unavailable on $DR_HOST"
DR_IP="$("${SSH[@]}" "ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p'")"
[[ "$DR_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "could not determine the DR host address"
if kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' |
    tr ' ' '\n' | grep -qx "$DR_IP"; then
  fail "$DR_HOST ($DR_IP) is a production node"
fi
echo "==> Building $DR_HOST ($DR_IP) as node $DR_NODE_NAME..."

echo "==> Preparing the host..."
"${SSH[@]}" 'sudo -n bash -s' <<'REMOTE'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
missing=()
for package in open-iscsi nfs-common cifs-utils cryptsetup jq curl; do
  dpkg -s "$package" >/dev/null 2>&1 || missing+=("$package")
done
if (( ${#missing[@]} > 0 )); then
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}" >/dev/null
fi
printf 'iscsi_tcp\ndm_crypt\n' >/etc/modules-load.d/longhorn.conf
modprobe iscsi_tcp
modprobe dm_crypt
printf 'fs.inotify.max_user_instances = 8192\nfs.inotify.max_user_watches = 524288\n' \
  >/etc/sysctl.d/99-inotify.conf
sysctl -q --system
systemctl enable -q --now iscsid
swapoff -a
mkdir -p /var/lib/longhorn /etc/rancher/k3s /var/lib/rancher/k3s/server/manifests
REMOTE

echo "==> Installing K3s $K3S_VERSION..."
"${SSH[@]}" "sudo -n bash -s -- $(printf '%q %q %q %q %q' \
  "$K3S_VERSION" "$DR_NODE_NAME" "$DR_IP" "$CILIUM_VERSION" "$LONGHORN_VERSION")" <<'REMOTE'
set -Eeuo pipefail
k3s_version="$1" node_name="$2" node_ip="$3" cilium_version="$4" longhorn_version="$5"

cat >/etc/rancher/k3s/config.yaml <<EOF
node-name: ${node_name}
node-ip: ${node_ip}
advertise-address: ${node_ip}
write-kubeconfig-mode: "0600"
disable:
  - servicelb
  - traefik
disable-network-policy: true
flannel-backend: none
EOF

# K3s applies these on start. Cilium is a bootstrap chart because nothing else
# can schedule until the node has a CNI.
cat >/var/lib/rancher/k3s/server/manifests/dr-cilium.yaml <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: cilium
  namespace: kube-system
spec:
  repo: https://helm.cilium.io/
  chart: cilium
  version: ${cilium_version}
  targetNamespace: kube-system
  bootstrap: true
  valuesContent: |-
    operator:
      replicas: 1
    ipam:
      operator:
        clusterPoolIPv4PodCIDRList: ["10.42.0.0/16"]
EOF
cat >/var/lib/rancher/k3s/server/manifests/dr-longhorn.yaml <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: longhorn
  namespace: kube-system
spec:
  repo: https://charts.longhorn.io
  chart: longhorn
  version: ${longhorn_version}
  targetNamespace: longhorn-system
  createNamespace: true
  valuesContent: |-
    persistence:
      defaultClassReplicaCount: 1
    defaultSettings:
      defaultReplicaCount: 1
    longhornUI:
      replicas: 1
    csi:
      attacherReplicaCount: 1
      provisionerReplicaCount: 1
      resizerReplicaCount: 1
      snapshotterReplicaCount: 1
EOF

installed="$(/usr/local/bin/k3s --version 2>/dev/null | awk 'NR==1 {print $3}' || true)"
if [[ "$installed" != "$k3s_version" ]]; then
  curl -sfL https://get.k3s.io |
    INSTALL_K3S_VERSION="$k3s_version" INSTALL_K3S_EXEC=server sh -s - >/dev/null
else
  systemctl enable -q --now k3s
fi

for _ in $(seq 1 90); do
  [[ "$(k3s kubectl get --raw=/readyz 2>/dev/null)" == ok ]] && break
  sleep 2
done
[[ "$(k3s kubectl get --raw=/readyz)" == ok ]]
REMOTE

dr_kubectl() {
  "${SSH[@]}" "sudo -n k3s kubectl $(printf '%q ' "$@")"
}

echo "==> Waiting for the node, Cilium and Longhorn..."
dr_kubectl wait --for=condition=Ready "node/$DR_NODE_NAME" --timeout=600s
dr_kubectl -n kube-system rollout status daemonset/cilium --timeout=600s
for _ in $(seq 1 120); do
  dr_kubectl -n longhorn-system get daemonset/longhorn-manager >/dev/null 2>&1 && break
  sleep 5
done
dr_kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=900s
dr_kubectl -n longhorn-system rollout status deployment/longhorn-driver-deployer --timeout=900s

echo "==> Pointing Longhorn at the production backup target..."
# The credential goes from one cluster to the other through a pipe and is
# never written to disk or shown.
kubectl -n longhorn-system get secret "$LONGHORN_BACKUP_SECRET" -o json |
  jq '{apiVersion, kind, type, data, metadata: {name: .metadata.name, namespace: .metadata.namespace}}' |
  "${SSH[@]}" 'sudo -n k3s kubectl apply -f - >/dev/null'
for _ in $(seq 1 60); do
  dr_kubectl -n longhorn-system get backuptarget default >/dev/null 2>&1 && break
  sleep 5
done
dr_kubectl -n longhorn-system patch backuptarget default --type merge -p \
  "{\"spec\":{\"backupTargetURL\":\"$BACKUP_TARGET\",\"credentialSecret\":\"$LONGHORN_BACKUP_SECRET\",\"pollInterval\":\"5m0s\"}}" >/dev/null
dr_kubectl -n longhorn-system wait --for=jsonpath='{.status.available}'=true \
  backuptarget/default --timeout=15m

echo "==> Installing the DR helpers..."
"${SSH[@]}" 'rm -rf /tmp/k3s-dr-sync && mkdir -m 700 /tmp/k3s-dr-sync'
scp -q -o BatchMode=yes "${HELPERS[@]/#/$SCRIPT_DIR/}" "$DR_HOST:/tmp/k3s-dr-sync/"
"${SSH[@]}" "sudo -n bash -s -- $(printf '%q ' "$HELPER_DIR" "${HELPERS[@]}")" <<'REMOTE'
set -Eeuo pipefail
destination="$1"
shift
install -d -o root -g root -m 0755 "$destination"
for name in "$@"; do
  install -o root -g root -m 0755 "/tmp/k3s-dr-sync/$name" "$destination/$name"
done
rm -rf /tmp/k3s-dr-sync
REMOTE

if [[ "$LOCK_SUDO" == true ]]; then
  echo "==> Restricting passwordless sudo to the DR helpers..."
  "${SSH[@]}" "sudo -n bash -s -- $(printf '%q ' "$HELPER_DIR" "${HELPERS[@]}")" <<'REMOTE'
set -Eeuo pipefail
destination="$1"
shift
user="${SUDO_USER:?}"
commands=""
for name in "$@"; do
  commands+="${commands:+, }${destination}/${name}"
done
candidate="$(mktemp)"
printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$commands" >"$candidate"
visudo -cf "$candidate" >/dev/null
install -o root -g root -m 0440 "$candidate" /etc/sudoers.d/k3s-dr-helpers
rm -f "$candidate"
# Drop any blanket rule left by the installer, but only once the helper rule
# is in place and valid.
for file in /etc/sudoers.d/*; do
  [[ "$file" == /etc/sudoers.d/k3s-dr-helpers ]] && continue
  if grep -qE "^${user}[[:space:]].*NOPASSWD:[[:space:]]*ALL[[:space:]]*$" "$file"; then
    rm -f "$file"
  fi
done
visudo -c >/dev/null
REMOTE
fi

echo "==> Running the DR preflight..."
"${SSH[@]}" "sudo -n $HELPER_DIR/dr-preflight.sh"
