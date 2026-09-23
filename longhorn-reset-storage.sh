#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3S_DIR="${K3S_DIR:-$SCRIPT_DIR}"
INVENTORY="${INVENTORY:-$K3S_DIR/inventory/k3s-ansible/hosts.ini}"

# A missing or unparsable inventory makes ansible match no hosts and still exit
# 0, which would report a reset that never happened.
export ANSIBLE_INVENTORY_UNPARSED_FAILED=true
[[ -r "$INVENTORY" ]] || { echo "ERROR: inventory is missing or unreadable: $INVENTORY" >&2; exit 1; }
mapfile -t hosts < <(ansible all -i "$INVENTORY" --list-hosts 2>/dev/null | sed -n 's/^ \{4,\}//p')
(( ${#hosts[@]} > 0 )) || { echo "ERROR: no hosts found in $INVENTORY" >&2; exit 1; }

cat <<'EOF'
WARNING: THIS DESTROYS ALL LONGHORN DATA UNDER /var/lib/storage
ON EVERY NODE IN THE ANSIBLE INVENTORY.

It does NOT repartition /dev/sda and does NOT touch the OS NVMe disk.
EOF
echo
echo "Inventory: $INVENTORY"
echo "Nodes (${#hosts[@]}):"
printf '  - %s\n' "${hosts[@]}"
echo
read -r -p 'Type RESET-LONGHORN to continue: ' answer
[[ "$answer" == "RESET-LONGHORN" ]] || { echo "Cancelled."; exit 1; }
ansible all -i "$INVENTORY" -b -m shell -a '
set -Eeuo pipefail
storage_src="$(findmnt -n -o SOURCE /var/lib/storage)"
root_src="$(findmnt -n -o SOURCE /)"
test "$storage_src" = "/dev/sda1"
test "$root_src" != "$storage_src"
rm -rf /var/lib/storage/replicas
rm -f /var/lib/storage/longhorn-disk.cfg
mkdir -p /var/lib/storage/longhorn
find /var/lib/storage/longhorn -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
chmod 0755 /var/lib/storage/longhorn
echo "Longhorn storage reset complete on $(hostname)"
findmnt /var/lib/storage
'
echo "Longhorn storage reset completed on ${#hosts[@]} node(s): ${hosts[*]}"
