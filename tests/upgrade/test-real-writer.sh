# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and the variables of the writer tests come from their helpers
# The real writer under `upgrade`: a real `pins apply` on the world of its own tests moves real pins,
# upgrade reads its document and commits the tree; the week of the flake inputs is a --skip it
# understands, a hold too, and what stays for review keeps its own command in review.json. The
# rest of the run is fake: the writer is what this test is about, and it needs no network.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"
# shellcheck source=tests/upgrade/isolation.sh
source "$DS_REPO_ROOT/tests/upgrade/isolation.sh"
apply_world
export PATH=$DS_TEST_ROOT/up-bin:$PATH

export UP_LOG=$DS_TEST_ROOT/steps.log UP_CONTROL=$DS_TEST_ROOT/control
export UP_APT=$DS_TEST_ROOT/apt DOTSTEWARD_APT_PYTHON=$DS_TEST_ROOT/apt-python
mkdir -p "$UP_CONTROL" "$UP_APT"
: >"$UP_LOG"
cp "$DS_REPO_ROOT/tests/upgrade/fakes/apt-python" "$DOTSTEWARD_APT_PYTHON"
chmod 0755 "$DOTSTEWARD_APT_PYTHON"
printf '{"available": true, "count": 0, "packages": [], "kernels": 1, "boot_free_mib": 900, "boot_low": false}\n' >"$UP_APT/analysis.json"

fw=$DS_TEST_ROOT/framework
mkdir -p "$fw/modules/components"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$DS_REPO_ROOT/privacy" "$DS_REPO_ROOT/engines" "$fw/"
find "$fw" -name __pycache__ -prune -exec rm -rf {} +
for fake in rebuild e2e static probes; do
  cp "$DS_REPO_ROOT/tests/upgrade/fakes/$fake.sh" "$fw/cli/commands/$fake.sh"
done
for command in gate txn host; do
  cat >"$fw/cli/commands/$command.sh" <<FAKE
#!/usr/bin/env bash
# summary: Fake $command of this test
printf '$command %s\n' "\$*" >>"$UP_LOG"
FAKE
done
cat >>"$fw/cli/commands/txn.sh" <<'FAKE'
if [[ $1 == publish ]]; then
  git -C "$DOTSTEWARD_INSTANCE" push -q origin HEAD:main
fi
FAKE
# The rows as a research would find them, without a network.
real_pins=$fw/cli/commands/pins-real
mv -- "$fw/cli/commands/pins.sh" "$real_pins"
cat >"$fw/cli/commands/pins.sh" <<FAKE
#!/usr/bin/env bash
# summary: The real pins of this test, with the rows of the test instead of a research
printf 'pins %s\n' "\$*" >>"$UP_LOG"
for argument in "\$@"; do
  if [[ \$argument == latest ]]; then
    cp -- "$rows" "\$3"
    exit 0
  fi
done
exec "\$BASH" -- "$real_pins" "\$@"
FAKE
chmod 0755 "$fw/cli/commands/"*.sh "$real_pins"

bare=$DS_TEST_ROOT/remote.git
remote=$(jq -r .instance.remote <<<"$(python3 -c 'import sys, tomllib, json; print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))' "$inst/workstation.toml")")
git init -q --bare "$bare"
git -C "$inst" remote remove origin 2>/dev/null || true
git -C "$inst" remote add origin "$remote"
git -C "$inst" add -A
git -C "$inst" diff --cached --quiet || git -C "$inst" commit -q -m "chore: the world"
git -C "$inst" push -q "$bare" HEAD:main
git -C "$inst" config url."$bare".insteadOf "$remote"
git -C "$inst" fetch -q origin
branch=$(git -C "$inst" rev-parse --abbrev-ref HEAD)
assert_eq main "$branch"

upgrade() {
  "$fw/cli/dotsteward" --instance "$inst" upgrade "$@" </dev/null
}

digest=$(printf '%064d' 7)
download=$(row agent_tools.example-release github-release 4.0.0 4.1.0 update '{"tag":"v4.1.0","asset":"example-release-linux-x64.tar.gz","size":4242,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz"}')
rows "$download"
assert_exit 3 upgrade --tracked
assert_contains "$(<"$UP_LOG")" "pins apply --latest"
assert_eq '"4.1.0"' "$(json_get "$versions" '.agent_tools["example-release"].minimum_version')"
assert_eq "chore: update pinned tool versions" "$(git -C "$inst" log -1 --format=%s)"
assert_eq "" "$(git -C "$inst" status --porcelain)"
newest=$(jq -r --slurp 'max_by(.sequence) | .run' "$state"/runs/upgrade/*.json)
assert_json "$state/runs/upgrade/$newest.json" '[.steps[] | select(.name == "pins-apply") | .moved] == [["agent_tools.example-release"]]'
assert_contains "$(<"$UP_LOG")" "txn publish --scope update"

# A hold of that version: the real writer says the row is skipped and moves the next one.
later=$(row agent_tools.example-release github-release 4.1.0 4.2.0 update '{"tag":"v4.2.0","asset":"example-release-linux-x64.tar.gz","size":4242,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.2.0/example-release-linux-x64.tar.gz"}')
rows "$later"
jq -n '{schema_version: 1, holds: [{component: "example-release", id: "agent_tools.example-release", version: "4.2.0", reason: "E2E red", since: "2026-01-01T00:00:00Z"}]}' >"$state/holds.json"
: >"$UP_LOG"
assert_exit 3 upgrade --tracked
assert_contains "$(<"$UP_LOG")" "--skip agent_tools.example-release"
assert_eq '"4.1.0"' "$(json_get "$versions" '.agent_tools["example-release"].minimum_version')"
