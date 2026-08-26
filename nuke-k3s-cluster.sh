#!/usr/bin/env bash
# nuke-k3s-cluster.sh
# Run from vostro. Wipes k3s + related state from every node listed below,
# then reboots each one so it comes back as a clean Ubuntu host.
#
# Requires: key-based SSH to each node as $SSH_USER, passwordless sudo there.
#
# ⚠️  DESTRUCTIVE. Obliterates, on every node:
#       /etc/rancher  /var/lib/rancher  /var/lib/kubelet
#       /etc/cni  /opt/cni  /var/lib/cni
#       /var/lib/longhorn   <-- ALL Longhorn replica data on that node
#     If Longhorn is backed by a separate disk/mount (e.g. /mnt/longhorn),
#     edit LONGHORN_PATHS below.

set -uo pipefail

# ========== EDIT ME ==========
NODES=(
  "k3s-node-0"
  "k3s-node-1"
  "k3s-node-2"
  "k3s-node-3"
  "k3s-node-4"
  "k3s-node-5"
)
SSH_USER="${SSH_USER:-jeff}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15"
REBOOT="${REBOOT:-yes}"       # "no" to skip reboot
REBOOT_TIMEOUT="${REBOOT_TIMEOUT:-300}"   # seconds to wait for a node to come back
PARALLEL="${PARALLEL:-yes}"   # "no" for serial (easier to read logs)
LONGHORN_PATHS=("/var/lib/longhorn")   # add extra paths if you relocated replicas
# =============================

# --- the cleanup script that runs on each node ---
read -r -d '' REMOTE_SCRIPT <<EOSH || true
#!/usr/bin/env bash
set -uo pipefail
H=\$(hostname)

echo "==> [\$H] stopping k3s services"
sudo systemctl stop k3s k3s-agent k3s-node 2>/dev/null || true
sudo systemctl disable k3s k3s-agent k3s-node 2>/dev/null || true

echo "==> [\$H] killing residual processes"
sudo pkill -9 -f 'k3s server|k3s agent|containerd-shim|kube-proxy|kubelet|cilium-agent|longhorn|flanneld' 2>/dev/null || true
sleep 2

echo "==> [\$H] unmounting k3s/kubelet mounts (deepest first)"
for m in \$(mount | awk '{print \$3}' | grep -E '^/(run/k3s|var/lib/kubelet|var/lib/rancher/k3s)' | sort -r); do
  sudo umount -f "\$m" 2>/dev/null || sudo umount -l "\$m" 2>/dev/null || true
done

echo "==> [\$H] removing binaries and systemd units"
sudo rm -f /usr/local/bin/k3s /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr
sudo rm -f /etc/systemd/system/k3s.service /etc/systemd/system/k3s-agent.service /etc/systemd/system/k3s-node.service
sudo rm -f /etc/systemd/system/k3s.service.env /etc/systemd/system/k3s-agent.service.env /etc/systemd/system/k3s-node.service.env
sudo rm -f /etc/systemd/system/multi-user.target.wants/k3s.service
sudo rm -f /etc/systemd/system/multi-user.target.wants/k3s-agent.service
sudo rm -f /etc/systemd/system/multi-user.target.wants/k3s-node.service
sudo rm -f /usr/local/lib/systemd/system/k3s.service /usr/local/lib/systemd/system/k3s-agent.service /usr/local/lib/systemd/system/k3s-node.service
sudo rm -f /usr/local/lib/systemd/system/k3s.service.env /usr/local/lib/systemd/system/k3s-agent.service.env /usr/local/lib/systemd/system/k3s-node.service.env
sudo rm -f /usr/lib/systemd/system/k3s.service /usr/lib/systemd/system/k3s-agent.service /usr/lib/systemd/system/k3s-node.service
sudo systemctl daemon-reload
sudo systemctl reset-failed 2>/dev/null || true

echo "==> [\$H] removing data directories"
sudo rm -rf /etc/rancher /var/lib/rancher
sudo rm -rf /var/lib/kubelet /var/lib/cni
sudo rm -rf /etc/cni /opt/cni
sudo rm -rf /run/k3s /run/flannel
sudo rm -rf /sys/fs/bpf/tc /sys/fs/bpf/cilium
for p in ${LONGHORN_PATHS[@]}; do
  sudo rm -rf "\$p" 2>/dev/null || true
done

echo "==> [\$H] flushing iptables / ip6tables"
for t in filter nat mangle raw; do
  sudo iptables  -t \$t -F 2>/dev/null || true
  sudo iptables  -t \$t -X 2>/dev/null || true
  sudo ip6tables -t \$t -F 2>/dev/null || true
  sudo ip6tables -t \$t -X 2>/dev/null || true
done

echo "==> [\$H] removing CNI/overlay interfaces"
for iface in cni0 flannel.1 flannel-v6.1 cilium_host cilium_net cilium_vxlan kube-ipvs0; do
  sudo ip link delete "\$iface" 2>/dev/null || true
done

echo "==> [\$H] cleanup complete"
EOSH

run_on_node() {
  local node="$1"
  # run the cleanup
  ssh $SSH_OPTS "${SSH_USER}@${node}" "bash -s" <<< "$REMOTE_SCRIPT" 2>&1 \
    | sed "s/^/[$node] /"
  local rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    echo "!!! [$node] cleanup exited $rc"
    return $rc
  fi

  if [[ "$REBOOT" == "yes" ]]; then
    echo "[$node] scheduling reboot in 2s"
    # systemd-run lets the SSH session exit cleanly before reboot fires
    ssh $SSH_OPTS "${SSH_USER}@${node}" \
      "sudo systemd-run --on-active=2s --unit=nuke-reboot systemctl reboot" \
      >/dev/null 2>&1 || true
  fi
}

wait_for_reboot() {
  local node="$1"
  local start=$(date +%s)
  local probe="ssh -o ConnectTimeout=3 -o BatchMode=yes $SSH_OPTS ${SSH_USER}@${node} true"

  echo "[$node] waiting for node to go down..."
  local down_deadline=$(($(date +%s) + 60))
  while $probe 2>/dev/null; do
    if (( $(date +%s) > down_deadline )); then
      echo "!!! [$node] still up after 60s -- reboot didn't take?"
      return 1
    fi
    sleep 2
  done

  echo "[$node] down, waiting for it to come back..."
  while ! $probe 2>/dev/null; do
    if (( $(date +%s) - start > REBOOT_TIMEOUT )); then
      echo "!!! [$node] did not return within ${REBOOT_TIMEOUT}s"
      return 1
    fi
    sleep 5
  done
  echo "[$node] back online after $(($(date +%s) - start))s"
}

verify_node() {
  local node="$1"
  ssh -o ConnectTimeout=5 $SSH_OPTS "${SSH_USER}@${node}" 'bash -s' <<'EOVR' 2>&1 | sed "s/^/[$node] /"
echo "uptime: $(uptime -p) (booted $(uptime -s))"
check() { # $1=path-or-bin  $2=label  $3=type (dir|bin|mount)
  case "$3" in
    bin)   command -v "$1" >/dev/null 2>&1 && echo "  ✗ $2 still present" || echo "  ✓ $2 gone" ;;
    dir)   [ -d "$1" ] && echo "  ✗ $2 still present ($1)" || echo "  ✓ $2 gone" ;;
    mount) mount | grep -q " $1 " && echo "  ✗ $2 still mounted" || echo "  ✓ no $2 mounts" ;;
  esac
}
check k3s                   "k3s binary"         bin
check kubectl               "kubectl binary"     bin
check /etc/rancher          "/etc/rancher"       dir
check /var/lib/rancher      "/var/lib/rancher"   dir
check /var/lib/kubelet      "/var/lib/kubelet"   dir
check /etc/cni              "/etc/cni"           dir
check /opt/cni              "/opt/cni"           dir
if [ -d /var/lib/longhorn ] && [ -n "$(ls -A /var/lib/longhorn 2>/dev/null)" ]; then
  echo "  ✗ /var/lib/longhorn not empty"
else
  echo "  ✓ /var/lib/longhorn empty or gone"
fi
# systemd shouldn't know about k3s anymore
if systemctl list-unit-files 2>/dev/null | grep -qE '^k3s'; then
  echo "  ✗ k3s systemd unit still registered"
else
  echo "  ✓ no k3s systemd units"
fi
# no k3s-related interfaces
if ip link show 2>/dev/null | grep -qE '(cni0|flannel|cilium|kube-ipvs)'; then
  echo "  ✗ CNI/overlay interface still present"
else
  echo "  ✓ no CNI/overlay interfaces"
fi
EOVR
}

echo "Target nodes:"
printf '  - %s\n' "${NODES[@]}"
echo "SSH user : $SSH_USER"
echo "Reboot   : $REBOOT"
echo "Parallel : $PARALLEL"
echo
read -r -p "Type YES to proceed: " confirm
[[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }

if [[ "$PARALLEL" == "yes" ]]; then
  pids=()
  for node in "${NODES[@]}"; do
    run_on_node "$node" &
    pids+=($!)
  done
  fail=0
  for pid in "${pids[@]}"; do
    wait "$pid" || fail=$((fail+1))
  done
  echo
  echo "Done. $fail node(s) reported errors."
else
  for node in "${NODES[@]}"; do
    run_on_node "$node" || echo "!!! $node failed, continuing"
  done
fi

echo
echo "All cleanup commands dispatched."

if [[ "$REBOOT" == "yes" ]]; then
  echo
  echo "=== Waiting for nodes to come back ==="
  if [[ "$PARALLEL" == "yes" ]]; then
    pids=()
    for node in "${NODES[@]}"; do
      wait_for_reboot "$node" &
      pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done
  else
    for node in "${NODES[@]}"; do
      wait_for_reboot "$node" || true
    done
  fi

  echo
  echo "=== Verification ==="
  # Serial so output per node stays grouped
  for node in "${NODES[@]}"; do
    verify_node "$node"
    echo
  done
fi

echo "Done."
