#!/usr/bin/env bash
# Replace an age key that sops encrypts with, and re-encrypt everything that
# was encrypted to the old one.
#
# Two keys are in use. The laptop key protects .secrets.enc here and every
# *.enc.yaml file in the private configuration repository. Argo CD's key is
# the second recipient of those *.enc.yaml files; it is held in the cluster
# (the sops-age Secret) and in .secrets.enc as ARGOCD_SOPS_AGE_KEY.
#
# Usage:
#   scripts/rotate-sops-age-key.sh
#       The laptop key. First add the new private key to the sops key file,
#       beside the old one, and put its public key in .sops.yaml here and in
#       the configuration repository in place of the old one.
#   scripts/rotate-sops-age-key.sh --argocd
#       Argo CD's key. It generates the new key itself. kubectl must point at
#       the cluster whose key is in .secrets.enc.
#
# Both commit and push the configuration repository. No private key is
# printed or left on disk outside .secrets.enc.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/cluster.env}"
SECRETS_FILE="${SECRETS_FILE:-$ROOT_DIR/.secrets.enc}"
CONFIG_REPO="${CONFIG_REPO:-$ROOT_DIR/../k3s-homelab-config}"
NOTIFY="${NOTIFY:-$ROOT_DIR/monitoring/dr-notify.sh}"

MODE=laptop
case "${1:-}" in
  "") ;;
  --argocd) MODE=argocd ;;
  *) echo "Usage: $0 [--argocd]" >&2; exit 2 ;;
esac

fail() { echo "ERROR: $*" >&2; exit 1; }

for command in sops jq git; do
  command -v "$command" >/dev/null 2>&1 || fail "$command command is required"
done
[[ -f "$SECRETS_FILE" && -f "$ROOT_DIR/.sops.yaml" ]] || fail "SOPS files are missing"
[[ -f "$CONFIG_REPO/.sops.yaml" ]] ||
  fail "configuration repository not found at $CONFIG_REPO (set CONFIG_REPO)"

config_git() { git -C "$CONFIG_REPO" "$@"; }

# The age public keys named in a file, one per line.
public_keys_in() { grep -oE 'age1[a-z0-9]{58}' "$1" | sort -u; }

# Re-encrypts every Secret in the configuration repository to the keys its
# .sops.yaml names now, and checks each one still decrypts. A file that
# already matches is left alone, so running this twice is safe.
rekey_config_repo() {
  local file
  while IFS= read -r file; do
    (cd "$CONFIG_REPO" && sops updatekeys --yes "$file" >/dev/null 2>&1) ||
      fail "sops could not re-encrypt $file in the configuration repository"
    (cd "$CONFIG_REPO" && sops --decrypt "$file" >/dev/null) ||
      fail "$file in the configuration repository no longer decrypts"
  done < <(config_git ls-files '*.enc.yaml')
}

# Commits whatever rekey_config_repo changed, and pushes. $1 is the message.
publish_config_repo() {
  if [[ -z "$(config_git status --porcelain)" ]]; then
    echo "==> The configuration repository already matches; nothing to push."
    return
  fi
  config_git add --update
  config_git commit --quiet --message "$1"
  config_git push --quiet
  echo "==> Pushed the configuration repository."
}

rotate_laptop_key() {
  local before after detail key
  local -a wanted=()
  before="$(mktemp)"; after="$(mktemp)"; detail="$(mktemp)"
  # shellcheck disable=SC2064 # expand the names now
  trap "rm -f -- '$before' '$after' '$detail'" EXIT

  sops --decrypt "$SECRETS_FILE" >/dev/null
  jq -r '.sops.age[]?.recipient' "$SECRETS_FILE" | sort >"$before"
  mapfile -t wanted < <(public_keys_in "$ROOT_DIR/.sops.yaml")

  # The configuration repository's .sops.yaml has to make the same change:
  # a key retired here must be gone from it, a key added here must be in it.
  while IFS= read -r key; do
    if ! printf '%s\n' "${wanted[@]}" | grep -qxF "$key" &&
        grep -qF "$key" "$CONFIG_REPO/.sops.yaml"; then
      fail "$CONFIG_REPO/.sops.yaml still names the key being retired ($key); replace it there too"
    fi
  done <"$before"
  for key in "${wanted[@]}"; do
    if ! grep -qxF "$key" "$before" && ! grep -qF "$key" "$CONFIG_REPO/.sops.yaml"; then
      fail "$CONFIG_REPO/.sops.yaml does not name the new key ($key); put it there too"
    fi
  done

  # The configuration repository goes first: if it fails, .secrets.enc is
  # untouched and the script can simply be run again.
  echo "==> Re-encrypting the configuration repository's Secrets..."
  rekey_config_repo
  publish_config_repo "Re-encrypt for the new laptop age key"

  # sops looks for .sops.yaml from the working directory, not beside the file.
  (cd "$ROOT_DIR" && sops updatekeys --yes "$SECRETS_FILE")
  jq -r '.sops.age[]?.recipient' "$SECRETS_FILE" | sort >"$after"
  if cmp -s "$before" "$after"; then
    fail "SOPS recipient set did not change; no reminder sent"
  fi
  # Existing recovery bundles still hold the old ciphertext; publish one for the
  # new recipients before the recovery test checks the latest bundle.
  echo "==> Publishing a recovery bundle encrypted to the new recipients..."
  "$ROOT_DIR/backup/backup.sh" || {
    echo "ERROR: .secrets.enc was re-keyed, but the recovery backup failed." >&2
    echo "ERROR: existing DR bundles are still encrypted to the previous recipients; keep the old key," >&2
    echo "ERROR: rerun backup/backup.sh, then scripts/test-secrets-recovery.sh. No reminder was sent." >&2
    exit 1
  }
  "$ROOT_DIR/scripts/test-secrets-recovery.sh"
  {
    echo "SOPS age-recipient rotation completed."
    echo
    echo "Update the Bitwarden SOPS AGE KEY record with the new private key now."
    echo "The encrypted secrets recovery test passed against a fresh recovery bundle."
    echo "The Secrets in the configuration repository were re-encrypted and pushed."
    echo
    echo "Keep the previous private key escrowed: older recovery bundles are still"
    echo "encrypted to it until they age out (retention keeps ${BACKUP_KEEP_COUNT:-14} nightly bundles)."
    echo
    echo "Recipients before: $(paste -sd, "$before")"
    echo "Recipients after:  $(paste -sd, "$after")"
  } >"$detail"
  "$NOTIFY" "[ACTION REQUIRED] Update Bitwarden SOPS AGE KEY" "$detail"
  echo "RESULT: SOPS AGE-KEY ROTATION VERIFIED; BITWARDEN REMINDER SENT"
}

# --- Argo CD's key -------------------------------------------------------------

# Names of the Argo CD applications that are not settled: still refreshing,
# not Synced and Healthy, or reporting an error. With $1 set to a commit of
# the configuration repository, also those reading that repository that have
# not rendered that commit yet.
unsettled_apps() {
  kubectl -n argocd get applications.argoproj.io -o json | jq -r --arg commit "${1:-}" '
    .items[] | select(
      .metadata.annotations["argocd.argoproj.io/refresh"] != null
      or .status.sync.status != "Synced"
      or .status.health.status != "Healthy"
      or ([.status.conditions[]? | select(.type | test("Error"))] | length > 0)
      or ($commit != ""
          and ([.spec.sources[]? | select(.repoURL | test("k3s-homelab-config"))] | length > 0)
          and ((.status.sync.revisions // []) | index($commit) | not))
    ) | .metadata.name' | paste -sd' '
}

# Gives Argo CD the keys in the named files and restarts the part of it that
# decrypts, so the change takes effect now.
set_cluster_keys() {
  kubectl create secret generic sops-age --namespace argocd \
    --from-file=keys.txt=<(cat "$@") --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null
  kubectl -n argocd rollout restart deployment/argocd-repo-server >/dev/null
  kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s >/dev/null
}

# swap_key <in> <out>: copies a decrypted file with the old private key
# replaced by the new one. Fails unless it was there exactly once.
swap_key() {
  python3 - "$1" "$2" "$WORK/old.key" "$WORK/new.key" <<'PY'
import sys

source, target, old_file, new_file = sys.argv[1:5]


def private_key(path):
    return next(line.strip() for line in open(path) if line.startswith("AGE-SECRET-KEY-"))


old, new = private_key(old_file), private_key(new_file)
text = open(source).read()
if text.count(old) != 1:
    sys.exit(1)
open(target, "w").write(text.replace(old, new))
PY
}

rotate_argocd_key() {
  local command old_key old_pub new_pub commit file count=0 pending deadline
  local config_path key_copy
  for command in age-keygen kubectl python3; do
    command -v "$command" >/dev/null 2>&1 || fail "$command command is required"
  done
  [[ -r "$ENV_FILE" ]] || fail "cluster environment file is missing: $ENV_FILE"
  # Directory inside the configuration repository this cluster reads; empty
  # for production. A test cluster keeps a copy of its key there.
  # shellcheck disable=SC1090
  config_path="$(set -a; source "$ENV_FILE"; printf '%s' "${ARGOCD_APPS_CONFIG_PATH:-}")"
  key_copy="${config_path}argocd-sops-age-key.enc.yaml"

  # Plaintext only ever exists in memory-backed, owner-only files.
  umask 077
  WORK="$(mktemp -d /dev/shm/rotate-age.XXXXXX)"
  DONE=false
  PUSHED=false
  CLUSTER_CHANGED=false
  START_HEAD=""
  trap 'undo_argocd_rotation' EXIT

  # shellcheck disable=SC1090
  old_key="$(source <(sops --decrypt "$SECRETS_FILE"); printf '%s' "${ARGOCD_SOPS_AGE_KEY:-}")"
  [[ "$old_key" == AGE-SECRET-KEY-* ]] || fail "ARGOCD_SOPS_AGE_KEY is not set in $SECRETS_FILE"
  printf '%s\n' "$old_key" >"$WORK/old.key"
  unset old_key
  old_pub="$(age-keygen -y "$WORK/old.key")"

  grep -qF "$old_pub" "$CONFIG_REPO/.sops.yaml" ||
    fail "$CONFIG_REPO/.sops.yaml does not name the current key ($old_pub)"
  [[ -z "$(config_git status --porcelain)" ]] ||
    fail "the configuration repository has uncommitted changes"
  config_git pull --quiet --ff-only
  kubectl -n argocd get secret sops-age -o jsonpath='{.data.keys\.txt}' | base64 -d |
    grep -qxFf "$WORK/old.key" ||
    fail "the cluster's sops-age Secret does not hold the key in $SECRETS_FILE; is kubectl pointed at the right cluster?"
  pending="$(unsettled_apps)"
  [[ -z "$pending" ]] ||
    fail "these applications are not Synced and Healthy, so the result could not be checked: $pending"
  START_HEAD="$(config_git rev-parse HEAD)"

  age-keygen -o "$WORK/new.key" 2>/dev/null
  new_pub="$(age-keygen -y "$WORK/new.key")"
  echo "==> Replacing Argo CD's key $old_pub"
  echo "    with $new_pub"

  # Argo CD holds both keys while the files change, so it can decrypt them
  # whichever commit it is looking at.
  echo "==> Giving Argo CD the new key beside the old one..."
  CLUSTER_CHANGED=true
  set_cluster_keys "$WORK/old.key" "$WORK/new.key"

  # .secrets.enc with the new key, written beside the real file and moved
  # into place only after the configuration repository is pushed.
  sops --decrypt "$SECRETS_FILE" >"$WORK/plain"
  swap_key "$WORK/plain" "$WORK/plain.new" ||
    fail "could not find the key exactly once in $SECRETS_FILE"
  sops --config "$ROOT_DIR/.sops.yaml" --encrypt --input-type binary --output-type binary \
    --filename-override "$SECRETS_FILE" "$WORK/plain.new" >"$SECRETS_FILE.new"
  sops --decrypt "$SECRETS_FILE.new" | cmp -s - "$WORK/plain.new" ||
    fail "the new $SECRETS_FILE did not decrypt to what was written"
  chmod --reference="$SECRETS_FILE" "$SECRETS_FILE.new"

  echo "==> Re-encrypting the configuration repository's Secrets..."
  sed -i "s/$old_pub/$new_pub/g" "$CONFIG_REPO/.sops.yaml"
  if config_git ls-files --error-unmatch "$key_copy" >/dev/null 2>&1; then
    (
      cd "$CONFIG_REPO" &&
        sops --decrypt "$key_copy" >"$WORK/copy.yaml" &&
        swap_key "$WORK/copy.yaml" "$WORK/copy.new.yaml" &&
        sops --encrypt --filename-override "$key_copy" "$WORK/copy.new.yaml" >"$WORK/copy.enc.yaml" &&
        cp "$WORK/copy.enc.yaml" "$key_copy"
    ) || fail "could not update the copy of the key in $key_copy"
  fi
  rekey_config_repo
  # Every file that names the new key must open with the new key alone.
  while IFS= read -r file; do
    grep -qF "$old_pub" "$CONFIG_REPO/$file" && fail "$file still names the old key"
    grep -qF "$new_pub" "$CONFIG_REPO/$file" || continue
    (cd "$CONFIG_REPO" && env -u SOPS_AGE_KEY SOPS_AGE_KEY_FILE="$WORK/new.key" \
      sops --decrypt "$file" >/dev/null 2>&1) || fail "$file does not decrypt with the new key"
    count=$((count + 1))
  done < <(config_git ls-files '*.enc.yaml')
  (( count > 0 )) || fail "no file in the configuration repository was encrypted to the old key"
  echo "==> $count files decrypt with the new key alone."

  publish_config_repo "Re-encrypt for Argo CD's new age key"
  PUSHED=true
  mv "$SECRETS_FILE.new" "$SECRETS_FILE"
  commit="$(config_git rev-parse HEAD)"

  echo "==> Taking the old key away from Argo CD and rendering every application again..."
  set_cluster_keys "$WORK/new.key"
  kubectl -n argocd annotate applications.argoproj.io --all \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  deadline=$((SECONDS + 900))
  until pending="$(unsettled_apps "$commit")" && [[ -z "$pending" ]]; do
    (( SECONDS < deadline )) ||
      fail "Argo CD holds only the new key, and these applications did not settle: $pending"
    sleep 10
  done
  echo "==> Every application is Synced and Healthy, rendered with the new key."

  if [[ "${SKIP_RECOVERY_BACKUP:-false}" == true ]]; then
    echo "==> Skipping the recovery bundle (SKIP_RECOVERY_BACKUP=true)."
  else
    # A bundle made before now restores the old key, which opens nothing in
    # the configuration repository any more.
    echo "==> Publishing a recovery bundle that holds the new key..."
    "$ROOT_DIR/backup/backup.sh" ||
      fail "the key was replaced, but the recovery backup failed; rerun backup/backup.sh"
  fi
  DONE=true
  echo "RESULT: ARGO CD AGE-KEY ROTATION VERIFIED"
  echo "Copy .secrets.enc to the other laptop (k3s-sync push) and pull the configuration repository there."
}

# On a failure before the configuration repository is pushed, puts everything
# back as it was. After the push nothing is undone: the new key is in use.
undo_argocd_rotation() {
  local status=$?
  trap - EXIT
  if [[ "$DONE" != true && "$PUSHED" != true ]]; then
    rm -f -- "$SECRETS_FILE.new"
    if [[ -n "$START_HEAD" ]]; then
      config_git reset --quiet --hard "$START_HEAD" || true
    fi
    if [[ "$CLUSTER_CHANGED" == true ]]; then
      set_cluster_keys "$WORK/old.key" || echo "WARNING: could not put Argo CD's old key back alone; it still holds both keys." >&2
    fi
    echo "Nothing was changed: .secrets.enc, the configuration repository and Argo CD's key are as they were." >&2
  elif [[ "$DONE" != true ]]; then
    echo "The new key is in .secrets.enc and the configuration repository. Fix the problem above; do not run this again." >&2
  fi
  find "$WORK" -type f -exec shred -u {} + 2>/dev/null
  rm -rf -- "$WORK"
  exit "$status"
}

if [[ "$MODE" == argocd ]]; then
  rotate_argocd_key
else
  rotate_laptop_key
fi
