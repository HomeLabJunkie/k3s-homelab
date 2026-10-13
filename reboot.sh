#!/usr/bin/env bash
set -Eeuo pipefail

# Use the repository's pinned Ansible (.venv) ahead of the laptop's own.
# USE_PROJECT_VENV=false leaves PATH alone; the tests set it to use mocks.
if [[ "${USE_PROJECT_VENV:-true}" == true && -d "$(dirname "${BASH_SOURCE[0]}")/.venv/bin" ]]; then
  PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.venv/bin:$PATH"
fi

ansible-playbook reboot.yml
