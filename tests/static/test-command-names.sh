# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_REPO_ROOT comes from the harness
# shellcheck disable=SC2016 # the patterns name backticks, nothing here is to expand
# What a user follows names the commands by their names: `txn` and `generate`. The old names
# `update` and `sync` stay through 1.x with a warning and stop working in 2.0.0, so a skill,
# a document, the template or a message that sends a user to them sends the user to a
# warning now and to an error later. The old names themselves, their test and the generated
# command reference are what remains, and template/bootstrap.sh with the parts it is made of
# (cli/lib/stage0.sh, the stage-0 message of cli/commands/preflight.sh): every instance holds a copy
# of it that its static checks compare byte for byte, so it changes only with the release that
# refreshes it (2.0.0 drops the old names).
cd "$DS_REPO_ROOT" || ds_fail "no repository"
mapfile -t found < <(
  grep -rnE '(dotsteward|cli\.sh) (update|sync)\b|(^|[^`])`(update (prepare|publish|status)|sync)\b|"--instance", [^,]+, "(update|sync)"' \
    . --exclude-dir=.git --exclude-dir=tests 2>/dev/null |
    grep -vE '^(\.\/)?(docs/cli\.md|cli/commands/(update|sync)\.sh|template/bootstrap\.sh|cli/lib/stage0\.sh):|the old name of' |
    grep -vE "^(\.\/)?cli/commands/preflight\.sh:.*stage0\.\\\$2\.env not found" || true
)
((${#found[@]} == 0)) || ds_fail "old command names: $(printf '%s\n' "${found[@]}" | cut -c1-120)"
