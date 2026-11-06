#!/usr/bin/env bash
# summary: Old name of generate: a warning, then generate with the same arguments (until 2.0.0)
set -Eeuo pipefail

printf "[dotsteward] WARNING: 'dotsteward sync' is the old name of 'dotsteward generate'; the old name stops working in 2.0.0\n" >&2
exec "$BASH" -- "$(dirname -- "${BASH_SOURCE[0]}")/generate.sh" "$@"
