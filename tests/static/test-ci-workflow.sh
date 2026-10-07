# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The ci workflow runs the self-test of the VM harness (tests/vm/selftest.sh,
# which never boots a virtual machine) in its lint job, after the Nix
# install whose pinned shellcheck the self-test uses, so a change that
# breaks the harness fails CI instead of the next VM phase.

workflow=$DS_REPO_ROOT/.github/workflows/ci.yml
[[ -f $workflow ]] || ds_fail "missing .github/workflows/ci.yml"

# lint_steps: the run lines of the lint job, in order.
lint_steps=$(awk '
  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); next }
  job == "lint" && /^[[:space:]]+run:/ { line = $0; sub(/^[[:space:]]+run:[[:space:]]*/, "", line); print line }
' "$workflow")
[[ -n $lint_steps ]] || ds_fail "ci.yml has no lint job with run steps"

install=$(grep -nxF 'bash tests/ci/install-nix.sh' <<<"$lint_steps" | cut -d: -f1 || true)
selftest=$(grep -nxF 'bash tests/vm/selftest.sh' <<<"$lint_steps" | cut -d: -f1 || true)
[[ -n $install ]] || ds_fail "the lint job of ci.yml does not install Nix"
[[ -n $selftest ]] || ds_fail "the lint job of ci.yml does not run bash tests/vm/selftest.sh"
((selftest > install)) || ds_fail "the lint job runs the VM harness self-test before the Nix install"
