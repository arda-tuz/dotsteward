#!/usr/bin/env bash
# summary: Fake rebuild of the upgrade tests: the record of rebuild --switch
set -euo pipefail
printf 'rebuild %s root=%s\n' "$*" "$DOTSTEWARD_INSTANCE" >>"$UP_LOG"
[[ ! -e $UP_CONTROL/rebuild-fails ]] || exit 1
if [[ -e $UP_CONTROL/rebuild-fails-in-work && $DOTSTEWARD_INSTANCE == */upgrade/work ]]; then
  exit 1
fi
if [[ -e $UP_CONTROL/rebuild-status-hook ]]; then
  bash "$UP_CONTROL/rebuild-status-hook"
fi
if [[ -e $UP_CONTROL/rebuild-status ]]; then
  exit "$(<"$UP_CONTROL/rebuild-status")"
fi
root=$DOTSTEWARD_INSTANCE
tree=$(git -C "$root" rev-parse 'HEAD^{tree}')
mkdir -p "$DOTSTEWARD_STATE_ROOT/current"
jq -n --arg generation "/nix/store/generation-$tree" --arg revision "$(git -C "$root" rev-parse HEAD)" \
  --arg tree "$tree" --arg root "$root" --arg profile "$2" '{
  generation: $generation, profile: $profile, revision: $revision, tree_oid: $tree, root: $root,
  framework_override: null, activated_at: "2026-01-01T00:00:00Z"}' >"$DOTSTEWARD_STATE_ROOT/current/activation.json"
printf '%s\n' "$2" >"$DOTSTEWARD_STATE_ROOT/current/profile"
