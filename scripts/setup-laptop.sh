#!/usr/bin/env bash
# shellcheck disable=SC2088  # "~/..." appears only in messages, for reading
set -Eeuo pipefail

# Sets up a new laptop to run the cluster, from a laptop that already does:
# the steps in docs/laptop-setup.md, in order. Each step is skipped when it is
# already done, so it is safe to run again. When a step needs you, the script
# says what to do and waits; press Enter to check again, or q to stop.
#
# Start it on the new laptop with:
#   git clone https://github.com/HomeLabJunkie/k3s-homelab.git ~/Work/k3s-homelab
#   ~/Work/k3s-homelab/scripts/setup-laptop.sh --from dev

REPO_DIR="${SETUP_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK_DIR="${WORK_DIR:-$HOME/Work}"
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
GITHUB_OWNER=HomeLabJunkie
FROM=dev
COPY_KEYS=true
READINESS=ask

usage() {
  cat <<'EOF'
Usage:
  scripts/setup-laptop.sh [--from HOST] [--no-copy] [--readiness | --no-readiness]

Options:
  --from HOST       The laptop to copy the keys from, as an SSH host
                    (user@address works). Default: dev
  --no-copy         Do not copy anything; wait for you to put the keys in
                    place instead.
  --readiness       Run ./workstation-readiness.sh at the end without asking.
  --no-readiness    Skip it.
  -h, --help        Show this help.

It copies from the other laptop, over one SSH connection (its password is
asked once): the age key, the cluster SSH key and the hosts in ~/.ssh/config,
the kubeconfig and the iLO login. It also adds this laptop's own SSH key
(~/.ssh/id_ed25519, created if missing) to the other laptop's authorized_keys,
and publishes it in the dotfiles so every laptop lets it in. A file already
on this laptop is never replaced. The GitHub login stays this laptop's own: the script offers to run
`gh auth login` for it.

Environment overrides:
  WORK_DIR   Where the repositories live. Default: ~/Work
  DOTFILES   The dotfiles checkout. Default: ~/dotfiles
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --from) FROM="${2:?--from needs a host}"; shift 2 ;;
    --no-copy) COPY_KEYS=false; shift ;;
    --readiness) READINESS=yes; shift ;;
    --no-readiness) READINESS=no; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# The keys and repositories belong to your user. SETUP_ALLOW_ROOT is for the
# tests, which may run as root in a container.
(( EUID != 0 )) || [[ "${SETUP_ALLOW_ROOT:-}" == 1 ]] ||
  { echo "ERROR: run this as your own user, not root" >&2; exit 1; }

TMP="$(mktemp -d)"
SSH_CONTROL="$TMP/ssh-control"
cleanup() {
  ssh -o ControlPath="$SSH_CONTROL" -O exit "$FROM" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT
HOST="$(hostnamectl --static 2>/dev/null || uname -n)"

STEP=0
step() {
  STEP=$((STEP + 1))
  echo
  echo "============================================================"
  echo " $STEP. $*"
  echo "============================================================"
}
ok() { echo "OK: $*"; }

# Reads one answer. Fails when there is nobody to answer (end of input).
ask() {
  local reply
  printf '%s ' "$1"
  IFS= read -r reply || { echo; return 1; }
  REPLY="$reply"
}

# Waits for you until the check passes: need WHAT HOW CHECK-COMMAND...
need() {
  local what="$1" how="$2"
  shift 2
  until "$@"; do
    echo
    echo ">>> NEEDS YOU: $what"
    printf '%s\n' "$how" | sed 's/^/    /'
    if ! ask "Press Enter when that is done to check again (q to stop):" || [[ "$REPLY" == q ]]; then
      echo
      echo "Stopped at step $STEP: $what"
      echo "Run scripts/setup-laptop.sh again to carry on from here."
      exit 1
    fi
  done
}

yes_no() {
  ask "$1 [y/N]" || return 1
  [[ "$REPLY" == [yY]* ]]
}

# --- 1. ------------------------------------------------------------------
step "Basic tools"
missing_basics() {
  local c missing=()
  for c in git ssh scp python3 curl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  (( ${#missing[@]} == 0 )) && return 0
  echo "Missing: ${missing[*]}"
  return 1
}
need "install the basic tools" \
  "Install git, openssh, python and curl with the system's package manager
(on Omarchy or Arch: sudo pacman -S --needed git openssh python curl)." \
  missing_basics
ok "git, ssh, scp, python3 and curl are installed"
[[ "$REPO_DIR" == "$WORK_DIR/k3s-homelab" ]] ||
  echo "NOTE: this checkout is $REPO_DIR; the DR timers and docs expect $WORK_DIR/k3s-homelab"

# --- 2. ------------------------------------------------------------------
step "Keys from $FROM"
# path relative to the home directory, mode, required
KEY_FILES=(
  ".config/sops/age/keys.txt 600 required"
  ".ssh/k3s_homelab_ed25519 600 required"
  ".ssh/k3s_homelab_ed25519.pub 644 optional"
  ".kube/config 600 required"
  ".config/ilo-ubuntu-hp 600 optional"
)

source_ssh() {
  ssh -o ControlPath="$SSH_CONTROL" "$@"
}

# One connection, kept open for the copies, so a password is asked only once.
connect_source() {
  ssh -o ControlMaster=yes -o ControlPath="$SSH_CONTROL" -o ControlPersist=15m \
    -o ConnectTimeout=10 -fN "$FROM"
}

copy_from_source() {
  local rel="$1" mode="$2" dest="$HOME/$1"
  [[ -e "$dest" ]] && { ok "~/$rel already here; left as it is"; return 0; }
  scp -q -o ControlPath="$SSH_CONTROL" "$FROM:$rel" "$TMP/copy" 2>/dev/null || return 1
  mkdir -p "$(dirname "$dest")"
  chmod 700 "$(dirname "$dest")"
  install -m "$mode" "$TMP/copy" "$dest"
  rm -f "$TMP/copy"
  ok "copied ~/$rel from $FROM"
}

# The node, k3s-dr and ubuntu-hp entries. Kept in a file of their own and
# included, so this laptop's own ~/.ssh/config is not overwritten.
has_cluster_ssh_config() {
  grep -qsE '^[[:space:]]*Host[[:space:]].*\bk3s-dr\b' "$HOME/.ssh/config" "$HOME/.ssh/config.k3s-homelab"
}
copy_ssh_config() {
  has_cluster_ssh_config && { ok "~/.ssh/config already has the cluster hosts"; return 0; }
  scp -q -o ControlPath="$SSH_CONTROL" "$FROM:.ssh/config" "$TMP/ssh-config" 2>/dev/null || return 1
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  install -m 600 "$TMP/ssh-config" "$HOME/.ssh/config.k3s-homelab"
  if [[ -f "$HOME/.ssh/config" ]]; then
    # Include must come before any Host block to apply everywhere.
    { echo "Include config.k3s-homelab"; echo; cat "$HOME/.ssh/config"; } >"$TMP/merged"
    install -m 600 "$TMP/merged" "$HOME/.ssh/config"
  else
    printf 'Include config.k3s-homelab\n' >"$TMP/merged"
    install -m 600 "$TMP/merged" "$HOME/.ssh/config"
  fi
  ok "added $FROM's SSH hosts as ~/.ssh/config.k3s-homelab (included from ~/.ssh/config)"
}

# This laptop's own key, added to $FROM's authorized_keys so it can log in
# there from now on. The dotfiles hand it to the other laptops (laptop-ssh).
ensure_laptop_key() {
  [[ -f "$HOME/.ssh/id_ed25519.pub" ]] && return 0
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N "" -C "${USER:-$(id -un)}@$HOST" -f "$HOME/.ssh/id_ed25519" </dev/null || return 1
  ok "created ~/.ssh/id_ed25519, this laptop's own SSH key"
}
authorize_on_source() {
  # shellcheck disable=SC2016  # expanded on $FROM, not here
  source_ssh "$FROM" 'umask 077; mkdir -p ~/.ssh; k=$(cat); grep -qxF "$k" ~/.ssh/authorized_keys 2>/dev/null || printf "%s\n" "$k" >>~/.ssh/authorized_keys' \
    <"$HOME/.ssh/id_ed25519.pub" || return 1
  ok "this laptop can now log in to $FROM with ~/.ssh/id_ed25519"
}

all_keys_present() {
  local entry rel missing=()
  for entry in "${KEY_FILES[@]}"; do
    read -r rel _ need_it <<<"$entry"
    [[ "$need_it" == required && ! -e "$HOME/$rel" ]] && missing+=("~/$rel")
  done
  has_cluster_ssh_config || missing+=("the cluster hosts in ~/.ssh/config")
  (( ${#missing[@]} == 0 )) && return 0
  echo "Missing: ${missing[*]}"
  return 1
}

if all_keys_present >/dev/null; then
  ok "the keys are already in place"
elif [[ "$COPY_KEYS" == true ]]; then
  need "let this laptop log in to $FROM over SSH" \
    "The script opens one SSH connection to $FROM and asks for its password if
it needs one. If $FROM cannot be reached by that name, run the script again
with --from user@address, or allow password login on $FROM." \
    connect_source
  { ensure_laptop_key && authorize_on_source; } ||
    echo "WARNING: could not add this laptop's SSH key to $FROM's ~/.ssh/authorized_keys"
  for entry in "${KEY_FILES[@]}"; do
    read -r rel mode need_it <<<"$entry"
    copy_from_source "$rel" "$mode" ||
      { [[ "$need_it" == optional ]] && echo "SKIP: $FROM has no ~/$rel"; } ||
      echo "WARNING: could not copy ~/$rel from $FROM"
  done
  copy_ssh_config || echo "WARNING: could not copy ~/.ssh/config from $FROM"
fi
need "put the remaining keys in place" \
  "Copy them from $FROM or Bitwarden, never through chat, email or git:
  ~/.config/sops/age/keys.txt  (Bitwarden: \"SOPS AGE KEY\"), mode 600
  ~/.ssh/k3s_homelab_ed25519, mode 600
  ~/.ssh/config entries for the six nodes, k3s-dr and ubuntu-hp
  ~/.kube/config, mode 600" \
  all_keys_present
ok "age key, cluster SSH key, SSH hosts and kubeconfig are in place"

# --- 3. ------------------------------------------------------------------
step "GitHub access"
# GitHub ends every ssh -T with exit 1, so read what it says instead.
github_ssh_ok() {
  local out
  out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    git@github.com 2>&1 || true)"
  grep -q 'successfully authenticated' <<<"$out"
}
# A new laptop has no gh yet: the dotfiles that install it are private,
# behind this very step.
if ! github_ssh_ok && ! command -v gh >/dev/null 2>&1 && command -v pacman >/dev/null 2>&1; then
  if yes_no "The GitHub CLI (gh) is not installed. Install it with pacman now?"; then
    sudo pacman -S --needed github-cli || true
    hash -r
  fi
fi
if ! github_ssh_ok && command -v gh >/dev/null 2>&1; then
  if yes_no "This laptop cannot push to GitHub yet. Run 'gh auth login' now? It can create and upload an SSH key."; then
    gh auth login --git-protocol ssh --web || true
  fi
fi
need "give this laptop an SSH key on GitHub" \
  "Either run: gh auth login --git-protocol ssh   (it offers to create and upload a key)
or create one with ssh-keygen -t ed25519 and add the .pub file at
https://github.com/settings/keys. Check with: ssh -T git@github.com" \
  github_ssh_ok
ok "ssh -T git@github.com authenticates"

# --- 4. ------------------------------------------------------------------
step "Repositories"
mkdir -p "$WORK_DIR"
for repo in k3s-homelab-config k3s-homelab-private; do
  if [[ -d "$WORK_DIR/$repo/.git" ]]; then
    ok "$WORK_DIR/$repo already cloned"
  else
    git clone "git@github.com:$GITHUB_OWNER/$repo.git" "$WORK_DIR/$repo"
    ok "cloned $repo"
  fi
done
origin="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
if [[ "$origin" == https://github.com/* ]]; then
  git -C "$REPO_DIR" remote set-url origin "git@github.com:$GITHUB_OWNER/k3s-homelab.git"
  ok "k3s-homelab now pushes over SSH"
fi

# --- 5. ------------------------------------------------------------------
step "Cluster tools"
TOOLS=(kubectl helm argocd kubectx kubens velero trivy k9s kubeconform gh sops age direnv jq yq argon2 envsubst)
# Handy but not needed by any script: the cluster's own setup installs the
# Cilium CLI on the nodes. Packages name its command differently (cilium on
# most, cilium-cli on some), so either name counts.
OPTIONAL_TOOLS=("cilium|cilium-cli")
have_any() {
  local name names
  IFS='|' read -ra names <<<"$1"
  for name in "${names[@]}"; do
    command -v "$name" >/dev/null 2>&1 && return 0
  done
  return 1
}
missing_tools() {
  local t missing=()
  for t in "${TOOLS[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  (( ${#missing[@]} == 0 )) && return 0
  echo "Missing: ${missing[*]}"
  return 1
}
if ! missing_tools >/dev/null && [[ ! -e "$DOTFILES" ]]; then
  if yes_no "Some cluster tools are missing and $DOTFILES is not here. Clone the dotfiles now?"; then
    git clone "git@github.com:$GITHUB_OWNER/dotfiles.git" "$DOTFILES"
  fi
fi

# The dotfiles keep a machines/<hostname>/ folder per laptop. Its
# local-only.txt lists the files atmos rewrites with each laptop's own
# settings; without it, bootstrap.sh would link them into the shared repo and
# atmos would then edit every laptop's copy. It must exist before bootstrap.sh
# runs, so create it here, and publish it once bootstrap has linked the git
# config that a commit needs.
MACHINE_DIR="machines/$HOST"
NEW_MACHINE_DIR=false
if [[ -d "$DOTFILES/machines" && ! -e "$DOTFILES/$MACHINE_DIR/local-only.txt" ]]; then
  template="$DOTFILES/machines/dev/local-only.txt"
  [[ -f "$template" ]] || template="$(find "$DOTFILES/machines" -name local-only.txt -print -quit)"
  if [[ -f "$template" ]] &&
     yes_no "Your dotfiles have no $MACHINE_DIR/local-only.txt. Create it from ${template#"$DOTFILES/"}, so this laptop's own display and input settings stay out of the shared repo?"; then
    mkdir -p "$DOTFILES/$MACHINE_DIR"
    cp "$template" "$DOTFILES/$MACHINE_DIR/local-only.txt"
    NEW_MACHINE_DIR=true
    ok "created $MACHINE_DIR/local-only.txt in the dotfiles"
  else
    echo "WARNING: without $MACHINE_DIR/local-only.txt, bootstrap.sh links the per-laptop Hyprland and Omarchy files into the shared dotfiles"
  fi
elif [[ -e "$DOTFILES/$MACHINE_DIR/local-only.txt" ]]; then
  ok "the dotfiles already have $MACHINE_DIR/local-only.txt"
fi

if ! missing_tools >/dev/null && [[ -x "$DOTFILES/bootstrap.sh" ]]; then
  if yes_no "Some cluster tools are missing. Run $DOTFILES/bootstrap.sh --packages now?"; then
    "$DOTFILES/bootstrap.sh" --packages || true
    hash -r
  fi
fi

if [[ "$NEW_MACHINE_DIR" == true ]]; then
  if git -C "$DOTFILES" add "$MACHINE_DIR/local-only.txt" &&
     git -C "$DOTFILES" commit -q -m "$MACHINE_DIR: keep the per-laptop files local, like dev" &&
     git -C "$DOTFILES" push -q; then
    ok "published $MACHINE_DIR/local-only.txt to the dotfiles repository"
  else
    echo "WARNING: could not publish $MACHINE_DIR/local-only.txt; run: dotfiles-sync push $MACHINE_DIR/local-only.txt"
  fi
fi

# The laptops log in to each other with the public keys each one publishes in
# the dotfiles' $MACHINE_DIR/ssh/. laptop-ssh publishes this laptop's and lets
# the others' in; dotfiles-sync repeats it on every laptop every 15 minutes,
# so they let this one in once its keys are pushed.
LAPTOP_SSH="$DOTFILES/shell/.local/bin/laptop-ssh"
if [[ -x "$LAPTOP_SSH" ]]; then
  if ! systemctl is-enabled --quiet sshd 2>/dev/null &&
     yes_no "sshd is off, so the other laptops cannot log in to this one. Enable and start it now?"; then
    sudo systemctl enable --now sshd || echo "WARNING: could not start sshd"
  fi
  "$LAPTOP_SSH" || echo "WARNING: laptop-ssh failed; run it again: $LAPTOP_SSH"
  if [[ -n "$(git -C "$DOTFILES" status --porcelain -- "$MACHINE_DIR/ssh" 2>/dev/null)" ]]; then
    if git -C "$DOTFILES" add -- "$MACHINE_DIR/ssh" &&
       git -C "$DOTFILES" commit -q -m "$MACHINE_DIR: publish this laptop's SSH keys, so the other laptops let it in" &&
       git -C "$DOTFILES" push -q; then
      ok "published $MACHINE_DIR/ssh; the other laptops let this one in within 15 minutes"
    else
      echo "WARNING: could not publish $MACHINE_DIR/ssh; run: dotfiles-sync push"
    fi
  else
    ok "the dotfiles already have this laptop's SSH keys"
  fi
fi

# bootstrap.sh links the dotfiles-sync timer but leaves it off. It keeps the
# dotfiles pulled and runs laptop-ssh, which is what lets the other laptops
# log in here with their keys; without it they are asked for a password.
SYNC_TIMER="$HOME/.config/systemd/user/dotfiles-sync.timer"
if [[ -e "$SYNC_TIMER" ]]; then
  if systemctl --user is-enabled --quiet dotfiles-sync.timer 2>/dev/null; then
    ok "the dotfiles-sync timer is already on"
  elif systemctl --user daemon-reload &&
       systemctl --user enable --now dotfiles-sync.timer; then
    # One sync now, so the other laptops' SSH keys are trusted straight away.
    systemctl --user start dotfiles-sync.service || true
    ok "turned on the dotfiles-sync timer (pulls the dotfiles every 15 minutes)"
  else
    echo "WARNING: could not turn on the dotfiles-sync timer; run: systemctl --user enable --now dotfiles-sync.timer"
  fi
fi
need "install the cluster tools" \
  "The dotfiles install them:
  git clone git@github.com:$GITHUB_OWNER/dotfiles.git $DOTFILES
  cd $DOTFILES && ./bootstrap.sh --packages
Open a new shell afterwards if a tool still is not found." \
  missing_tools
ok "all cluster tools are installed"
for t in "${OPTIONAL_TOOLS[@]}"; do
  have_any "$t" ||
    echo "NOTE: no ${t//|/ or } command; it is only for looking at Cilium by hand (cilium status), so carrying on"
done

# --- 6. ------------------------------------------------------------------
step "Python environment and Ansible collections"
cd "$REPO_DIR"
if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv
  ok "created .venv"
fi
.venv/bin/python -m pip install -q -r requirements.txt
ok "requirements.txt installed in .venv"
./scripts/ensure-ansible-collections.sh
command -v direnv >/dev/null 2>&1 && direnv allow . && ok "direnv allowed for this repository"

# --- 7. ------------------------------------------------------------------
step "Private files"
K3S_SYNC="$WORK_DIR/k3s-homelab-private/k3s-sync"
private_files_present() {
  local f missing=()
  for f in .secrets.enc config/cluster.env; do
    [[ -s "$REPO_DIR/$f" ]] || missing+=("$f")
  done
  (( ${#missing[@]} == 0 )) && return 0
  echo "Missing: ${missing[*]}"
  return 1
}
if [[ -x "$K3S_SYNC" ]]; then
  command -v k3s-sync >/dev/null 2>&1 || "$K3S_SYNC" install
  "$K3S_SYNC" pull
fi
need "bring the private files over" \
  "Run: $K3S_SYNC install && $K3S_SYNC pull
It needs the age key and GitHub access from the steps above. See the
private repository's GUIDE.md if it reports a problem." \
  private_files_present
ok ".secrets.enc and config/cluster.env are here"

# Step 2 leaves an age key that was already here alone, so check it is the
# one .secrets.enc is encrypted for. Otherwise every script that reads a
# secret fails later (deploy preflight, maintenance, the DR power-on).
AGE_KEY="${SOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt}"
secrets_decrypt() { sops --decrypt "$REPO_DIR/.secrets.enc" >/dev/null 2>&1; }
key_mismatch_help() {
  local wanted have
  wanted="$(grep -oE 'age1[0-9a-z]{58}' "$REPO_DIR/.secrets.enc" "$REPO_DIR/.sops.yaml" 2>/dev/null |
    sed 's/.*://' | sort -u | tr '\n' ' ' || true)"
  have="$(age-keygen -y "$AGE_KEY" 2>/dev/null | tr '\n' ' ' || true)"
  echo "sops cannot decrypt .secrets.enc with $AGE_KEY."
  echo "  .secrets.enc is for: ${wanted:-unknown}"
  echo "  this laptop has:     ${have:-no key}"
}
decrypts_or_explains() { secrets_decrypt || { key_mismatch_help; return 1; }; }
source_connected() {
  ssh -o ControlPath="$SSH_CONTROL" -O check "$FROM" >/dev/null 2>&1 || connect_source
}
if ! secrets_decrypt; then
  key_mismatch_help
  if [[ "$COPY_KEYS" == true ]] &&
     yes_no "Replace $AGE_KEY with $FROM's age key? The current one is kept as $AGE_KEY.bak."; then
    if source_connected &&
       scp -q -o ControlPath="$SSH_CONTROL" "$FROM:.config/sops/age/keys.txt" "$TMP/age-key" 2>/dev/null; then
      mkdir -p "$(dirname "$AGE_KEY")"
      [[ -e "$AGE_KEY" ]] && cp -p "$AGE_KEY" "$AGE_KEY.bak"
      install -m 600 "$TMP/age-key" "$AGE_KEY"
      rm -f "$TMP/age-key"
      ok "replaced the age key with $FROM's (old one in $AGE_KEY.bak)"
    else
      echo "WARNING: could not copy the age key from $FROM"
    fi
  fi
fi
need "give this laptop the age key .secrets.enc is encrypted for" \
  "Copy it from $FROM or Bitwarden (\"SOPS AGE KEY\") to $AGE_KEY, mode 600,
keeping the old one if you need it. Check with: age-keygen -y $AGE_KEY
and: sops --decrypt $REPO_DIR/.secrets.enc >/dev/null" \
  decrypts_or_explains
ok "sops decrypts .secrets.enc with this laptop's age key"

# --- 8. ------------------------------------------------------------------
step "Inventory"
./scripts/prepare-env.sh
ok "inventory/k3s-ansible/hosts.ini written from config/cluster.env"

# --- 9. ------------------------------------------------------------------
step "Cluster access"
cluster_ok() { kubectl get nodes >/dev/null 2>&1; }
need "reach the cluster" \
  "kubectl get nodes fails. Check that this laptop is on the home network and
that ~/.kube/config points at the kube-vip address." \
  cluster_ok
kubectl get nodes
echo
echo "The DR timers run only on dev. If this laptop replaces dev, run"
echo "./install-dr-timers.sh once after this."

# --- 10. ----------------------------------------------------------------
step "Workstation readiness"
case "$READINESS" in
  yes) run_readiness=true ;;
  no) run_readiness=false ;;
  *) run_readiness=false
     yes_no "Run ./workstation-readiness.sh now? It takes 20-40 minutes and powers the DR server on if it is off." &&
       run_readiness=true ;;
esac
if [[ "$run_readiness" == true ]]; then
  ./workstation-readiness.sh
else
  echo "Skipped. Run ./workstation-readiness.sh before this laptop takes over from another."
fi

echo
echo "RESULT: LAPTOP SET UP"
