# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_REPO_ROOT comes from the harness
# What a user follows names the commands by their names: `txn` and `generate`. The old names
# `update` and `sync` stay through 1.x with a warning and stop working in 2.0.0, so a skill,
# a document, the template or a message that sends a user to them sends the user to a
# warning now and to an error later. The old names themselves, their test and the generated
# command reference are what remains.
cd "$DS_REPO_ROOT" || ds_fail "no repository"
mapfile -t found < <(
  grep -rnE '(dotsteward|cli\.sh) (update|sync)\b|`(update (prepare|publish|status)|sync)\b' \
    README.md skills docs template cli nix modules 2>/dev/null |
    grep -vE '^(docs/cli\.md|cli/commands/(update|sync)\.sh):|the old name of' || true
)
((${#found[@]} == 0)) || ds_fail "old command names: $(printf '%s\n' "${found[@]}" | cut -c1-120)"
