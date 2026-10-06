#!/usr/bin/env bash
# Builds the Home Manager generation of this instance for this machine and,
# with --switch, activates it: `dotsteward rebuild`.
#
# Usage: ./rebuild.sh --profile PROFILE (--switch | --build-only)
#                     [--framework-override REF]
#
# Every argument goes to `dotsteward rebuild` unchanged.
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

exec "$root/.dotsteward/cli.sh" rebuild "$@"
