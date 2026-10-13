#!/usr/bin/env bash
# Rotates a throwaway laptop key through scripts/rotate-sops-age-key.sh, with
# a throwaway configuration repository, and checks both were re-encrypted.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for command in sops age-keygen git jq; do
  command -v "$command" >/dev/null 2>&1 && continue
  # A missing tool skips the test on a laptop, but not in CI, where a skip
  # would go unnoticed.
  if [[ -n "${CI:-}" ]]; then echo "FAIL: $command is not installed" >&2; exit 1; fi
  echo "SKIP: $command is not installed"; exit 0
done

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset SOPS_AGE_KEY

for name in old new argocd; do
  age-keygen -o "$TEST_ROOT/$name.key" 2>/dev/null
done
old_pub="$(age-keygen -y "$TEST_ROOT/old.key")"
new_pub="$(age-keygen -y "$TEST_ROOT/new.key")"
argocd_pub="$(age-keygen -y "$TEST_ROOT/argocd.key")"
cat "$TEST_ROOT/old.key" "$TEST_ROOT/new.key" >"$TEST_ROOT/keys.txt"
export SOPS_AGE_KEY_FILE="$TEST_ROOT/keys.txt"

# A stand-in for this repository: the script, a secrets file, and stubs for
# what the script calls afterwards.
repo="$TEST_ROOT/repo"
mkdir -p "$repo/scripts" "$repo/backup" "$repo/monitoring"
cp "$ROOT_DIR/scripts/rotate-sops-age-key.sh" "$repo/scripts/"
for stub in backup/backup.sh scripts/test-secrets-recovery.sh monitoring/dr-notify.sh; do
  printf '#!/usr/bin/env bash\ntouch "%s/ran-%s"\n' "$TEST_ROOT" "$(basename "$stub")" >"$repo/$stub"
  chmod +x "$repo/$stub"
done
printf 'creation_rules:\n  - path_regex: \\.secrets.*\n    age: %s\n' "$old_pub" >"$repo/.sops.yaml"
printf 'EXAMPLE=value\n' >"$TEST_ROOT/plain"
# shellcheck disable=SC2094 # the override is a name; nothing is read from it
sops --config "$repo/.sops.yaml" --encrypt --input-type binary --output-type binary \
  --filename-override "$repo/.secrets.enc" "$TEST_ROOT/plain" >"$repo/.secrets.enc"
# The test cluster's secrets file sits beside it, encrypted to the same key.
# shellcheck disable=SC2094 # the override is a name; nothing is read from it
sops --config "$repo/.sops.yaml" --encrypt --input-type binary --output-type binary \
  --filename-override "$repo/.secrets.test.enc" "$TEST_ROOT/plain" >"$repo/.secrets.test.enc"
test_recipients() { jq -r '.sops.age[].recipient' "$repo/.secrets.test.enc"; }

# A stand-in for the configuration repository, with somewhere to push to.
git init --quiet --bare "$TEST_ROOT/config.git"
config="$TEST_ROOT/config"
git clone --quiet "$TEST_ROOT/config.git" "$config" 2>/dev/null
mkdir "$config/app"
cat >"$config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: \.enc\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      $old_pub,
      $argocd_pub
EOF
cat >"$TEST_ROOT/example.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: example
stringData:
  password: not-a-real-password
EOF
# shellcheck disable=SC2094 # the override is a name; nothing is read from it
(cd "$config" && sops --encrypt --filename-override app/example.enc.yaml \
  "$TEST_ROOT/example.yaml" >app/example.enc.yaml)
git -C "$config" add .
git -C "$config" commit --quiet --message "Start"
git -C "$config" push --quiet origin HEAD

rotate() { CONFIG_REPO="$config" "$repo/scripts/rotate-sops-age-key.sh" >"$TEST_ROOT/output" 2>&1; }
recipients() { jq -r '.sops.age[].recipient' "$repo/.secrets.enc"; }

# The new key named here but not in the configuration repository: refused,
# with nothing changed.
sed -i "s/$old_pub/$new_pub/" "$repo/.sops.yaml"
if rotate; then fail "rotation ran with the old key still in the configuration repository"; fi
grep -q "still names the key being retired" "$TEST_ROOT/output" || fail "no explanation for the refusal"
[[ "$(recipients)" == "$old_pub" ]] || fail ".secrets.enc changed on a refused run"
[[ "$(test_recipients)" == "$old_pub" ]] || fail ".secrets.test.enc changed on a refused run"
[[ -z "$(git -C "$config" status --porcelain)" ]] || fail "configuration repository changed on a refused run"

# Named in both: everything is re-encrypted and pushed.
sed -i "s/$old_pub/$new_pub/" "$config/.sops.yaml"
rotate || { cat "$TEST_ROOT/output" >&2; fail "rotation failed"; }
[[ "$(recipients)" == "$new_pub" ]] || fail ".secrets.enc is not encrypted to the new key"
pushed="$(git -C "$TEST_ROOT/config.git" show HEAD:app/example.enc.yaml)"
grep -qF "$new_pub" <<<"$pushed" || fail "the pushed Secret does not name the new key"
grep -qF "$old_pub" <<<"$pushed" && fail "the pushed Secret still names the old key"
grep -qF "$new_pub" <(git -C "$TEST_ROOT/config.git" show HEAD:.sops.yaml) || fail ".sops.yaml was not pushed"
for name in new argocd; do
  (cd "$config" && SOPS_AGE_KEY_FILE="$TEST_ROOT/$name.key" sops --decrypt app/example.enc.yaml |
    grep -q "not-a-real-password") || fail "the Secret does not decrypt with the $name key alone"
done
if (cd "$config" && SOPS_AGE_KEY_FILE="$TEST_ROOT/old.key" sops --decrypt app/example.enc.yaml >/dev/null 2>&1); then
  fail "the Secret still decrypts with the old key"
fi
SOPS_AGE_KEY_FILE="$TEST_ROOT/new.key" sops --decrypt "$repo/.secrets.enc" | grep -q "EXAMPLE=value" ||
  fail ".secrets.enc does not decrypt with the new key alone"
[[ "$(test_recipients)" == "$new_pub" ]] || fail ".secrets.test.enc is not encrypted to the new key"
SOPS_AGE_KEY_FILE="$TEST_ROOT/new.key" sops --decrypt "$repo/.secrets.test.enc" | grep -q "EXAMPLE=value" ||
  fail ".secrets.test.enc does not decrypt with the new key alone"
for stub in backup.sh test-secrets-recovery.sh dr-notify.sh; do
  [[ -e "$TEST_ROOT/ran-$stub" ]] || fail "$stub was not run"
done

echo "PASS: rotate-sops-age-key laptop key"
