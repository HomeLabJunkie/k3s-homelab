#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ENV_FILE="${ENV_FILE:-$ROOT/config/cluster.env}"

"$ROOT/scripts/prepare-env.sh"

exec "$ROOT/deploy.sh" "$@"
