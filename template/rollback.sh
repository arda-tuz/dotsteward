#!/usr/bin/env bash
# Undoes the Home Manager setup of this instance on this machine (login
# shell, managed links, force-linked files): `dotsteward rollback`.
#
# Usage: ./rollback.sh [--latest] (--dry-run [--json] | --apply)
#
# Every argument goes to `dotsteward rollback` unchanged.
set -Eeuo pipefail

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

exec "$root/.dotsteward/cli.sh" rollback "$@"
