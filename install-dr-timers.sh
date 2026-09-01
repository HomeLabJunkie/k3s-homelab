#!/usr/bin/env bash
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${REPO}/systemd"
DST="${HOME}/.config/systemd/user"

UNITS=(
  k3s-dr-backup.service
  k3s-dr-backup.timer
  k3s-dr-verify.service
  k3s-dr-verify.timer
  k3s-dr-monitor.service
  k3s-dr-monitor.timer
)

for f in "${UNITS[@]}"; do
  [[ -f "${SRC}/${f}" ]] || { echo "ERROR: missing ${SRC}/${f}"; exit 1; }
done

mkdir -p "$DST"
cp "${UNITS[@]/#/${SRC}/}" "$DST/"

systemctl --user daemon-reload
systemctl --user enable --now \
  k3s-dr-backup.timer \
  k3s-dr-verify.timer \
  k3s-dr-monitor.timer

echo
systemctl --user list-timers 'k3s-dr-*'
echo
echo "Timers are persistent and catch up after the user session starts."
echo "For execution before login, enable user lingering once:"
echo "  sudo loginctl enable-linger ${USER}"
