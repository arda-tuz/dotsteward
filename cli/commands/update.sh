#!/usr/bin/env bash
# summary: Old name of txn: a warning, then txn with the same arguments (until 2.0.0)
set -Eeuo pipefail

printf "[dotsteward] WARNING: 'dotsteward update' is the old name of 'dotsteward txn'; the old name stops working in 2.0.0\n" >&2
exec "$BASH" -- "$(dirname -- "${BASH_SOURCE[0]}")/txn.sh" "$@"
