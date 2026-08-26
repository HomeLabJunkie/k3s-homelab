#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${HOME}/k3s"
SRC="${REPO}/systemd"
DST="${HOME}/.config/systemd/user"

for f in k3s-dr-backup.service k3s-dr-backup.timer k3s-dr-verify.service k3s-dr-verify.timer; do
  [[ -f "${SRC}/${f}" ]] || { echo "ERROR: missing ${SRC}/${f}"; exit 1; }
done

if ! sudo -n true 2>/dev/null; then
  cat <<'EOF'
ERROR: scheduled backup currently needs non-interactive sudo because backup.sh
mounts/unmounts NFS and writes root-owned recovery files.

Do not enable the timers yet. First either:
  1. configure the backup NFS mount and permissions so backup.sh needs no sudo, or
  2. configure narrowly-scoped passwordless sudo for only the required backup commands.

Manual backup/verification remains fully usable.
EOF
  exit 1
fi

mkdir -p "$DST"
cp "${SRC}/k3s-dr-"* "$DST/"

systemctl --user daemon-reload
systemctl --user enable --now k3s-dr-backup.timer k3s-dr-verify.timer

echo
systemctl --user list-timers 'k3s-dr-*'
echo
echo "For timers to run while you are logged out, enable user lingering once:"
echo "  sudo loginctl enable-linger ${USER}"
