#!/usr/bin/env bash
# shellcheck disable=SC2016  # the stubs' bodies are meant to stay unexpanded
set -Eeuo pipefail

# recovery/dr-host-power.sh on, against a stubbed iLO and SSH: a server that
# is already on with the DR host's VM stopped gets the VM started, and a DR
# host that never answers fails with ssh's own error instead of a bare timeout.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
export STATE="$T/state" BIN="$T/bin"
mkdir -p "$STATE" "$BIN"
printf 'admin\nsecret\n' >"$T/ilo"
chmod 600 "$T/ilo"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
# The server is on; the iLO answers every request.
stub curl 'cat >/dev/null; echo "{\"PowerState\":\"On\"}"'
# k3s-dr answers once its VM runs; ubuntu-hp runs the script on stdin with
# a virsh that knows one stopped autostart VM.
stub ssh '
host=""; for a in "$@"; do case "$a" in k3s-dr|ubuntu-hp) host="$a" ;; esac; done
case "$host" in
  k3s-dr) [[ -e "$STATE/vm-running" ]] && exit 0
    echo "ssh: connect to host 192.0.2.126 port 22: No route to host" >&2; exit 255 ;;
  ubuntu-hp) echo "hypervisor ${*: -1}" >>"$STATE/calls"
    [[ -n "${NO_START:-}" ]] && { cat >/dev/null; exit 0; }
    script="$(cat)"; shift $(( $# - 1 )); set -- ${1#sudo -n bash -s --}
    virsh() { case "$1" in
      list) echo dr-vm ;;
      domstate) [[ -e "$STATE/vm-running" ]] && echo running || echo "shut off" ;;
      start) echo "virsh start $2" >>"$STATE/calls"; touch "$STATE/vm-running" ;;
    esac; }
    eval "$script" ;;
esac'

run() {
  local out="$1"; shift
  set +e
  env PATH="$BIN:$PATH" ENV_FILE=/dev/null DR_ILO_HOST=192.0.2.108 DR_HYPERVISOR_HOST=ubuntu-hp \
    DR_ILO_CREDENTIALS="$T/ilo" WAIT_INTERVAL_SECONDS=1 BOOT_TIMEOUT_SECONDS=3 "$@" \
    "$REPO_ROOT/recovery/dr-host-power.sh" on >"$out" 2>&1
  local rc=$?
  set -e
  return "$rc"
}
fail() { echo "FAIL: $*" >&2; cat "$T"/*.out >&2; exit 1; }

# 1. Server on, VM stopped: the stopped autostart VM is started.
run "$T/start.out" || fail "power-on with a stopped VM failed"
grep -qF 'k3s-dr does not answer: ssh: connect to host 192.0.2.126 port 22: No route to host' "$T/start.out" ||
  fail "did not say why k3s-dr did not answer"
grep -qx 'virsh start dr-vm' "$STATE/calls" || fail "the stopped VM was not started"
grep -qx 'DR host is up.' "$T/start.out" || fail "did not wait for the DR host"
echo "PASS: starts the DR host's VM when the server is already on"

# 2. DR_VM_NAME names the VM to start.
rm -f "$STATE/vm-running" "$STATE/calls"
run "$T/named.out" DR_VM_NAME=k3s-dr-vm || fail "power-on with DR_VM_NAME failed"
grep -qx 'virsh start k3s-dr-vm' "$STATE/calls" || fail "DR_VM_NAME was not started"
rm -f "$STATE/vm-running"
if run "$T/unsafe.out" DR_VM_NAME='x;reboot'; then fail "an unsafe DR_VM_NAME was accepted"; fi
grep -qF 'unsafe DR_VM_NAME value' "$T/unsafe.out" || fail "unsafe DR_VM_NAME not reported"
echo "PASS: starts the VM DR_VM_NAME names"

# 3. The VM cannot be started and the host never answers: fail with ssh's error.
rm -f "$STATE/vm-running"
if run "$T/never.out" NO_START=1; then fail "succeeded although k3s-dr never answered"; fi
grep -qF 'ssh k3s-dr: ssh: connect to host 192.0.2.126 port 22: No route to host' "$T/never.out" ||
  fail "timeout did not show ssh's error"
grep -qF 'timed out after 3s waiting for k3s-dr' "$T/never.out" || fail "no timeout message"
echo "PASS: a DR host that never answers fails with ssh's error"

echo 'PASS: DR host power-on'
