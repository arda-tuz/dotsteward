#!/usr/bin/env bash
# summary: Fake generate of the apply tests: a mirror that is a function of the tree
#
# Writes .dotsteward/stage0.linux.env, INTENT_SHA256 over workstation.toml and the pages of docs/,
# as the real generate writes the mirrors from the evaluation of the tree: the same tree always
# gives the same bytes, and two changes made apart give a value neither side had. The manifest
# mirrors of the tests stay as the tests write them. $UP_CONTROL/generate-red: exit 1.
set -euo pipefail
root=$DOTSTEWARD_INSTANCE
printf 'generate %s root=%s\n' "$*" "$root" >>"$UP_LOG"
[[ ! -e $UP_CONTROL/generate-red ]] || {
  printf '[dotsteward] ERROR: cannot evaluate the mirrors of the instance\n' >&2
  exit 1
}
digest=$(cd "$root" && find workstation.toml docs -type f -print0 | LC_ALL=C sort -z | xargs -0 cat | sha256sum)
mkdir -p "$root/.dotsteward"
printf 'INTENT_SHA256=%s\n' "${digest%% *}" >"$root/.dotsteward/stage0.linux.env.new"
mv -- "$root/.dotsteward/stage0.linux.env.new" "$root/.dotsteward/stage0.linux.env"
