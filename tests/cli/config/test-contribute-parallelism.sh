# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh and config_load
# The Nix parallelism of the framework check, the `nix flake check` of a
# framework clone that `dotsteward contribute check` runs
# (DS_CONTRIBUTE_NIX_MAX_JOBS, DS_CONTRIBUTE_NIX_CORES): a budget of its own,
# because its builds are test runs and evaluations, lighter than the
# instance builds the gate's budget is sized for. The total memory minus
# 2048 MiB is the budget, as for the gate; one job per full 3072 MiB of it,
# at most 4 jobs and at most one per CPU, at least one; the cores of a job
# follow the gate's rule (the CPUs divided among the jobs, at most one per
# full 1024 MiB of a job's share, at least one). gate.nix_max_jobs and
# gate.nix_cores, which size the instance builds, do not apply to it;
# DOTSTEWARD_CONTRIBUTE_NIX_MAX_JOBS and DOTSTEWARD_CONTRIBUTE_NIX_CORES
# override it for one run.
# shellcheck source=tests/cli/config/helpers.sh
source "$DS_REPO_ROOT/tests/cli/config/helpers.sh"

fw=$DS_TEST_ROOT/framework
make_framework "$fw"
instance=$DS_TEST_ROOT/instances/minimal
make_instance "$instance"
export DOTSTEWARD_PLATFORM=linux

# check MEMORY_MIB CPUS: "JOBS CORES" of the framework check on that machine.
check() {
  DOTSTEWARD_MEMORY_MIB=$1 DOTSTEWARD_CPU_COUNT=$2 load_config "$fw" "$instance"
  printf '%s %s\n' "$DS_CONTRIBUTE_NIX_MAX_JOBS" "$DS_CONTRIBUTE_NIX_CORES"
}
# gate MEMORY_MIB CPUS: "JOBS CORES" of the gate on that machine.
gate() {
  DOTSTEWARD_MEMORY_MIB=$1 DOTSTEWARD_CPU_COUNT=$2 load_config "$fw" "$instance"
  printf '%s %s\n' "$DS_GATE_NIX_MAX_JOBS" "$DS_GATE_NIX_CORES"
}

# Derived from the machine.
assert_eq "1 1" "$(check 3900 2)" "a 4 GiB machine with 2 CPUs"
assert_eq "1 1" "$(check 1024 64)" "less memory than the reserve"
assert_eq "1 1" "$(check 65536 1)" "one CPU"
assert_eq "1 5" "$(check 7900 8)" "an 8 GiB machine with 8 CPUs"
assert_eq "3 2" "$(check 12288 8)" "12 GiB with 8 CPUs"
assert_eq "4 3" "$(check 16384 12)" "16 GiB with 12 CPUs"
assert_eq "4 3" "$(check 15872 12)" "a 16 GiB machine with 12 CPUs whose kernel reports 15.5 GiB"
assert_eq "4 4" "$(check 32768 16)" "32 GiB with 16 CPUs: at most 4 jobs"
assert_eq "2 1" "$(check 65536 2)" "at most one job per CPU"

# Twice the gate's jobs on a 16 GiB machine with 12 CPUs.
assert_eq "2 6" "$(gate 16384 12)" "the gate on 16 GiB with 12 CPUs"

# The gate's configured values size the instance builds only.
printf '%s\n\n[gate]\nnix_max_jobs = 1\nnix_cores = 1\n' "$(<"$instance/workstation.toml")" >"$instance/workstation.toml"
assert_eq "4 3" "$(check 16384 12)" "configured gate values do not apply to the framework check"
assert_eq "1 1" "$(gate 16384 12)" "configured gate values"

# The environment overrides it for one run, one value or both.
assert_eq "6 2" "$(DOTSTEWARD_CONTRIBUTE_NIX_MAX_JOBS=6 DOTSTEWARD_CONTRIBUTE_NIX_CORES=2 check 16384 12)" \
  "both values from the environment"
assert_eq "6 2" "$(DOTSTEWARD_CONTRIBUTE_NIX_MAX_JOBS=6 check 16384 12)" "environment jobs, derived cores"
assert_eq "4 0" "$(DOTSTEWARD_CONTRIBUTE_NIX_CORES=0 check 16384 12)" "environment cores (0: every core)"
# The gate's overrides stay the gate's.
assert_eq "4 3" "$(DOTSTEWARD_NIX_MAX_JOBS=1 DOTSTEWARD_NIX_CORES=1 check 16384 12)" \
  "the gate's environment overrides do not apply to the framework check"

# Invalid overrides are refused with every problem.
assert_exit 1 env DOTSTEWARD_CONTRIBUTE_NIX_MAX_JOBS=0 DOTSTEWARD_CONTRIBUTE_NIX_CORES=many \
  "$fw/cli/dotsteward" --instance "$instance" context --json
assert_contains "$DS_STDERR" '[dotsteward] ERROR: DOTSTEWARD_CONTRIBUTE_NIX_MAX_JOBS: expected an integer >= 1, got "0"'
assert_contains "$DS_STDERR" '[dotsteward] ERROR: DOTSTEWARD_CONTRIBUTE_NIX_CORES: expected an integer >= 0, got "many"'
