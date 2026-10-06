#!/usr/bin/env bash
# Instance static check ([gate] static): runs from the instance root.
set -Eeuo pipefail
for file in workstation.toml versions.lock.json agent/skills.lock.json home/AGENTS.md; do
  [[ -f $file ]] || {
    echo "$file is missing" >&2
    exit 1
  }
done
echo "full instance static ok"
