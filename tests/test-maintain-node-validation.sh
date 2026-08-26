#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/fixture"
MOCK_BIN="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"
TARGET="192.0.2.10"

mkdir -p \
  "$FIXTURE_ROOT/config" \
  "$FIXTURE_ROOT/inventory/k3s-ansible" \
  "$FIXTURE_ROOT/maintenance" \
  "$FIXTURE_ROOT/scripts" \
  "$MOCK_BIN" \
  "$STATE_DIR"

: >"$FIXTURE_ROOT/config/cluster.env"
: >"$FIXTURE_ROOT/.secrets"
: >"$FIXTURE_ROOT/inventory/k3s-ansible/hosts.ini"
: >"$FIXTURE_ROOT/maintenance/reconcile-k3s-agent.yml"
: >"$FIXTURE_ROOT/maintenance/reconcile-k3s-server.yml"

cat >"$FIXTURE_ROOT/scripts/check-ansible-toolchain.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$FIXTURE_ROOT/scripts/ensure-ansible-collections.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$FIXTURE_ROOT/repo-doctor.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$MOCK_BIN/ansible" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$MOCK_BIN/ansible-inventory" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_NODE_TYPE:-worker}" == "control-plane" ]]; then
  printf '{"master":{"hosts":["%s"]},"node":{"hosts":[]}}\n' "$MOCK_TARGET"
else
  printf '{"master":{"hosts":[]},"node":{"hosts":["%s"]}}\n' "$MOCK_TARGET"
fi
EOF

cat >"$MOCK_BIN/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == "--check" ]] && exit 0
done
touch "$MOCK_STATE_DIR/live"
exit 0
EOF

cat >"$MOCK_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
set -u

scenario="${MOCK_SCENARIO:-success}"
live=false
[[ -f "$MOCK_STATE_DIR/live" ]] && live=true
args=" $* "

if [[ "$args" == *" get --raw=/readyz "* ]]; then
  if [[ "$live" == true && "$scenario" == "api" ]]; then
    exit 1
  fi
  echo ok
  exit 0
fi

if [[ "$args" == *" get nodes -o wide --no-headers "* ]]; then
  printf 'mock-node Ready none 1d v1 %s none Linux kernel runtime\n' "$MOCK_TARGET"
  exit 0
fi

if [[ "$args" == *" get node mock-node "* ]]; then
  if [[ "$live" == true && "$scenario" == "node" ]]; then
    printf False
  else
    printf True
  fi
  exit 0
fi

if [[ "$args" == *" k8s-app=cilium "* ]]; then
  if [[ "$live" == true && "$scenario" == "cilium" ]]; then
    echo 'cilium-mock 0/1 CrashLoopBackOff 1 1m'
  else
    echo 'cilium-mock 1/1 Running 0 1m'
  fi
  exit 0
fi

if [[ "$args" == *" name=kube-vip-ds "* ]]; then
  if [[ "$live" == true && "$scenario" == "kube-vip" ]]; then
    echo 'kube-vip-mock 0/1 CrashLoopBackOff 1 1m'
  else
    echo 'kube-vip-mock 1/1 Running 0 1m'
  fi
  exit 0
fi

if [[ "$args" == *" volumes.longhorn.io "* ]]; then
  if [[ "$live" == true && "$scenario" == "longhorn" ]]; then
    echo 'attached degraded pvc-mock'
  else
    echo 'attached healthy pvc-mock'
  fi
  exit 0
fi

echo "unexpected kubectl invocation: $*" >&2
exit 1
EOF

chmod +x \
  "$FIXTURE_ROOT/repo-doctor.sh" \
  "$FIXTURE_ROOT/scripts/check-ansible-toolchain.sh" \
  "$FIXTURE_ROOT/scripts/ensure-ansible-collections.sh" \
  "$MOCK_BIN/ansible" \
  "$MOCK_BIN/ansible-inventory" \
  "$MOCK_BIN/ansible-playbook" \
  "$MOCK_BIN/kubectl"

pass_count=0
fail_count=0

run_case() {
  local name="$1"
  local scenario="$2"
  local node_type="$3"
  local expected_rc="$4"
  local expected_text="$5"
  local output_file="$TEST_ROOT/$name.out"
  local rc

  rm -f "$STATE_DIR/live"

  set +e
  PATH="$MOCK_BIN:$PATH" \
    ROOT_DIR="$FIXTURE_ROOT" \
    MOCK_STATE_DIR="$STATE_DIR" \
    MOCK_TARGET="$TARGET" \
    MOCK_SCENARIO="$scenario" \
    MOCK_NODE_TYPE="$node_type" \
    POST_MAINTENANCE_VALIDATION_ATTEMPTS=1 \
    POST_MAINTENANCE_VALIDATION_INTERVAL_SECONDS=0 \
    "$REPO_ROOT/maintain-node.sh" "$TARGET" --apply --yes \
      >"$output_file" 2>&1
  rc=$?
  set -e

  if (( rc == expected_rc )) && grep -qF "$expected_text" "$output_file"; then
    echo "PASS: $name"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $name (expected rc=$expected_rc and '$expected_text', got rc=$rc)"
    sed -n '1,260p' "$output_file"
    fail_count=$((fail_count + 1))
  fi
}

run_case success success worker 0 'POST-MAINTENANCE VALIDATION: PASS'
run_case api-failure api worker 1 'FAIL: API /readyz'
run_case node-failure node worker 1 'FAIL: Target node'
run_case cilium-failure cilium worker 1 'FAIL: Cilium'
run_case kube-vip-failure kube-vip control-plane 1 'FAIL: kube-vip'
run_case longhorn-failure longhorn worker 1 'FAIL: Longhorn volumes'

echo
echo "Validation tests: $pass_count passed, $fail_count failed"
(( fail_count == 0 ))
