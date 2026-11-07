# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The apt engine runs under the system's python with python3-apt. On a machine without
# them the plan does not fall over: the report names the missing piece and the command
# that brings it. tests/apt-worlds has the engine itself, on a real apt.
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

work=$DS_TEST_ROOT/apt
mkdir -p "$work"
review=$DOTSTEWARD_STATE_ROOT/review.json

# No such interpreter: without a report an error, with one a decision for a person.
export DOTSTEWARD_APT_PYTHON=$work/no-such-python
status=0
core_python -m dotsteward_cli.apt_plan plan >"$work/out" 2>"$work/err" || status=$?
assert_eq 1 "$status"
assert_contains "$(<"$work/err")" "python3-apt-missing"

status=0
core_python -m dotsteward_cli.apt_plan plan --report apt-test >"$work/out" 2>"$work/err" || status=$?
assert_eq 3 "$status"
assert_json "$review" '.items[] | select(.code == "python3-apt-missing") | .run == "sudo apt-get install python3-apt"'

# A system python without the binding: the same answer, from the helper itself.
# python3 -S has no site packages, whatever the machine has installed.
printf '#!/bin/sh\nexec python3 -S "$@"\n' >"$work/python-without-apt"
chmod +x "$work/python-without-apt"
export DOTSTEWARD_APT_PYTHON=$work/python-without-apt
status=0
core_python -m dotsteward_cli.apt_plan analysis --report apt-test >"$work/out" 2>"$work/err" || status=$?
assert_eq 3 "$status"
assert_contains "$(<"$work/err")" "python3-apt-missing"
assert_json "$review" '[.items[].code] == ["python3-apt-missing"]'

# A helper that dies without an answer is a failure, not a plan with nothing to do.
printf '#!/bin/sh\necho "Traceback" >&2\nexit 9\n' >"$work/python-broken"
chmod +x "$work/python-broken"
export DOTSTEWARD_APT_PYTHON=$work/python-broken
status=0
core_python -m dotsteward_cli.apt_plan plan --report apt-test >"$work/out" 2>"$work/err" || status=$?
assert_eq 1 "$status"
assert_contains "$(<"$work/err")" "Traceback"

# A request that cannot be meant is a usage error before anything starts.
assert_usage() {
  status=0
  core_python -m dotsteward_cli.apt_plan plan --request - <<<"$1" >"$work/out" 2>"$work/err" || status=$?
  assert_eq 2 "$status" "the request $1"
}
assert_usage '{"mode": "everything"}'
assert_usage '{"accept": ["series:kernel"]}'
assert_usage '{"accept": ["series:gpu=1"]}'
assert_usage 'not json'

# --- the steps that change the system, with a helper that answers as told: the outcome of a
# commit decides the code of the run. The real helper runs in tests/container.

export DOTSTEWARD_APT_SUDO=''
canned=$work/canned.json
cat >"$work/python-canned" <<SCRIPT
#!/bin/sh
# Called as: python -I helper ACTION --output FILE
cp "$canned" "\$5"
SCRIPT
chmod +x "$work/python-canned"
export DOTSTEWARD_APT_PYTHON=$work/python-canned
mkdir -p "$work/bin"
export DOTSTEWARD_MODINFO=$work/bin/modinfo
# shellcheck disable=SC2016 # the text of a script, for its own shell
printf '#!/bin/sh\n[ "$4" != signer ] || echo "Canonical Ltd. Kernel Module Signing"\n' >"$work/bin/modinfo"
chmod +x "$work/bin/modinfo"

commit() {
  printf '%s\n' "$1" >"$canned"
  status=0
  core_python -m dotsteward_cli.apt_plan commit --report apt-test >"$work/out" 2>"$work/err" || status=$?
}

AFTER='"newest_kernel": {"abi": "7.0.0-44", "base": "generic", "release": "7.0.0-44-generic", "nvidia": true, "prebuilt": true, "driver_version": "595.99.02-0ubuntu1", "planned": false}'

commit "{\"status\": \"committed\", \"committed\": true, \"items\": [], $AFTER}"
assert_eq 0 "$status"
[[ ! -e $review ]] || ds_fail "a commit without items leaves no review"

commit '{"status": "nothing", "committed": false, "items": []}'
assert_eq 0 "$status"

# A refusal waits for a person; a failed download is a partial run; dpkg that failed a failure.
commit '{"status": "refused", "committed": false, "items": [{"code": "apt-denied", "pending": true, "class": "removal"}]}'
assert_eq 3 "$status"
assert_json "$review" '[.items[].code] == ["apt-denied"]'
commit '{"status": "fetch-failed", "committed": false, "items": [], "message": "no network"}'
assert_eq 6 "$status"
commit '{"status": "dpkg-failed", "committed": false, "items": [], "message": "dpkg error"}'
assert_eq 1 "$status"
commit '{"status": "blocked", "committed": false, "items": [{"code": "dpkg-lock-busy", "pending": true, "message": "held"}]}'
assert_eq 3 "$status"
assert_json "$review" '[.items[].code] == ["dpkg-lock-busy"]'

# A note is no decision: the run is done, the review names it.
commit "{\"status\": \"committed\", \"committed\": true, \"dpkg_dist\": [\"/etc/example.conf.dpkg-dist\"], \"rollback\": {\"missing\": [\"example=1\"]}, \"items\": [{\"code\": \"module-loss\", \"pending\": false, \"packages\": [\"example\"]}], $AFTER}"
assert_eq 0 "$status"
assert_json "$review" '[.items[].code] == ["module-loss", "dpkg-dist", "rollback-missing"]'
assert_json "$review" '.items[] | select(.code == "dpkg-dist") | .path == "/etc/example.conf.dpkg-dist"'

# The module of the newest kernel, whatever the commit did: signed by the distribution, by somebody
# else, of another version, or not there. A person looks at all but the first.
modinfo_says() {
  # shellcheck disable=SC2016 # the text of a script, for its own shell
  printf '#!/bin/sh\n[ "%s" != missing ] || exit 1\ncase "$4" in\n  signer) echo "%s" ;;\n  version) echo "%s" ;;\nesac\n' "$1" "$1" "$2" >"$work/bin/modinfo"
}
modinfo_says "Canonical Ltd. Kernel Module Signing" 595.99.02
commit "{\"status\": \"committed\", \"committed\": true, \"items\": [], $AFTER}"
assert_eq 0 "$status"
modinfo_says "machine owner key" 595.99.02
commit "{\"status\": \"committed\", \"committed\": true, \"items\": [], $AFTER}"
assert_eq 3 "$status"
assert_json "$review" '.items[] | select(.code == "module-signer") | .signer == "machine owner key" and .kernel == "7.0.0-44-generic"'
# A module the machine builds and signs itself is a note only.
commit "{\"status\": \"committed\", \"committed\": true, \"items\": [], ${AFTER/\"prebuilt\": true/\"prebuilt\": false}}"
assert_eq 0 "$status"
assert_json "$review" '.items[] | select(.code == "module-signer") | .signer == "machine owner key"'
modinfo_says "Canonical Ltd. Kernel Module Signing" 595.80.01
commit "{\"status\": \"committed\", \"committed\": true, \"items\": [], $AFTER}"
assert_eq 3 "$status"
assert_json "$review" '.items[] | select(.code == "module-version") | .module == "595.80.01" and .driver == "595.99.02" and .kernel == "7.0.0-44-generic"'
modinfo_says missing ""
for outcome in committed nothing refused dpkg-failed; do
  commit "{\"status\": \"$outcome\", \"committed\": false, \"items\": [], $AFTER}"
  ((status != 0)) || ds_fail "a kernel without a module after $outcome is no green run"
  assert_json "$review" '.items[] | select(.code == "module-missing") | .kernel == "7.0.0-44-generic" and (.message | test("do not reboot"))'
done
# What the plan brings is no finding, and without the NVIDIA class there is no module to look for.
commit "{\"status\": \"nothing\", \"committed\": false, \"items\": [], ${AFTER/\"nvidia\": true/\"nvidia\": false}}"
assert_eq 0 "$status"
commit "{\"status\": \"nothing\", \"committed\": false, \"items\": [], ${AFTER/\"planned\": false/\"planned\": true}}"
assert_eq 0 "$status"
# No modinfo at all: said, and no decision.
export DOTSTEWARD_MODINFO=$work/bin/no-such-modinfo
commit "{\"status\": \"nothing\", \"committed\": false, \"items\": [], $AFTER}"
assert_eq 0 "$status"
assert_json "$review" '.items[] | select(.code == "module-unchecked") | .kernel == "7.0.0-44-generic"'
export DOTSTEWARD_MODINFO=$work/bin/modinfo
modinfo_says "Canonical Ltd. Kernel Module Signing" 595.99.02

# The helper dies without an answer: a failure, and its status is named.
printf '#!/bin/sh\nexit 137\n' >"$work/python-canned"
status=0
core_python -m dotsteward_cli.apt_plan commit --report apt-test >"$work/out" 2>"$work/err" || status=$?
assert_eq 1 "$status"
assert_contains "$(<"$work/err")" "apt-helper-failed: the apt helper ended with status 137"

# What the child prints goes to a private file, named by the answer and the report, and from there
# to standard error; the answer stays on its own stream. An empty file does not stay.
logs=$DOTSTEWARD_STATE_ROOT/apt-logs
assert_eq "" "$(ls -A "$logs" 2>/dev/null)" "nothing printed, no log"
cat >"$work/python-canned" <<SCRIPT
#!/bin/sh
echo "Setting up example (2.0)"
echo "dpkg: warning: example" >&2
cp "$canned" "\$5"
SCRIPT
commit '{"status": "committed", "committed": true, "items": []}'
assert_eq 0 "$status"
log_file=$(jq -r .log "$work/out")
assert_contains "$log_file" "$logs/commit-"
assert_contains "$(<"$log_file")" "Setting up example (2.0)"
assert_contains "$(<"$log_file")" "dpkg: warning: example"
assert_file_mode "$log_file" 600
assert_file_mode "$logs" 700
assert_contains "$(<"$work/err")" "Setting up example (2.0)"
assert_contains "$(<"$work/err")" "dpkg: warning: example"
# Reports are ordered by their sequence: two of one second sort by chance by name.
assert_eq "$log_file" "$(find "$DOTSTEWARD_STATE_ROOT/runs/apt-test" -name '*.json' -exec cat {} + | jq -rs 'max_by(.sequence) | .steps[] | select(.name == "commit") | .log')"
# A standard error nobody can write to changes nothing for the child or the answer.
status=0
core_python -m dotsteward_cli.apt_plan commit >"$work/out" 2>&- || status=$?
assert_eq 0 "$status"
assert_json "$work/out" '.status == "committed"'
assert_eq 2 "$(wc -l <"$(jq -r .log "$work/out")" | tr -d ' ')" "the log holds what the child printed, once"
# Old logs do not pile up.
for _ in {1..22}; do
  core_python -m dotsteward_cli.apt_plan commit >/dev/null 2>&1
done
assert_eq 20 "$(find "$logs" -type f | wc -l | tr -d ' ')"

# Without a state root that commands agree on there is no place for the log, before anything starts.
rm -f "$work/started"
printf '#!/bin/sh\n: >"%s"\n' "$work/started" >"$work/python-canned"
status=0
(cd "$work" && env -u DOTSTEWARD_STATE_ROOT -u DOTSTEWARD_INSTANCE HOME="$work" PYTHONPATH="$DS_REPO_ROOT/cli/python" PYTHONDONTWRITEBYTECODE=1 \
  python3 -s -P -m dotsteward_cli.apt_plan commit >"$work/out" 2>"$work/err") || status=$?
assert_eq 1 "$status"
assert_contains "$(<"$work/err")" "no-state-root"
[[ ! -e $work/started ]] || ds_fail "the helper started without a place for its output"

# A signal to the parent waits for the child and lands in the report.
cat >"$work/python-canned" <<SCRIPT
#!/bin/sh
: >"$work/started"
while [ ! -e "$work/go" ]; do sleep 0.05; done
cp "$canned" "\$5"
SCRIPT
printf '%s\n' '{"status": "committed", "committed": true, "items": []}' >"$canned"
rm -f "$work/started" "$work/go"
PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.apt_plan commit \
  --report apt-signal >"$work/out" 2>"$work/err" &
parent=$!
core_wait "$work/started"
kill -TERM "$parent"
sleep 0.2
kill -0 "$parent" || ds_fail "the parent did not stay until the child ended"
: >"$work/go"
status=0
wait "$parent" || status=$?
assert_eq 0 "$status"
assert_json "$work/out" '.interrupted == ["SIGTERM"] and .status == "committed"'
assert_json "$(find "$DOTSTEWARD_STATE_ROOT/runs/apt-signal" -name '*.json')" '.interrupted == ["SIGTERM"]'
