#!/usr/bin/env bash
# Runs one step of a maintenance transaction of this instance through
# dotsteward. `./update.sh -h` prints the subcommands.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./update.sh prepare|validate|publish|status [ARG...]

One step of a maintenance transaction; the remaining arguments go to the
dotsteward command unchanged:
  prepare   dotsteward update prepare: record the base of the transaction
            (--official-sources-only [--scope update|maintain])
  validate  dotsteward gate: prove the candidate tree without committing
            ([--scope update|maintain] [--force] [--expected-base OID])
  publish   dotsteward update publish: push the proven tree
            ([--scope update|maintain] [--expected-base OID])
  status    dotsteward update status: show the transaction records ([--json])
EOF
}

error() {
  printf '[dotsteward] ERROR: %s\n' "$*" >&2
}

if (($# == 0)); then
  error "update.sh needs a subcommand"
  usage >&2
  exit 1
fi

case $1 in
  prepare) command=(update prepare) ;;
  validate) command=(gate) ;;
  publish) command=(update publish) ;;
  status) command=(update status) ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  *)
    error "update.sh: unknown subcommand $1 (expected prepare, validate, publish or status)"
    usage >&2
    exit 1
    ;;
esac
shift

# The instance root: the directory of this file, symbolic links resolved.
source_path=${BASH_SOURCE[0]}
while [ -L "$source_path" ]; do
  link_dir=$(cd -P -- "$(dirname -- "$source_path")" && pwd)
  source_path=$(readlink -- "$source_path")
  case $source_path in
    /*) ;;
    *) source_path=$link_dir/$source_path ;;
  esac
done
root=$(cd -P -- "$(dirname -- "$source_path")" && pwd)

exec "$root/.dotsteward/cli.sh" "${command[@]}" "$@"
