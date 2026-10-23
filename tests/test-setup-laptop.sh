#!/usr/bin/env bash
# shellcheck disable=SC2016  # the stubs' bodies are meant to stay unexpanded
set -Eeuo pipefail

# scripts/setup-laptop.sh against stubbed tools: a fresh laptop is set up
# from the other laptop's files, a step that needs you waits and then carries
# on, a re-run changes nothing, and nobody answering stops it cleanly.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

export HOME="$T/home" SOURCE_HOME="$T/source-home" REPO="$T/work/k3s-homelab" STATE="$T/state"
export WORK_DIR="$T/work" DOTFILES="$T/no-dotfiles" SETUP_REPO_DIR="$REPO" SETUP_ALLOW_ROOT=1
export BIN="$T/bin"
mkdir -p "$HOME/.ssh" "$SOURCE_HOME/.config/sops/age" "$SOURCE_HOME/.ssh" "$SOURCE_HOME/.kube" \
  "$REPO/scripts" "$STATE" "$BIN"

# The other laptop's files.
echo AGE-SECRET-KEY-TEST >"$SOURCE_HOME/.config/sops/age/keys.txt"
echo PRIVATE-KEY >"$SOURCE_HOME/.ssh/k3s_homelab_ed25519"
echo PUBLIC-KEY >"$SOURCE_HOME/.ssh/k3s_homelab_ed25519.pub"
printf 'Host k3s-dr\n  HostName 192.0.2.127\n' >"$SOURCE_HOME/.ssh/config"
echo KUBECONFIG >"$SOURCE_HOME/.kube/config"
# No iLO file on the source: an optional copy.

# This laptop's own SSH config, which must survive.
printf 'Host personal\n  HostName 192.0.2.1\n' >"$HOME/.ssh/config"

# The repository's own scripts, as stubs that record their calls.
for s in scripts/ensure-ansible-collections.sh scripts/prepare-env.sh workstation-readiness.sh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$STATE/calls"\n' "$s" >"$REPO/$s"
  chmod +x "$REPO/$s"
done
: >"$REPO/requirements.txt"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
stub ssh '
case "$*" in
  *"-T"*git@github.com*) [[ -e "$STATE/github-key" ]] && echo "Hi! You have successfully authenticated" >&2; exit 1 ;;
  *-O\ exit*) exit 0 ;;
  *-fN*) echo "ssh-master $*" >>"$STATE/calls"; exit 0 ;;
esac
exit 0'
# scp -q -o ControlPath=... HOST:REL DEST
stub scp 'src="${@: -2:1}"; dest="${@: -1}"; cp "$SOURCE_HOME/${src#*:}" "$dest" 2>/dev/null'
stub gh 'case "$1 $2" in "auth login") touch "$STATE/github-key"; echo "gh-login" >>"$STATE/calls" ;; esac'
stub git '
if [[ "$1" == clone ]]; then
  mkdir -p "$3/.git"; echo "clone $2" >>"$STATE/calls"
  if [[ "$3" == *k3s-homelab-private ]]; then
    printf "#!/usr/bin/env bash\necho \"k3s-sync \$1\" >>\"\$STATE/calls\"\n[[ \$1 == pull ]] && mkdir -p \"\$REPO/config\" && echo x >\"\$REPO/.secrets.enc\" && echo x >\"\$REPO/config/cluster.env\"\nexit 0\n" >"$3/k3s-sync"
    chmod +x "$3/k3s-sync"
  fi
  exit 0
fi
case "$*" in
  *"remote get-url origin") cat "$STATE/origin" ;;
  *"remote set-url origin "*) echo "${@: -1}" >"$STATE/origin"; echo "set-url ${@: -1}" >>"$STATE/calls" ;;
esac'
stub python3 'mkdir -p .venv/bin; printf "#!/usr/bin/env bash\necho \"pip \$*\" >>\"\$STATE/calls\"\n" >.venv/bin/python; chmod +x .venv/bin/python'
# Fails until $STATE/cluster-up exists, so a test can make you wait.
stub kubectl '[[ -e "$STATE/cluster-up" ]] || { n=$(( $(cat "$STATE/kube-tries" 2>/dev/null || echo 0) + 1 )); echo $n >"$STATE/kube-tries"; (( n > ${KUBE_FAILS:-0} )) || exit 1; }; echo "node-0 Ready"'
for t in curl helm argocd kubectx kubens cilium velero trivy k9s kubeconform sops age direnv jq yq argon2 envsubst; do
  stub "$t" 'exit 0'
done
# The system's own commands, minus every tool the tests stand in for: a real
# gh, kubectl or git on the machine (a CI runner has gh in /usr/bin) must not
# be found once a stub is removed, or the script runs it for real.
SYSBIN="$T/sysbin"
mkdir -p "$SYSBIN"
STUBBED=" gh git ssh scp python3 curl kubectl helm argocd kubectx kubens cilium velero trivy k9s kubeconform sops age direnv jq yq argon2 envsubst pacman sudo yay stow "
for dir in /usr/local/bin /usr/bin /bin; do
  for f in "$dir"/*; do
    name="${f##*/}"
    [[ "$STUBBED" == *" $name "* || -e "$SYSBIN/$name" ]] && continue
    ln -s "$f" "$SYSBIN/$name"
  done
done
export PATH="$BIN:$SYSBIN"

run() {
  local input="$1" out="$2"
  shift 2
  set +e
  printf '%b' "$input" | "$REPO_ROOT/scripts/setup-laptop.sh" --from dev "$@" >"$out" 2>&1
  local rc=$?
  set -e
  return "$rc"
}
fail() { echo "FAIL: $*" >&2; sed -n '1,200p' "$T"/*.out >&2; exit 1; }
mode() { stat -c %a "$1"; }

# 1. A fresh laptop. GitHub needs a key: answer y to gh auth login. The
# cluster is unreachable at first: press Enter once, then it answers.
echo https://github.com/HomeLabJunkie/k3s-homelab >"$STATE/origin"
KUBE_FAILS=1 run 'y\n\nn\n' "$T/fresh.out" || fail "fresh setup exited non-zero"
grep -qx 'RESULT: LAPTOP SET UP' "$T/fresh.out" || fail "fresh setup did not finish"
[[ "$(cat "$HOME/.config/sops/age/keys.txt")" == AGE-SECRET-KEY-TEST ]] || fail "age key not copied"
[[ "$(mode "$HOME/.config/sops/age/keys.txt")" == 600 && "$(mode "$HOME/.ssh/k3s_homelab_ed25519")" == 600 &&
   "$(mode "$HOME/.kube/config")" == 600 && "$(mode "$HOME/.config/sops/age")" == 700 ]] || fail "wrong modes"
[[ "$(head -1 "$HOME/.ssh/config")" == 'Include config.k3s-homelab' ]] || fail "Include not first in ~/.ssh/config"
grep -qx 'Host personal' "$HOME/.ssh/config" || fail "this laptop's own SSH config was lost"
grep -qx 'Host k3s-dr' "$HOME/.ssh/config.k3s-homelab" || fail "cluster hosts not copied"
grep -qF 'SKIP: dev has no ~/.config/ilo-ubuntu-hp' "$T/fresh.out" || fail "optional iLO file not reported"
[[ "$(grep -c '^ssh-master' "$STATE/calls")" == 1 ]] || fail "expected one SSH connection to dev"
grep -qx 'gh-login' "$STATE/calls" || fail "gh auth login not run"
grep -qx 'clone git@github.com:HomeLabJunkie/k3s-homelab-private.git' "$STATE/calls" || fail "private repo not cloned"
grep -qx 'set-url git@github.com:HomeLabJunkie/k3s-homelab.git' "$STATE/calls" || fail "origin not switched to SSH"
grep -qx 'k3s-sync pull' "$STATE/calls" || fail "k3s-sync pull not run"
grep -qx 'scripts/prepare-env.sh ' "$STATE/calls" || fail "prepare-env not run"
if [[ "$(grep -c 'NEEDS YOU' "$T/fresh.out")" != 1 ]] || ! grep -qF 'NEEDS YOU: reach the cluster' "$T/fresh.out"; then
  fail "expected exactly one wait, for the cluster"
fi
if grep -q '^workstation-readiness.sh' "$STATE/calls"; then fail "readiness ran after answering n"; fi
echo "PASS: fresh laptop"

# 2. Again: everything is in place, nothing is copied or cloned twice.
: >"$STATE/calls"
touch "$STATE/cluster-up"
cp "$HOME/.ssh/config" "$T/ssh-config-before"
run '' "$T/rerun.out" --no-readiness || fail "re-run exited non-zero"
grep -qx 'RESULT: LAPTOP SET UP' "$T/rerun.out" || fail "re-run did not finish"
if grep -qE '^(ssh-master|clone|gh-login|set-url)' "$STATE/calls"; then fail "re-run repeated a one-time step"; fi
if grep -q 'NEEDS YOU' "$T/rerun.out"; then fail "re-run asked for something"; fi
cmp -s "$HOME/.ssh/config" "$T/ssh-config-before" || fail "re-run changed ~/.ssh/config"
echo "PASS: re-run is a no-op"

# 3. Nobody answers when a key is missing and dev does not have it: stop,
# say where, exit non-zero.
rm "$HOME/.kube/config" "$SOURCE_HOME/.kube/config"
run '' "$T/stop.out" --no-readiness && fail "carried on without the kubeconfig"
grep -qF 'NEEDS YOU: put the remaining keys in place' "$T/stop.out" || fail "no NEEDS YOU for the missing key"
grep -qF 'Stopped at step 2' "$T/stop.out" || fail "did not say where it stopped"
grep -qF 'Missing: ~/.kube/config' "$T/stop.out" || fail "did not name the missing file"
# Copying the missing key again must not include the cluster hosts twice.
[[ "$(grep -c '^Include config.k3s-homelab' "$HOME/.ssh/config")" == 1 ]] || fail "Include added twice"
echo "PASS: stops cleanly when nobody answers"
echo KUBECONFIG >"$HOME/.kube/config"

# 4. No gh and no GitHub key, as on a brand-new laptop: offer to install gh
# with pacman, then gh auth login.
rm "$BIN/gh" "$STATE/github-key"
: >"$STATE/calls"
stub sudo '"$@"'
stub pacman 'echo "pacman $*" >>"$STATE/calls"; printf "#!/usr/bin/env bash\ncase \"\$1 \$2\" in \"auth login\") touch \"\$STATE/github-key\"; echo gh-login >>\"\$STATE/calls\" ;; esac\n" >"$BIN/gh"; chmod +x "$BIN/gh"'
run 'y\ny\n' "$T/gh.out" --no-readiness || fail "setup without gh exited non-zero"
grep -qx 'pacman -S --needed github-cli' "$STATE/calls" || fail "gh not installed with pacman"
grep -qx 'gh-login' "$STATE/calls" || fail "gh auth login not run after installing gh"
if grep -q 'NEEDS YOU' "$T/gh.out"; then fail "waited although gh could be installed"; fi
echo "PASS: installs gh when it is missing"

# 5. A cluster tool is missing and there are no dotfiles: offer to clone
# them, then run their bootstrap, which installs the tool.
rm "$BIN/helm"
: >"$STATE/calls"
# The dotfiles clone gets a bootstrap.sh that "installs" helm; any other
# git call goes to the git stub from above.
mv "$BIN/git" "$BIN/git-base"
stub git '
if [[ "$1" == clone && "$3" == "$DOTFILES" ]]; then
  mkdir -p "$3"; echo "clone $2" >>"$STATE/calls"
  printf "#!/usr/bin/env bash\necho \"bootstrap \$*\" >>\"\$STATE/calls\"\nprintf \"#!/usr/bin/env bash\\\\nexit 0\\\\n\" >\"\$BIN/helm\"; chmod +x \"\$BIN/helm\"\n" >"$3/bootstrap.sh"
  chmod +x "$3/bootstrap.sh"
  exit 0
fi
exec "$BIN/git-base" "$@"'
run 'y\ny\n' "$T/dotfiles.out" --no-readiness || fail "setup without dotfiles exited non-zero"
grep -qx 'clone git@github.com:HomeLabJunkie/dotfiles.git' "$STATE/calls" || fail "dotfiles not cloned"
grep -qx 'bootstrap --packages' "$STATE/calls" || fail "dotfiles bootstrap not run"
if grep -q 'NEEDS YOU' "$T/dotfiles.out"; then fail "waited although the dotfiles install the tools"; fi
echo "PASS: clones the dotfiles when tools are missing"

echo 'PASS: laptop setup'
