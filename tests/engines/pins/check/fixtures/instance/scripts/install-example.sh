#!/usr/bin/env bash
# Reads the download pin from the lock; no literal URL or digest here.
set -Eeuo pipefail
url=$(lock_value '.agent_tools."example-release".url')
sha256=$(lock_value '.agent_tools."example-release".sha256')
printf '%s %s\n' "$url" "$sha256"
