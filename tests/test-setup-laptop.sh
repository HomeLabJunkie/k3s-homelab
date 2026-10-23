#!/usr/bin/env bash
# shellcheck disable=SC2016  # the stubs' bodies are meant to stay unexpanded
set -Eeuo pipefail

# scripts/setup-laptop.sh against stubbed tools: a fresh laptop is set up
# from the other laptop's files, a step that needs you waits and then carries
# on, a re-run changes nothing, and nobody answering stops it cleanly.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

# Where the script looks for the age key; the machine's own (a CI runner sets
# XDG_CONFIG_HOME) would point it outside the test's home.
unset XDG_CONFIG_HOME SOPS_AGE_KEY_FILE
export HOME="$T/home" SOURCE_HOME="$T/source-home" REPO="$T/work/k3s-homelab" STATE="$T/state"
export WORK_DIR="$T/work" DOTFILES="$T/no-dotfiles" SETUP_REPO_DIR="$REPO" SETUP_ALLOW_ROOT=1
export BIN="$T/bin"
mkdir -p "$HOME/.ssh" "$SOURCE_HOME/.config/sops/age" "$SOURCE_HOME/.ssh" "$SOURCE_HOME/.kube" \
  "$REPO/scripts" "$STATE" "$BIN"

# The other laptop's files.
echo AGE-SECRET-KEY-TEST >"$SOURCE_HOME/.config/sops/age/keys.txt"
echo PRIVATE-KEY >"$SOURCE_HOME/.ssh/k3s_homelab_ed25519"
echo PUBLIC-KEY >"$SOURCE_HOME/.ssh/k3s_homelab_ed25519.pub"
# Its SSH config: hosts to copy with their keys, and its own defaults, a
# host this laptop already defines and its personal key, which are not.
cat >"$SOURCE_HOME/.ssh/config" <<'EOF'
Host *
  ServerAliveInterval 60
Include config.laptops

Host k3s-dr
  HostName 192.0.2.127
  IdentityFile ~/.ssh/k3s_homelab_ed25519
# The DR server
Host ubuntu-hp
    HostName 192.0.2.250
    User sysop
    IdentityFile ~/.ssh/ubuntu_hp_ed25519
    IdentitiesOnly yes
Host personal
  HostName 192.0.2.99
Host gitbox
  IdentityFile ~/.ssh/id_ed25519
Match host other
  User someone
Host laptop-*
  User me
EOF
echo HP-PRIVATE-KEY >"$SOURCE_HOME/.ssh/ubuntu_hp_ed25519"
echo HP-PUBLIC-KEY >"$SOURCE_HOME/.ssh/ubuntu_hp_ed25519.pub"
echo DEV-OWN-KEY >"$SOURCE_HOME/.ssh/id_ed25519"
echo KUBECONFIG >"$SOURCE_HOME/.kube/config"
# No iLO file on the source: an optional copy.
printf '# comment\ngithub.com ssh-ed25519 GITHUBKEY\nk3s-dr ssh-ed25519 DRKEY\n192.0.2.11 ssh-ed25519 NODEKEY\n' \
  >"$SOURCE_HOME/.ssh/known_hosts"

# This laptop's own SSH config and a host it already trusts, which must survive.
printf 'Host personal\n  HostName 192.0.2.1\n' >"$HOME/.ssh/config"
printf 'personal ssh-ed25519 PERSONALKEY\ngithub.com ssh-ed25519 GITHUBKEY\n' >"$HOME/.ssh/known_hosts"

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
  *authorized_keys*) cat >>"$STATE/source-authorized-keys"; exit 0 ;;
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
  "-C "*" status --porcelain"*) cat "$STATE/dotfiles-status" 2>/dev/null ;;
  "-C "*" add "*|"-C "*" commit "*|"-C "*" push"*) echo "git ${*:3}" >>"$STATE/calls"
    if [[ "$3" == commit ]]; then rm -f "$STATE/dotfiles-status"; fi ;;
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
STUBBED=" gh git ssh scp ssh-keygen systemctl python3 curl kubectl helm argocd kubectx kubens cilium cilium-cli velero trivy k9s kubeconform sops age direnv jq yq argon2 envsubst pacman sudo yay stow hostnamectl age-keygen "
for dir in /usr/local/bin /usr/bin /bin; do
  for f in "$dir"/*; do
    name="${f##*/}"
    [[ "$STUBBED" == *" $name "* || -e "$SYSBIN/$name" || -L "$SYSBIN/$name" ]] && continue
    ln -s "$f" "$SYSBIN/$name"
  done
done
export PATH="$BIN:$SYSBIN"
stub hostnamectl 'echo newlaptop'
# Writes a key pair where -f says, as ssh-keygen -q -t ed25519 -N "" would.
stub ssh-keygen 'f=""; c=""; while (( $# )); do case "$1" in -f) f="$2"; shift ;; -C) c="$2"; shift ;; esac; shift; done
[[ -n "$f" ]] || exit 1
umask 077; echo PRIVATE-KEY >"$f"; echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST $c" >"$f.pub"'
# Records calls; the dotfiles-sync timer counts as enabled once enabled.
stub systemctl '
echo "systemctl $*" >>"$STATE/calls"
case "$*" in
  *"is-enabled"*dotfiles-sync.timer*) [[ -e "$STATE/sync-timer-on" ]] ;;
  *"enable --now dotfiles-sync.timer"*) touch "$STATE/sync-timer-on" ;;
esac'

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
[[ "$(cat "$HOME/.ssh/config.k3s-homelab")" == "Host k3s-dr
  HostName 192.0.2.127
  IdentityFile ~/.ssh/k3s_homelab_ed25519

Host ubuntu-hp
    HostName 192.0.2.250
    User sysop
    IdentityFile ~/.ssh/ubuntu_hp_ed25519
    IdentitiesOnly yes

Host gitbox
  IdentityFile ~/.ssh/id_ed25519" ]] || fail "SSH hosts not copied host by host"
[[ "$(cat "$HOME/.ssh/ubuntu_hp_ed25519")" == HP-PRIVATE-KEY && "$(mode "$HOME/.ssh/ubuntu_hp_ed25519")" == 600 &&
   "$(mode "$HOME/.ssh/ubuntu_hp_ed25519.pub")" == 644 ]] || fail "ubuntu-hp's key not copied"
[[ "$(cat "$HOME/.ssh/id_ed25519")" != DEV-OWN-KEY ]] || fail "dev's own id_ed25519 was copied"
grep -qF 'added 3 SSH host(s) from dev' "$T/fresh.out" || fail "SSH host merge not reported"
grep -qF 'SKIP: dev has no ~/.config/ilo-ubuntu-hp' "$T/fresh.out" || fail "optional iLO file not reported"
[[ "$(mode "$HOME/.ssh/id_ed25519")" == 600 ]] || fail "this laptop's own SSH key not created"
cmp -s "$HOME/.ssh/id_ed25519.pub" "$STATE/source-authorized-keys" || fail "this laptop's key not added to dev's authorized_keys"
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
[[ "$(cat "$HOME/.ssh/known_hosts")" == "personal ssh-ed25519 PERSONALKEY
github.com ssh-ed25519 GITHUBKEY
k3s-dr ssh-ed25519 DRKEY
192.0.2.11 ssh-ed25519 NODEKEY" ]] || fail "dev's host keys not added to known_hosts exactly once, keeping this laptop's"
grep -qF "trusted 2 host key(s) that dev already trusts" "$T/fresh.out" || fail "known_hosts merge not reported"
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
grep -qF "known_hosts already has the host keys dev trusts" "$T/rerun.out" || fail "re-run did not check known_hosts"
[[ "$(wc -l <"$HOME/.ssh/known_hosts")" == 4 ]] || fail "re-run added host keys twice"
grep -qF "already has every host dev has" "$T/rerun.out" || fail "re-run did not check dev's SSH hosts"
echo "PASS: re-run is a no-op"

# 2b. As on the Vostro: k3s-dr is defined but ubuntu-hp and its key are not.
# Setup notices and adds just those.
printf 'Host k3s-dr\n  HostName 192.0.2.127\n' >"$HOME/.ssh/config.k3s-homelab"
rm "$HOME/.ssh/ubuntu_hp_ed25519" "$HOME/.ssh/ubuntu_hp_ed25519.pub"
: >"$STATE/calls"
run '' "$T/vostro.out" --no-readiness || fail "setup without ubuntu-hp exited non-zero"
grep -qx 'Host ubuntu-hp' "$HOME/.ssh/config.k3s-homelab" || fail "ubuntu-hp not added"
[[ "$(grep -c '^Host k3s-dr' "$HOME/.ssh/config.k3s-homelab")" == 1 ]] || fail "k3s-dr added twice"
[[ -e "$HOME/.ssh/ubuntu_hp_ed25519" ]] || fail "ubuntu-hp's key not copied"
if grep -q 'NEEDS YOU' "$T/vostro.out"; then fail "waited although dev has ubuntu-hp"; fi
echo "PASS: adds the hosts a laptop is missing"

# 2c. A host added on dev later reaches a set-up laptop on its next run,
# without a password. dev's own id_ed25519 is never copied, even when this
# laptop has none.
printf 'Host newbox\n  HostName 192.0.2.5\n' >>"$SOURCE_HOME/.ssh/config"
mv "$HOME/.ssh/id_ed25519" "$T/own-key"
: >"$STATE/calls"
run '' "$T/newbox.out" --no-readiness || fail "setup with a new host on dev exited non-zero"
grep -qx 'Host newbox' "$HOME/.ssh/config.k3s-homelab" || fail "new host on dev not added"
[[ ! -e "$HOME/.ssh/id_ed25519" ]] || fail "dev's own id_ed25519 was copied"
mv "$T/own-key" "$HOME/.ssh/id_ed25519"
if grep -q '^ssh-master' "$STATE/calls"; then fail "opened a password connection for a set-up laptop"; fi
echo "PASS: a host added on dev later reaches the laptop"

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
  printf "mkdir -p \"\$HOME/.config/systemd/user\"; touch \"\$HOME/.config/systemd/user/dotfiles-sync.timer\"\n" >>"$3/bootstrap.sh"
  mkdir -p "$3/machines/dev" && printf ".config/hypr/monitors.lua\n.config/omarchy/shell.json\n" >"$3/machines/dev/local-only.txt"
  exit 0
fi
exec "$BIN/git-base" "$@"'
# Answers: clone the dotfiles, create this laptop's local-only.txt, run bootstrap.
run 'y\ny\ny\n' "$T/dotfiles.out" --no-readiness || fail "setup without dotfiles exited non-zero"
grep -qx 'clone git@github.com:HomeLabJunkie/dotfiles.git' "$STATE/calls" || fail "dotfiles not cloned"
grep -qx 'bootstrap --packages' "$STATE/calls" || fail "dotfiles bootstrap not run"
if grep -q 'NEEDS YOU' "$T/dotfiles.out"; then fail "waited although the dotfiles install the tools"; fi
echo "PASS: clones the dotfiles when tools are missing"

# 6. That run also gave this laptop its machines/<hostname>/local-only.txt,
# before bootstrap linked anything, and published it after.
cmp -s "$DOTFILES/machines/dev/local-only.txt" "$DOTFILES/machines/newlaptop/local-only.txt" ||
  fail "machines/newlaptop/local-only.txt not copied from dev"
expected="git add machines/newlaptop/local-only.txt
git commit -q -m machines/newlaptop: keep the per-laptop files local, like dev
git push -q"
[[ "$(grep '^git ' "$STATE/calls")" == "$expected" ]] || fail "local-only.txt not committed and pushed"
[[ "$(grep -nE '^bootstrap|^git add' "$STATE/calls" | cut -d: -f2 | cut -c1-9)" == "bootstrap
git add m" ]] || fail "expected bootstrap before the commit (git needs the linked config)"
created_at="$(grep -nF 'created machines/newlaptop/local-only.txt' "$T/dotfiles.out" | cut -d: -f1)"
bootstrap_at="$(grep -nF 'bootstrap.sh --packages now?' "$T/dotfiles.out" | cut -d: -f1)"
if [[ -z "$created_at" || -z "$bootstrap_at" ]] || (( created_at > bootstrap_at )); then
  fail "local-only.txt must exist before bootstrap.sh links anything"
fi
cp "$STATE/calls" "$STATE/calls.first"
: >"$STATE/calls"
run '' "$T/dotfiles-again.out" --no-readiness || fail "re-run with dotfiles exited non-zero"
grep -qF 'the dotfiles already have machines/newlaptop/local-only.txt' "$T/dotfiles-again.out" ||
  fail "re-run did not see the existing local-only.txt"
if grep -q '^git ' "$STATE/calls"; then fail "re-run committed again"; fi
echo "PASS: gives a new laptop its own local-only.txt in the dotfiles"

# 7. Bootstrap linked the dotfiles-sync timer; the first run turned it on and
# synced once, the re-run left it alone.
grep -qx 'systemctl --user enable --now dotfiles-sync.timer' "$STATE/calls.first" ||
  fail "dotfiles-sync timer not turned on"
grep -qx 'systemctl --user start dotfiles-sync.service' "$STATE/calls.first" ||
  fail "no first sync after turning the timer on"
grep -qF 'turned on the dotfiles-sync timer' "$T/dotfiles.out" || fail "timer not reported"
if grep -q 'enable --now' "$STATE/calls"; then fail "re-run turned the timer on again"; fi
grep -qF 'the dotfiles-sync timer is already on' "$T/dotfiles-again.out" || fail "re-run did not see the timer on"
echo "PASS: turns on the dotfiles-sync timer"

# 8. The Cilium CLI is missing (or named cilium-cli): a note, not a wait.
rm "$BIN/cilium"
run '' "$T/no-cilium.out" --no-readiness || fail "setup waited for the cilium CLI"
grep -qF 'NOTE: no cilium or cilium-cli command' "$T/no-cilium.out" || fail "no note about the missing cilium CLI"
if grep -q 'NEEDS YOU' "$T/no-cilium.out"; then fail "waited for an optional tool"; fi
stub cilium-cli 'exit 0'
run '' "$T/cilium-cli.out" --no-readiness || fail "setup failed with cilium-cli"
if grep -q 'NOTE: no cilium' "$T/cilium-cli.out"; then fail "cilium-cli was not accepted"; fi
echo "PASS: the cilium CLI is optional, under either name"

# 8. The dotfiles have laptop-ssh: offer to start sshd, run laptop-ssh, and
# publish the keys it wrote. Once they are pushed, a re-run changes nothing.
mkdir -p "$DOTFILES/shell/.local/bin"
printf '#!/usr/bin/env bash\necho laptop-ssh >>"$STATE/calls"\n[[ -e "$STATE/keys-written" ]] || { touch "$STATE/keys-written"; echo "?? machines/newlaptop/ssh/" >"$STATE/dotfiles-status"; }\n' \
  >"$DOTFILES/shell/.local/bin/laptop-ssh"
chmod +x "$DOTFILES/shell/.local/bin/laptop-ssh"
stub systemctl 'echo "systemctl $*" >>"$STATE/calls"
[[ "$1" == is-enabled ]] && { [[ -e "$STATE/sshd-on" ]]; exit; }
[[ "$*" == "enable --now sshd" ]] && touch "$STATE/sshd-on"
exit 0'
: >"$STATE/calls"
run 'y\n' "$T/laptop-ssh.out" --no-readiness || fail "setup with laptop-ssh exited non-zero"
grep -qx 'systemctl enable --now sshd' "$STATE/calls" || fail "sshd not started after answering y"
grep -qx 'laptop-ssh' "$STATE/calls" || fail "laptop-ssh not run"
expected="git add -- machines/newlaptop/ssh
git commit -q -m machines/newlaptop: publish this laptop's SSH keys, so the other laptops let it in
git push -q"
[[ "$(grep '^git ' "$STATE/calls")" == "$expected" ]] || fail "this laptop's SSH keys not committed and pushed"
: >"$STATE/calls"
run '' "$T/laptop-ssh-again.out" --no-readiness || fail "re-run with laptop-ssh exited non-zero"
grep -qx 'laptop-ssh' "$STATE/calls" || fail "re-run did not run laptop-ssh"
if grep -qE '^git |enable --now' "$STATE/calls"; then fail "re-run published or started sshd again"; fi
grep -qF "the dotfiles already have this laptop's SSH keys" "$T/laptop-ssh-again.out" || fail "re-run did not see the published keys"
echo "PASS: publishes this laptop's SSH keys for the other laptops"

# 10. The laptop already had an age key, but not the one .secrets.enc is for.
# Step 2 leaves it alone; step 7 notices, and on y replaces it with dev's,
# keeping the old one.
stub sops '[[ "$1" == --decrypt ]] && grep -qx AGE-SECRET-KEY-TEST "$HOME/.config/sops/age/keys.txt"'
stub age-keygen 'grep -q AGE-SECRET-KEY-TEST "$2" && echo age1good || echo age1wrong'
echo AGE-SECRET-KEY-OLD >"$HOME/.config/sops/age/keys.txt"
run 'y\n' "$T/age.out" --no-readiness || fail "setup with the wrong age key exited non-zero"
[[ "$(cat "$HOME/.config/sops/age/keys.txt")" == AGE-SECRET-KEY-TEST ]] || fail "age key not replaced with dev's"
[[ "$(cat "$HOME/.config/sops/age/keys.txt.bak")" == AGE-SECRET-KEY-OLD ]] || fail "old age key not kept"
[[ "$(mode "$HOME/.config/sops/age/keys.txt")" == 600 ]] || fail "replaced age key is not mode 600"
grep -qF 'this laptop has:     age1wrong' "$T/age.out" || fail "did not show the laptop's age key"
grep -qF 'sops decrypts .secrets.enc' "$T/age.out" || fail "did not confirm decryption"

# With --no-copy and nobody answering, it stops at step 7 and says why.
echo AGE-SECRET-KEY-OLD >"$HOME/.config/sops/age/keys.txt"
run '' "$T/age-stop.out" --no-copy --no-readiness && fail "carried on with the wrong age key"
grep -qF 'NEEDS YOU: give this laptop the age key .secrets.enc is encrypted for' "$T/age-stop.out" ||
  fail "no NEEDS YOU for the wrong age key"
grep -qF 'Stopped at step 7' "$T/age-stop.out" || fail "did not stop at step 7"
cp "$SOURCE_HOME/.config/sops/age/keys.txt" "$HOME/.config/sops/age/keys.txt"
echo "PASS: checks the age key opens .secrets.enc"

echo 'PASS: laptop setup'
