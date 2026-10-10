#!/usr/bin/env bash
set -Eeuo pipefail

# A throwaway six-node cluster on the DR hypervisor, for testing a fresh
# bootstrap with site.yml without touching production. The VMs sit on their
# own NAT network: they can reach the internet to download K3s and images,
# and are firewalled off from every private network, including the LAN.
#
# The cluster gets its own random token and its own addresses. Nothing from
# production is copied into it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

DR_HYPERVISOR_HOST="${DR_HYPERVISOR_HOST:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/k3s_homelab_ed25519.pub}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-${SSH_PUBLIC_KEY%.pub}}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/k3s-homelab/dr-test-cluster}"
SUBNET=10.90.0
SERVERS=(11 12 13)
WORKERS=(21 22 23)
TEST_VIP="$SUBNET.50"
TEST_LB_RANGE="$SUBNET.60-$SUBNET.80"

usage() {
  cat <<'EOF'
Usage:
  recovery/dr-test-cluster.sh create      Create the network and six VMs
  recovery/dr-test-cluster.sh bootstrap   Run site.yml against them
  recovery/dr-test-cluster.sh status      Show VMs and, if built, the nodes
  recovery/dr-test-cluster.sh destroy     Delete the VMs, disks and network

Settings, from config/cluster.env or the environment:
  DR_HYPERVISOR_HOST   SSH alias of the DR hypervisor. Needs passwordless
                       sudo there.
  SSH_PUBLIC_KEY       Public key the VMs trust.
                       Default: ~/.ssh/k3s_homelab_ed25519.pub
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -n "$DR_HYPERVISOR_HOST" ]] || fail "DR_HYPERVISOR_HOST is not set"
HYPERVISOR=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$DR_HYPERVISOR_HOST")
# The VMs are only reachable through the hypervisor. Their host keys change on
# every rebuild, so they are kept in a file of their own.
VM_SSH_ARGS="-o ProxyJump=$DR_HYPERVISOR_HOST -o IdentitiesOnly=yes -i $SSH_PRIVATE_KEY -o UserKnownHostsFile=$STATE_DIR/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"

vm_ssh() {
  local address="$1"
  shift
  # shellcheck disable=SC2086,SC2029 # options are split on purpose; commands run remotely
  ssh $VM_SSH_ARGS "jeff@$address" "$@"
}

cmd_create() {
  local public_key
  [[ -r "$SSH_PUBLIC_KEY" ]] || fail "public key is not readable: $SSH_PUBLIC_KEY"
  public_key="$(<"$SSH_PUBLIC_KEY")"
  # A private key must never be handed to cloud-init.
  [[ "$public_key" =~ ^ssh-(ed25519|rsa)\ AAAA[A-Za-z0-9+/=]+ ]] && [[ "$public_key" != *PRIVATE* ]] ||
    fail "$SSH_PUBLIC_KEY does not hold a public key"
  mkdir -p "$STATE_DIR"
  rm -f "$STATE_DIR/known_hosts"

  "${HYPERVISOR[@]}" "sudo -n bash -s -- $(printf '%q ' "$SUBNET" "$public_key" "${SERVERS[*]}" "${WORKERS[*]}")" <<'REMOTE'
set -Eeuo pipefail
subnet="$1" public_key="$2"
read -r -a servers <<<"$3"
read -r -a workers <<<"$4"
image=/tank/vm/images/ubuntu-26.04-server-cloudimg-amd64.img
[[ -s "$image" ]] || { echo "ERROR: base image is missing: $image" >&2; exit 1; }

if ! virsh net-info k3s-test >/dev/null 2>&1; then
  definition="$(mktemp)"
  cat >"$definition" <<EOF
<network>
  <name>k3s-test</name>
  <forward mode='nat'/>
  <bridge name='virbr-k3stest' stp='on' delay='0'/>
  <ip address='${subnet}.1' netmask='255.255.255.0'/>
</network>
EOF
  virsh net-define "$definition" >/dev/null
  rm -f "$definition"
fi
virsh net-autostart k3s-test >/dev/null
virsh net-list --name | grep -qx k3s-test || virsh net-start k3s-test >/dev/null

# The test VMs may reach the internet but no private network. This table is
# separate from libvirt's own rules and is reloaded on boot.
cat >/etc/nftables.d-k3s-test.nft <<EOF
table inet k3s_test_isolation
delete table inet k3s_test_isolation
table inet k3s_test_isolation {
  chain forward {
    type filter hook forward priority -10; policy accept;
    ip saddr ${subnet}.0/24 ip daddr ${subnet}.0/24 accept
    ip saddr ${subnet}.0/24 ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } drop
  }
  chain input {
    type filter hook input priority -10; policy accept;
    ip saddr ${subnet}.0/24 ip daddr != ${subnet}.1 ip daddr != 255.255.255.255 drop
  }
}
EOF
nft -f /etc/nftables.d-k3s-test.nft
cat >/etc/systemd/system/k3s-test-isolation.service <<'EOF'
[Unit]
Description=Firewall the k3s-test VM network off from private networks
Before=libvirtd.service virtqemud.service
After=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d-k3s-test.nft

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q k3s-test-isolation.service

zfs list tank/vm/k3s-test >/dev/null 2>&1 || zfs create tank/vm/k3s-test

create_vm() {
  local name="$1" address="$2" memory="$3"
  if virsh dominfo "$name" >/dev/null 2>&1; then
    echo "  $name already exists"
    return 0
  fi
  local dir=/tank/vm/k3s-test seed
  seed="$(mktemp -d)"
  qemu-img create -q -f qcow2 -F qcow2 -b "$image" "$dir/$name.qcow2" 40G
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$name" "$(date +%s)" "$name" >"$seed/meta-data"
  cat >"$seed/network-config" <<EOF
version: 2
ethernets:
  lan:
    match:
      name: "en*"
    dhcp4: false
    addresses: [${address}/24]
    routes:
      - to: default
        via: ${subnet}.1
    nameservers:
      addresses: [1.1.1.1, 9.9.9.9]
EOF
  cat >"$seed/user-data" <<EOF
#cloud-config
hostname: ${name}
manage_etc_hosts: true
timezone: America/Chicago
users:
  - name: jeff
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${public_key}
    sudo: "ALL=(ALL) NOPASSWD:ALL"
ssh_pwauth: false
package_update: true
packages: [open-iscsi, nfs-common, curl, python3]
EOF
  cloud-localds -N "$seed/network-config" "$dir/$name-seed.iso" "$seed/user-data" "$seed/meta-data"
  rm -rf "$seed"
  virt-install --name "$name" --memory "$memory" --vcpus 2 --cpu host-passthrough \
    --os-variant ubuntu24.04 --import --boot uefi \
    --disk "path=$dir/$name.qcow2,bus=virtio,cache=none,discard=unmap" \
    --disk "path=$dir/$name-seed.iso,device=cdrom" \
    --network network=k3s-test,model=virtio \
    --graphics none --console pty,target_type=serial --noautoconsole >/dev/null
  echo "  $name created at $address"
}

index=0
for host in "${servers[@]}"; do
  create_vm "k3s-test-server-$index" "$subnet.$host" 6144
  index=$((index + 1))
done
index=0
for host in "${workers[@]}"; do
  create_vm "k3s-test-worker-$index" "$subnet.$host" 4096
  index=$((index + 1))
done
REMOTE

  echo "==> Waiting for the VMs to finish first boot..."
  local host address waited
  for host in "${SERVERS[@]}" "${WORKERS[@]}"; do
    address="$SUBNET.$host"
    waited=0
    until vm_ssh "$address" 'cloud-init status --wait >/dev/null 2>&1; true' 2>/dev/null; do
      (( waited < 420 )) || fail "$address did not come up"
      sleep 10
      waited=$((waited + 10))
    done
    echo "  $address ready"
  done

  echo "==> Checking isolation from the first VM..."
  # shellcheck disable=SC2016 # expanded on the VM
  vm_ssh "$SUBNET.${SERVERS[0]}" '
    curl -fsS -m 10 -o /dev/null https://get.k3s.io && echo "  internet: reachable"
    for target in 192.168.1.3 192.168.1.8 192.168.1.210 192.168.1.250; do
      if ping -c1 -W2 "$target" >/dev/null 2>&1; then
        echo "  LAN $target: REACHABLE"
        exit 1
      fi
    done
    echo "  LAN: unreachable"'
}

write_inventory() {
  local inventory="$STATE_DIR/inventory"
  mkdir -p "$inventory"
  {
    echo "[master]"
    printf "$SUBNET.%s\n" "${SERVERS[@]}"
    echo
    echo "[node]"
    printf "$SUBNET.%s\n" "${WORKERS[@]}"
    echo
    echo "[k3s_cluster:children]"
    echo "master"
    echo "node"
    echo
    echo "[k3s_cluster:vars]"
    echo "ansible_ssh_common_args=$VM_SSH_ARGS"
  } >"$inventory/hosts.ini"
  # Reuse the production group_vars so the test exercises the real settings.
  ln -sfn "$ROOT_DIR/inventory/k3s-ansible/group_vars" "$inventory/group_vars"
  echo "$inventory/hosts.ini"
}

cmd_bootstrap() {
  command -v ansible-playbook >/dev/null 2>&1 || fail "ansible-playbook is required (activate .venv)"
  [[ -d "$STATE_DIR" ]] || fail "run create first"
  local inventory token_file
  inventory="$(write_inventory)"
  token_file="$STATE_DIR/token"
  if [[ ! -s "$token_file" ]]; then
    ( umask 077; head -c 24 /dev/urandom | base64 | tr -d '/+=' >"$token_file" )
  fi
  cd "$ROOT_DIR"
  # site.yml fetches the new cluster's kubeconfig into the repository. Keep
  # the test cluster's copy out of the way of the real one.
  local saved_kubeconfig=""
  if [[ -e kubeconfig ]]; then
    saved_kubeconfig="$STATE_DIR/kubeconfig.production"
    mv -- kubeconfig "$saved_kubeconfig"
  fi
  # shellcheck disable=SC2064 # expand the saved path now
  trap "[[ -e kubeconfig ]] && mv -- kubeconfig '$STATE_DIR/kubeconfig.test'; [[ -n '$saved_kubeconfig' ]] && mv -- '$saved_kubeconfig' kubeconfig; true" EXIT
  # The VMs have one NIC, named enp1s0, where production uses eno1.
  K3S_TOKEN="$(<"$token_file")" KUBE_VIP="$TEST_VIP" METALLB_IP_RANGE="$TEST_LB_RANGE" \
    ansible-playbook -i "$inventory" site.yml \
      -e cilium_iface=enp1s0 -e flannel_iface=enp1s0
  cmd_status
}

cmd_status() {
  "${HYPERVISOR[@]}" 'sudo -n virsh list --all | grep -E "k3s-test|Name" || echo "no test VMs"'
  if [[ -d "$STATE_DIR" ]] && vm_ssh "$SUBNET.${SERVERS[0]}" 'command -v k3s' >/dev/null 2>&1; then
    vm_ssh "$SUBNET.${SERVERS[0]}" 'sudo k3s kubectl get nodes -o wide; sudo k3s secrets-encrypt status | head -3'
  fi
}

cmd_destroy() {
  "${HYPERVISOR[@]}" 'sudo -n bash -s' <<'REMOTE'
set -Eeuo pipefail
for name in $(virsh list --all --name | grep '^k3s-test-' || true); do
  virsh destroy "$name" >/dev/null 2>&1 || true
  virsh undefine "$name" --nvram >/dev/null
  echo "  removed $name"
done
if zfs list tank/vm/k3s-test >/dev/null 2>&1; then
  zfs destroy -r tank/vm/k3s-test
fi
if virsh net-info k3s-test >/dev/null 2>&1; then
  virsh net-destroy k3s-test >/dev/null 2>&1 || true
  virsh net-undefine k3s-test >/dev/null
fi
systemctl disable -q k3s-test-isolation.service 2>/dev/null || true
rm -f /etc/systemd/system/k3s-test-isolation.service /etc/nftables.d-k3s-test.nft
nft delete table inet k3s_test_isolation 2>/dev/null || true
systemctl daemon-reload
REMOTE
  rm -rf -- "$STATE_DIR"
  echo "Test cluster removed."
}

(( $# == 1 )) || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage ;;
  create) cmd_create ;;
  bootstrap) cmd_bootstrap ;;
  status) cmd_status ;;
  destroy) cmd_destroy ;;
  *) usage >&2; exit 2 ;;
esac
