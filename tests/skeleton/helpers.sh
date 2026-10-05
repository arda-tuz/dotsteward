# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers shared by the skeleton tests. Not a test file (no test- prefix).

# copy_framework DEST: copies the dispatcher, the version command, VERSION
# and the test runner with its libraries into DEST, so a test can add commands
# or files freely. Other command files are left out on purpose: the skeleton
# tests must not depend on commands that later tasks add.
copy_framework() {
  local dest=$1
  mkdir -p "$dest/tests" "$dest/cli/commands"
  cp "$DS_REPO_ROOT/cli/dotsteward" "$dest/cli/dotsteward"
  cp "$DS_REPO_ROOT/cli/commands/version.sh" "$dest/cli/commands/version.sh"
  cp "$DS_REPO_ROOT/VERSION" "$dest/VERSION"
  cp "$DS_REPO_ROOT/tests/run.sh" "$dest/tests/run.sh"
  cp -R "$DS_REPO_ROOT/tests/lib" "$dest/tests/lib"
  # The harness may read shared fixtures relative to its own location.
  if [[ -d $DS_REPO_ROOT/tests/fixtures ]]; then
    cp -R "$DS_REPO_ROOT/tests/fixtures" "$dest/tests/fixtures"
  fi
}

# write_command FRAMEWORK NAME SUMMARY BODY: adds cli/commands/NAME.sh.
write_command() {
  local file=$1/cli/commands/$2.sh
  {
    printf '#!/usr/bin/env bash\n'
    [[ -z $3 ]] || printf '# summary: %s\n' "$3"
    printf 'set -Eeuo pipefail\n%s\n' "$4"
  } >"$file"
  chmod 0755 "$file"
}
