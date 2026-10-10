#!/usr/bin/env bash
set -Eeuo pipefail

# Power the on-demand DR host on or off. The DR host is a VM on a server that
# stays off between rehearsals; the server's iLO switches it on, and a normal
# OS shutdown switches it off.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

DR_HOST="${DR_HOST:-k3s-dr}"
DR_HYPERVISOR_HOST="${DR_HYPERVISOR_HOST:-}"
DR_ILO_HOST="${DR_ILO_HOST:-}"
DR_ILO_CREDENTIALS="${DR_ILO_CREDENTIALS:-$HOME/.config/ilo-ubuntu-hp}"
SECRETS_FILE="${SECRETS_FILE:-$ROOT_DIR/.secrets.enc}"
ILO_USERNAME=""
ILO_PASSWORD=""
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-600}"
SHUTDOWN_TIMEOUT_SECONDS="${SHUTDOWN_TIMEOUT_SECONDS:-300}"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=6)

usage() {
  cat <<'EOF'
Usage:
  recovery/dr-host-power.sh status
  recovery/dr-host-power.sh on
  recovery/dr-host-power.sh off

  status   Show the server's power state and whether the DR host answers.
  on       Power the server on and wait for the DR host to answer on SSH.
  off      Shut down the VMs and the server, then confirm it is off.

Settings, from config/cluster.env or the environment:
  DR_HOST               SSH alias of the DR host. Default: k3s-dr
  DR_HYPERVISOR_HOST    SSH alias of the server that runs it. Needs
                        passwordless sudo there.
  DR_ILO_HOST           Address of the server's iLO.
  DR_ILO_CREDENTIALS    File with the iLO username on line 1 and the
                        password on line 2, mode 0600.
                        Default: ~/.config/ilo-ubuntu-hp
  SECRETS_FILE          Used when that file does not exist: the sops file
                        holding DR_ILO_USERNAME and DR_ILO_PASSWORD.
                        Default: .secrets.enc in the repository
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_settings() {
  [[ -n "$DR_ILO_HOST" ]] || fail "DR_ILO_HOST is not set"
  [[ -n "$DR_HYPERVISOR_HOST" ]] || fail "DR_HYPERVISOR_HOST is not set"
  [[ "$DR_ILO_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe DR_ILO_HOST value"
  if [[ -e "$DR_ILO_CREDENTIALS" ]]; then
    [[ -r "$DR_ILO_CREDENTIALS" ]] || fail "iLO credentials file is not readable: $DR_ILO_CREDENTIALS"
    [[ "$(stat -c %a "$DR_ILO_CREDENTIALS")" == 600 ]] ||
      fail "iLO credentials file must be mode 0600: $DR_ILO_CREDENTIALS"
  else
    [[ -r "$SECRETS_FILE" ]] ||
      fail "no iLO credentials: neither $DR_ILO_CREDENTIALS nor $SECRETS_FILE exists"
    command -v sops >/dev/null 2>&1 || fail "sops command is required to read $SECRETS_FILE"
  fi
  command -v curl >/dev/null 2>&1 || fail "curl command is required"
  command -v jq >/dev/null 2>&1 || fail "jq command is required"
  load_ilo_credentials
}

# The local file wins, so a power command does not need sops. Without it, for
# example on a replacement laptop, the login comes from the encrypted secrets.
load_ilo_credentials() {
  if [[ -e "$DR_ILO_CREDENTIALS" ]]; then
    { IFS= read -r ILO_USERNAME; IFS= read -r ILO_PASSWORD || [[ -n "$ILO_PASSWORD" ]]; } <"$DR_ILO_CREDENTIALS"
  else
    local decrypted
    decrypted="$(sops --decrypt "$SECRETS_FILE")" || fail "sops could not decrypt $SECRETS_FILE"
    # Only the two iLO values leave the subshell.
    { IFS= read -r ILO_USERNAME; IFS= read -r ILO_PASSWORD; } < <(
      # shellcheck disable=SC1090
      source <(printf '%s\n' "$decrypted")
      printf '%s\n%s\n' "${DR_ILO_USERNAME:-}" "${DR_ILO_PASSWORD:-}"
    )
  fi
  [[ -n "$ILO_USERNAME" && -n "$ILO_PASSWORD" ]] ||
    fail "the iLO username or password is empty (DR_ILO_USERNAME and DR_ILO_PASSWORD in $SECRETS_FILE)"
}

# The credentials reach curl on stdin, so they never appear in a process list.
# iLO ships a self-signed certificate, hence -k.
ilo() {
  printf 'user = "%s:%s"\n' "${ILO_USERNAME//\"/\\\"}" "${ILO_PASSWORD//\"/\\\"}" |
    curl -sk -m 20 -K - "$@"
}

power_state() {
  ilo "https://$DR_ILO_HOST/redfish/v1/Systems/1/" | jq -r '.PowerState // .Power // "unknown"'
}

dr_host_answers() {
  ssh "${SSH_OPTIONS[@]}" "$DR_HOST" true >/dev/null 2>&1
}

wait_for() {
  local description="$1" timeout="$2"
  shift 2
  local waited=0
  until "$@"; do
    (( waited < timeout )) || fail "timed out after ${timeout}s waiting for $description"
    sleep 10
    waited=$((waited + 10))
  done
}

server_is_off() {
  [[ "$(power_state)" == Off ]]
}

cmd_status() {
  echo "Server power: $(power_state)"
  if dr_host_answers; then
    echo "DR host $DR_HOST: answers on SSH"
  else
    echo "DR host $DR_HOST: unreachable"
  fi
}

cmd_on() {
  if [[ "$(power_state)" == On ]]; then
    echo "Server is already on."
  else
    echo "==> Powering the server on..."
    [[ "$(ilo -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
          -d '{"ResetType":"On"}' \
          "https://$DR_ILO_HOST/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/")" == 200 ]] ||
      fail "the iLO refused the power-on request"
  fi
  echo "==> Waiting for $DR_HOST to answer on SSH..."
  wait_for "$DR_HOST" "$BOOT_TIMEOUT_SECONDS" dr_host_answers
  echo "DR host is up."
}

cmd_off() {
  if server_is_off; then
    echo "Server is already off."
    return 0
  fi
  echo "==> Shutting down the VMs and the server..."
  ssh "${SSH_OPTIONS[@]}" "$DR_HYPERVISOR_HOST" 'sudo -n bash -s' <<'REMOTE'
set -Eeuo pipefail
mapfile -t running < <(virsh list --name --state-running | sed '/^$/d')
for domain in "${running[@]}"; do
  virsh shutdown "$domain" >/dev/null
done
for _ in $(seq 1 30); do
  [[ -z "$(virsh list --name --state-running | sed '/^$/d')" ]] && break
  sleep 5
done
[[ -z "$(virsh list --name --state-running | sed '/^$/d')" ]] || {
  echo "ERROR: a VM did not shut down; leaving the server on" >&2
  exit 1
}
systemctl poweroff
REMOTE
  wait_for "the server to power off" "$SHUTDOWN_TIMEOUT_SECONDS" server_is_off
  echo "Server is off."
}

(( $# == 1 )) || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage ;;
  status) require_settings; cmd_status ;;
  on) require_settings; cmd_on ;;
  off) require_settings; cmd_off ;;
  *) usage >&2; exit 2 ;;
esac
