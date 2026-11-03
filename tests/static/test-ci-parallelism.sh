# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The full check of ci.yml runs no more test files at once than its runner
# has vCPUs. Every framework check runs its suites with as many test files
# at once as its build has cores (mkTestCheck: tests/run.sh --jobs
# "$NIX_BUILD_CORES"), so `nix flake check --max-jobs J --cores C` runs up
# to J * C files at once. Without both options the runner builds one
# derivation per vCPU with every vCPU each (max-jobs auto, cores 0): 16
# test files at once on the 4 vCPUs of GitHub's ubuntu-24.04 runner of a
# public repository, which made the check slower than one file per build.
# The host-level step after it runs one test file at a time: each test of
# tests/host drives real Nix, whose evaluation and builds use every vCPU.

workflow=$DS_REPO_ROOT/.github/workflows/ci.yml
[[ -f $workflow ]] || ds_fail "missing .github/workflows/ci.yml"

# The runner of the full check and its vCPUs.
runner=ubuntu-24.04
vcpus=4

# job_values JOB KEY: the values of KEY (runs-on, or run of every step) in
# job JOB of ci.yml, one per line; a block value (run: |) gives its lines.
job_values() {
  awk -v job="$1" -v key="$2" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { current = $1; sub(/:$/, "", current); block = 0; next }
    current != job { next }
    block && index($0, indent " ") == 1 { line = $0; sub(/^[[:space:]]+/, "", line); print line; next }
    { block = 0 }
    $0 ~ "^[[:space:]]+(- )?" key ":" {
      line = $0
      sub("^[[:space:]]+(- )?" key ":[[:space:]]*", "", line)
      if (line ~ /^[|>][-+]?$/) {
        block = 1
        match($0, /^[[:space:]]+/)
        indent = substr($0, 1, RLENGTH)
        next
      }
      print line
    }' "$workflow"
}

# option NAME LINE: the number given as --NAME N or --NAME=N in LINE.
option() {
  sed -nE "s/^(.* )?--$1[ =]([0-9]+)( .*)?$/\2/p" <<<"$2"
}

assert_eq "$runner" "$(job_values check runs-on)" "the runner of the full check, whose vCPUs this test counts"
runs=$(job_values check run)

flake_check=$(grep -E '^nix flake check( |$)' <<<"$runs" || true)
[[ -n $flake_check ]] || ds_fail "the check job of ci.yml does not run nix flake check"
max_jobs=$(option max-jobs "$flake_check")
cores=$(option cores "$flake_check")
[[ -n $max_jobs && -n $cores ]] ||
  ds_fail "nix flake check in ci.yml runs without --max-jobs N and --cores N, so the runner builds one derivation per vCPU with every vCPU each: $flake_check"
((max_jobs >= 1 && cores >= 1)) ||
  ds_fail "nix flake check in ci.yml needs at least one job and one core per build: $flake_check"
((max_jobs * cores <= vcpus)) ||
  ds_fail "nix flake check in ci.yml runs up to $((max_jobs * cores)) test files at once (--max-jobs $max_jobs --cores $cores) on the $vcpus vCPUs of $runner"

host=$(grep -E '^bash tests/run\.sh( |$)' <<<"$runs" || true)
[[ -n $host ]] || ds_fail "the check job of ci.yml does not run the host-level tests"
assert_contains "$host" " tests/host" "the host-level step"
assert_eq 1 "$(option jobs "$host")" "test files at once in the host-level step of ci.yml ($host)"
