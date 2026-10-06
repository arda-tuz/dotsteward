# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# G7 and G8, the five steps ([gate] I10, I12, SPEC D4): a passing gate runs
# preflight, static, pins, flake-check and cli-probes in this order, quietly
# (each step's output goes to the private validate.log under a
# "== <step>: <command>" header), prints one "ok" line per step, writes the
# private validation.json (schema 1.1, the five step keys) atomically and
# prints {result, tree_oid, scope, total_seconds, step_seconds}. A failing
# step stops the gate: a FAILED line, the last 60 log lines and the log path
# on stderr, exit 1, no later step, and the previous record is kept.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

# --- success --------------------------------------------------------------------

assert_exit 0 run_gate --scope maintain
assert_eq "" "$DS_STDERR"
assert_eq $'preflight\nstatic\npins\nflake-check\ncli-probes' "$(step_lines)"
assert_eq 7 "$(wc -l <<<"$DS_STDOUT")"
assert_eq "[dotsteward] candidate validated; nothing committed or pushed" "$(sed -n 6p <<<"$DS_STDOUT")"
summary=$(tail -n 1 <<<"$DS_STDOUT")
assert_json - '(keys | sort) == (["result", "scope", "step_seconds", "total_seconds", "tree_oid"])
  and .result == "passed" and .scope == "maintain"
  and (.step_seconds | keys_unsorted) == ["preflight", "static", "pins", "flake-check", "cli-probes"]' <<<"$summary"
[[ $summary != *$'\n'* && $summary == '{"result":'* ]] || ds_fail "the summary is not one compact JSON line: $summary"

tree=$(add_tree_oid)
assert_file_mode "$gate_state" 700
assert_file_mode "$gate_validation" 600
assert_file_mode "$gate_log" 600
assert_json "$gate_validation" '(keys_unsorted) == ["schema_version", "result", "tree_oid", "base_oid", "scope",
  "nix_version", "gate_version", "framework_override", "denylist_sha256", "root", "validated_at",
  "total_seconds", "step_seconds", "log"]'
jq -e --arg tree "$tree" --arg base "$(head_oid)" --arg root "$gate_inst" --arg log "$gate_log" \
  --arg version "$(<"$DS_REPO_ROOT/VERSION")" '
  .schema_version == "1.1" and .result == "passed" and .tree_oid == $tree and .base_oid == $base
  and .scope == "maintain" and .nix_version == "nix (Nix) 2.31.2" and .gate_version == $version
  and .framework_override == null and .denylist_sha256 == null and .root == $root and .log == $log
  and (.validated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (.total_seconds | type) == "number"
  and ([.step_seconds[] | type == "number" and . >= 0] | all)
  and (.step_seconds | keys_unsorted) == ["preflight", "static", "pins", "flake-check", "cli-probes"]' \
  "$gate_validation" >/dev/null || ds_fail "unexpected record: $(<"$gate_validation")"
assert_eq "$(jq -c '{result, tree_oid, scope, total_seconds, step_seconds}' "$gate_validation")" "$summary"

# The calls, in order: the version, the cache probe, the three commands and
# the two Nix builds with the default parallelism.
assert_eq $'static\npins check --nix' "$(fake_calls | head -n 2)"
assert_eq "probes --generation" "$(fake_calls | sed -n 3p | cut -d' ' -f1-2)"
assert_call_count 1 nix '*--version'
assert_call_count 1 curl
assert_eq "$(nix_line flake check "$gate_inst" --no-update-lock-file --keep-going -L --max-jobs 2 --cores 6)" \
  "$(ds_calls_of nix | grep -F ' flake check ')"
assert_eq "$(nix_line build "$gate_inst#checks.x86_64-linux.home" --no-link --no-update-lock-file \
  --print-out-paths --max-jobs 2 --cores 6)" "$(ds_calls_of nix | grep -F ' build ')"
generation=$(fake_calls | sed -n 3p | cut -d' ' -f3)
[[ -d $generation/home-path/bin ]] || ds_fail "probes did not get the built generation: $generation"
# Every step command sees the instance.
assert_eq 3 "$(grep -c "^dotsteward-[a-z]*:env DOTSTEWARD_INSTANCE=$gate_inst -DOTSTEWARD_FRAMEWORK_OVERRIDE$" "$DS_CALL_LOG")"
# The order of the external calls follows the steps.
order=$(awk '$1 == "curl" { print "curl" } $1 ~ /^dotsteward-[a-z]+$/ { print $1 }
  $1 == "nix" && / flake check / { print "flake" } $1 == "nix" && / build / { print "build" }' "$DS_CALL_LOG")
assert_eq $'curl\ndotsteward-static\ndotsteward-pins\nflake\nbuild\ndotsteward-probes' "$order"

# The log holds every step's header and output.
log=$(<"$gate_log")
for step in preflight static pins flake-check cli-probes; do
  assert_eq 1 "$(grep -c "^== $step: " <<<"$log")" "header of $step"
done
assert_contains "$log" "fake static output"
assert_contains "$log" "fake pins output"
assert_contains "$log" "fake probes output"
assert_eq "== static: dotsteward static" "$(grep '^== static: ' <<<"$log")"
assert_eq "== pins: dotsteward pins check --nix" "$(grep '^== pins: ' <<<"$log")"
assert_eq "" "$(temp_dirs)" "temporary directories left behind"

# The configured parallelism, then the environment overrides.
set_toml gate nix_max_jobs 3
set_toml gate nix_cores 4
commit_all "chore: tune the parallelism"
: >"$DS_CALL_LOG"
assert_exit 0 run_gate --scope maintain
assert_call_count 1 nix '*flake check * --max-jobs 3 --cores 4'
assert_call_count 1 nix '* build * --max-jobs 3 --cores 4'
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_NIX_MAX_JOBS=1 DOTSTEWARD_NIX_CORES=2 \
  "$gate_fw/cli/dotsteward" --instance "$gate_inst" gate --scope maintain --force
assert_call_count 1 nix '*flake check * --max-jobs 1 --cores 2'

# A second run starts a new log.
assert_eq 1 "$(grep -c '^== static: ' "$gate_log")" "the log was not truncated"

# --- failure ----------------------------------------------------------------------

record=$(<"$gate_validation")
mkdir -p "$gate_inst/notes"
printf 'a\n' >"$gate_inst/notes/a.txt"
commit_all "docs: add a note"
step_fail pins 3
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
assert_eq $'preflight\nstatic' "$(step_lines)"
assert_not_contains "$DS_STDOUT" "candidate validated"
assert_eq "[dotsteward] pins         FAILED (0s)" "$(grep 'FAILED' <<<"$DS_STDERR" | sed 's/([0-9]*s)/(0s)/')"
assert_contains "$DS_STDERR" "fake pins output"
assert_eq "[dotsteward] ERROR: gate step failed: pins; full log: $gate_log" "$(tail -n 1 <<<"$DS_STDERR")"
assert_eq $'static\npins check --nix' "$(fake_calls)"
assert_call_count 0 nix '*flake check*'
assert_call_count 0 nix '* build *'
assert_eq "$record" "$(<"$gate_validation")" "a failed run changed the record"
assert_contains "$(<"$gate_log")" "fake pins output"
step_fail pins 0

# The tail is the last 60 log lines.
for i in $(seq -w 1 100); do
  printf 'check output line %s\n' "$i"
done >"$DS_TEST_ROOT/flake-output"
ds_stub_route nix 'flake check *' --exit 1 --stdout-file "$DS_TEST_ROOT/flake-output"
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
assert_eq $'preflight\nstatic\npins' "$(step_lines)"
assert_contains "$DS_STDERR" "flake-check  FAILED ("
assert_contains "$DS_STDERR" "check output line 100"
assert_contains "$DS_STDERR" "check output line 041"
assert_not_contains "$DS_STDERR" "check output line 040"
assert_eq "[dotsteward] ERROR: gate step failed: flake-check; full log: $gate_log" "$(tail -n 1 <<<"$DS_STDERR")"
assert_eq 62 "$(wc -l <<<"$DS_STDERR")"
assert_contains "$(<"$gate_log")" "check output line 001"
assert_eq $'static\npins check --nix' "$(fake_calls)"
assert_call_count 0 nix '* build *'
assert_eq "$record" "$(<"$gate_validation")"
ds_stub_clear_routes nix

# The same tree passes once the failure is gone.
assert_exit 0 run_gate --scope maintain
assert_eq "$(add_tree_oid)" "$(jq -r .tree_oid "$gate_validation")"
