#!/usr/bin/env bash
# summary: Create a new instance from the framework template (--dir, --remote, --components)
#
# Usage: dotsteward init --dir DIR --remote URL [--username U] [--home H]
#          [--name N] [--checkout PATH] [--components LIST]
#          [--method COMPONENT=METHOD]...
#          [--method-platform COMPONENT=linux:METHOD,darwin:METHOD]...
#          [--systems x86_64-linux[,aarch64-darwin]] [--profiles ADOPT,FRESH]
#          [--allow-unfree] [--contribute fork|owner]
#          [--framework-ref vX.Y.Z | --framework-url URL] [--no-git]
#          [--non-interactive] [--json]
#
# Copies the framework template into DIR (missing, empty, or filled by
# `nix flake init -t`), writes workstation.toml, merges the chosen catalog
# components' seeds into the locks and their flake inputs into flake.nix,
# then runs `nix flake lock`, `dotsteward sync --nix` and `dotsteward pins
# check --nix` in a temporary directory, moves the instance into DIR and
# commits it there with the user's git identity. All or
# nothing: DIR changes only when every step passed, and a failed commit puts
# it back as it was. init never prompts. The engine is
# cli/python/dotsteward_cli/init.py, run with the python3 first on PATH (the
# package puts its own python, with tomlkit, there). Exit 0, 1 for a refusal
# or a failed step, 2 for a usage error.
set -Eeuo pipefail

root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

if ! command -v python3 >/dev/null 2>&1; then
  printf '[dotsteward] ERROR: init needs python3 on PATH\n' >&2
  exit 1
fi

PYTHONPATH=$root/cli/python PYTHONDONTWRITEBYTECODE=1 \
  exec python3 -s -P -m dotsteward_cli.init "$@"
