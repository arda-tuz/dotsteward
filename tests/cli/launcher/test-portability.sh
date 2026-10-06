# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The launcher runs before any Nix toolchain is on PATH, including on a
# stock macOS with /bin/bash 3.2 and BSD tools: no bash 4+ syntax, no GNU-only
# tool options, and sha256sum only with a shasum fallback.
# shellcheck source=tests/cli/launcher/helpers.sh
source "$DS_REPO_ROOT/tests/cli/launcher/helpers.sh"

[[ -f $launcher_template ]] || ds_fail "launcher template missing: $launcher_template"
# Git records only the executable bit; the exact mode follows the umask of
# the checkout (755 or 775), so only executability is checked here.
[[ -x $launcher_template ]] || ds_fail "launcher template is not executable: $launcher_template"
shebang=$(head -n 1 "$launcher_template")
stage=$(git -C "$DS_REPO_ROOT" ls-files --stage -- template/.dotsteward/cli.sh 2>/dev/null) || stage=""
mode=${stage%% *}
if [[ -n $mode ]]; then
  assert_eq 100755 "$mode" "template/.dotsteward/cli.sh is committed executable"
  assert_eq '#!/usr/bin/env bash' "$shebang"
else
  # Outside a git checkout (the Nix check copies the source and patches its
  # shebangs) the interpreter may already be a store bash.
  [[ $shebang == '#!/usr/bin/env bash' || $shebang == '#!/nix/store/'*/bin/bash ]] ||
    ds_fail "unexpected shebang: $shebang"
fi

# Code lines only: comments may mention anything.
code=$(sed -e 's/^[[:space:]]*#.*$//' "$launcher_template")

# pattern|reason pairs (extended regular expressions).
forbidden=(
  '(^|[^[:alnum:]_])(mapfile|readarray|coproc)([^[:alnum:]_]|$)|bash 4 builtin'
  'declare[[:space:]]+-[[:alpha:]]*[AnlucLU]|bash 4 declare option'
  'local[[:space:]]+-[[:alpha:]]*n|nameref (bash 4.3)'
  '\[\[[[:space:]]+-v[[:space:]]|[[ -v ]] (bash 4.2)'
  '\$\{[^}]*(,,|\^\^|,|\^)\}|case modification (bash 4)'
  '\$\{[^}]*@[QEPAaKkUuL]\}|parameter transformation (bash 4.4)'
  '\$\{[[:alnum:]_]+:[^}]*:-[0-9]+\}|negative substring length (bash 4.2)'
  '&>>|append both streams (bash 4)'
  '\|&|pipe both streams (bash 4)'
  '(^|[^[:alnum:]_])wait[[:space:]]+-n|wait -n (bash 4.3)'
  '(^|[^[:alnum:]_])readlink[[:space:]]+-[[:alpha:]]*[fem]|GNU readlink option'
  '(^|[^[:alnum:]_])realpath([^[:alnum:]_]|$)|not on macOS before 13'
  '(^|[^[:alnum:]_])sed[[:space:]]+(-[[:alpha:]]*[[:space:]]+)*-i|sed -i differs between GNU and BSD'
  '(^|[^[:alnum:]_])(stat|date)[[:space:]]+-[cd]|GNU stat/date option'
  '--(sort|printf|null-data|zero)([^[:alnum:]-]|$)|GNU-only long option'
)
for entry in "${forbidden[@]}"; do
  pattern=${entry%|*}
  reason=${entry##*|}
  if matches=$(grep -nE -e "$pattern" <<<"$code"); then
    ds_fail "launcher uses a non-portable construct ($reason): $matches"
  fi
done

# sha256sum is not on macOS: every use comes with the shasum fallback.
assert_contains "$code" "sha256sum"
assert_contains "$code" "shasum -a 256"

# bash -n parses it; shellcheck (when present) finds nothing.
bash -n "$launcher_template"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --shell=bash "$launcher_template"
fi
