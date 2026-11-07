#!/usr/bin/env bash
# summary: Check, sync, research and move the pinned versions of the instance's lock files
#
# Usage: dotsteward pins [--instance DIR] check [--nix]
#        dotsteward pins [--instance DIR] sync [--nix] [--skill NAME]...
#        dotsteward pins [--instance DIR] latest [--out FILE] [--all] [--jobs N]
#        dotsteward pins [--instance DIR] apply [--latest FILE] [--plan] [--skip ID]... [--json] [--jobs N]
#
# check cross-checks versions.lock.json, the skills lock and the files they
# pin with the core rules and the rules the enabled components declare (read
# from the committed .dotsteward/manifest.<system>.json mirrors); it is
# offline and writes nothing. sync rewrites the derived values. --nix
# compares (check) or writes (sync) the resolved versions with
# `nix eval <instance>#lib.pinnedVersions`, after refusing untracked files.
# latest reports the newest stable upstream versions and writes nothing but
# --out. apply moves the pins to the rows of latest (or of --latest FILE), with
# review items for what a person decides, and commits nothing. Exit codes: 0 ok,
# 1 inconsistencies or a refusal, 2 usage errors and broken inputs; apply also
# 3 review items wait and 6 an upstream could not be read.
#
# The engine is engines/pins/dotsteward_pins (Python standard library only),
# run with the python3 first on PATH.
set -Eeuo pipefail

root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

if ! command -v python3 >/dev/null 2>&1; then
  printf '[pins] ERROR: python3 is required on PATH\n' >&2
  exit 2
fi

# --nix needs nix; a daemon installation may not be on PATH yet.
for argument in "$@"; do
  if [[ $argument == --nix || $argument == apply ]]; then
    # shellcheck source=cli/lib/lib.sh
    source "$root/cli/lib/lib.sh"
    source_nix_daemon
    break
  fi
done

PYTHONPATH=$root/engines/pins:$root/cli/python PYTHONDONTWRITEBYTECODE=1 \
  exec python3 -s -P -m dotsteward_pins "$@"
