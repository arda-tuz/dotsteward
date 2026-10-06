#!/usr/bin/env bash
# Instance static check (gate static step, checks.instance-static): runs from
# the instance root.
set -Eeuo pipefail
[[ -f workstation.toml ]] || {
  echo "workstation.toml is missing" >&2
  exit 1
}
[[ $DOTSTEWARD_INSTANCE == "$PWD" ]] || {
  echo "DOTSTEWARD_INSTANCE is not the instance root" >&2
  exit 1
}
echo "example static ok"
