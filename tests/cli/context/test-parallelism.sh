# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The Nix parallelism of the gate (gate.nix_max_jobs, gate.nix_cores), as
# `dotsteward context --json` reports it and `dotsteward gate` passes it to
# Nix. Without a configured value it is derived from the machine: the total
# memory in MiB minus 2048 MiB for the evaluation and the system is the
# budget; one job per full 6144 MiB of it, at most one per CPU and at least
# one; the cores of a job are the CPUs divided among the jobs, at most one
# per full 1024 MiB of the job's share of the budget, and at least one. So a
# 4 GiB machine builds one derivation on one core, and a 16 GiB machine
# with 12 CPUs keeps the earlier fixed values, two jobs with six cores.
# DOTSTEWARD_MEMORY_MIB and DOTSTEWARD_CPU_COUNT replace the facts of the
# machine (tests, containers with tighter limits); a configured value wins
# over the derived one, and DOTSTEWARD_NIX_MAX_JOBS and DOTSTEWARD_NIX_CORES
# win over both.
# shellcheck source=tests/cli/context/helpers.sh
source "$DS_REPO_ROOT/tests/cli/context/helpers.sh"

export DOTSTEWARD_PLATFORM=linux

inst=$DS_TEST_ROOT/instances/minimal
make_minimal_instance "$inst"
base_config=$(<"$inst/workstation.toml")

# parallelism MEMORY_MIB CPUS: "JOBS CORES" of the instance for that machine.
parallelism() {
  DOTSTEWARD_MEMORY_MIB=$1 DOTSTEWARD_CPU_COUNT=$2 context_json "$inst" |
    jq -r '"\(.gate.nix_max_jobs) \(.gate.nix_cores)"'
}

# The defaults are not fixed numbers any more.
assert_eq null "$(jq -c '.properties.gate.properties.nix_max_jobs.default' "$DS_REPO_ROOT/schema/workstation.schema.json")"
assert_eq null "$(jq -c '.properties.gate.properties.nix_cores.default' "$DS_REPO_ROOT/schema/workstation.schema.json")"

# Derived from the machine.
assert_eq "1 1" "$(parallelism 3900 2)" "a 4 GiB machine with 2 CPUs"
assert_eq "1 1" "$(parallelism 3900 4)" "a 4 GiB machine with 4 CPUs"
assert_eq "1 1" "$(parallelism 1024 64)" "less memory than the reserve"
assert_eq "1 1" "$(parallelism 65536 1)" "one CPU"
assert_eq "1 5" "$(parallelism 7900 8)" "an 8 GiB machine with 8 CPUs"
assert_eq "2 6" "$(parallelism 16384 12)" "a 16 GiB machine with 12 CPUs (MemTotal of 16 GiB)"
assert_eq "2 6" "$(parallelism 16384 12)" "16 GiB with 12 CPUs"
assert_eq "4 4" "$(parallelism 32000 16)" "a 32 GiB machine with 16 CPUs"
assert_eq "8 1" "$(parallelism 65536 8)" "at most one job per CPU"

# The harness pins the machine to 16 GiB and 12 CPUs, so the other tests see
# the values of that machine.
assert_eq "16384 12" "$DOTSTEWARD_MEMORY_MIB $DOTSTEWARD_CPU_COUNT"
assert_eq '{"nix_max_jobs":2,"nix_cores":6}' "$(context_json "$inst" | jq -c '.gate | {nix_max_jobs, nix_cores}')"

# The real machine: positive integers.
doc=$(env -u DOTSTEWARD_MEMORY_MIB -u DOTSTEWARD_CPU_COUNT "$context_framework/cli/dotsteward" --instance "$inst" context --json)
jq -e '.gate.nix_max_jobs >= 1 and .gate.nix_cores >= 1 and (.gate.nix_max_jobs | type) == "number"' <<<"$doc" >/dev/null ||
  ds_fail "unexpected parallelism of this machine: $(jq -c .gate <<<"$doc")"

# Configured values win: an instance keeps fixed values on every machine.
printf '%s\n\n[gate]\nnix_max_jobs = 2\nnix_cores = 6\n' "$base_config" >"$inst/workstation.toml"
assert_eq "2 6" "$(parallelism 3900 2)" "configured values on a small machine"
# One configured key: the other is derived around it.
printf '%s\n\n[gate]\nnix_max_jobs = 3\n' "$base_config" >"$inst/workstation.toml"
assert_eq "3 4" "$(parallelism 16384 12)" "configured jobs, derived cores"
printf '%s\n\n[gate]\nnix_cores = 3\n' "$base_config" >"$inst/workstation.toml"
assert_eq "1 3" "$(parallelism 3900 2)" "configured cores, derived jobs"
# The environment wins over both.
assert_eq "5 7" "$(DOTSTEWARD_NIX_MAX_JOBS=5 DOTSTEWARD_NIX_CORES=7 parallelism 3900 2)" "environment overrides"
printf '%s\n' "$base_config" >"$inst/workstation.toml"
assert_eq "5 1" "$(DOTSTEWARD_NIX_MAX_JOBS=5 parallelism 3900 2)" "an environment job count, derived cores"

# The machine facts must be positive integers.
assert_exit 1 env DOTSTEWARD_MEMORY_MIB=0 DOTSTEWARD_CPU_COUNT=many \
  "$context_framework/cli/dotsteward" --instance "$inst" context --json
assert_contains "$DS_STDERR" '[dotsteward] ERROR: DOTSTEWARD_MEMORY_MIB: expected an integer >= 1, got "0"'
assert_contains "$DS_STDERR" '[dotsteward] ERROR: DOTSTEWARD_CPU_COUNT: expected an integer >= 1, got "many"'

# The documents state the rule with the numbers of the code.
for doc_file in docs/workstation-toml.md plugins/dotsteward/skills/dotsteward-init/references/platform-prereqs.md README.md; do
  text=$(<"$DS_REPO_ROOT/$doc_file")
  assert_contains "$text" "4 GiB" "$doc_file names the smallest supported memory"
done
text=$(<"$DS_REPO_ROOT/docs/workstation-toml.md")
for fact in "2048 MiB" "6144 MiB" "1024 MiB" "DOTSTEWARD_MEMORY_MIB" "DOTSTEWARD_CPU_COUNT"; do
  assert_contains "$text" "$fact" "docs/workstation-toml.md explains the derived parallelism"
done
