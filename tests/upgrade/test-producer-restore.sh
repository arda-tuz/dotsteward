# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and the variables of the writer tests come from their helpers
# The answer of the producer to a consumer that holds a shared lock back (T19), through the real
# writer: the pins of the components that went red there come back from the commit the consumer
# went back to as whole groups (a download pin with its digest, a pypi pin with its hash-pinned
# requirements), so the published lock is the consistent lock of that commit for them and the real
# `pins check` passes on it; upstream still calls the red versions the latest, and a local hold
# keeps the writer from moving them there again. The rest of the run is fake.
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
git config --global url."$bare".insteadOf "$remote"
mkdir -p "$state"
jq -n '{schema_version: 1, name: "example-host", machine_key: "00112233445566778899aabbccddeeff", named_at: "2026-01-01T00:00:00Z",
  host: {system: "x86_64-linux", profile: "main", platform: "ubuntu-24.04", tags: []}}' >"$state/machine.json"
git -C "$inst" fetch -q origin
branch=$(git -C "$inst" rev-parse --abbrev-ref HEAD)
assert_eq main "$branch"

upgrade() {
  "$fw/cli/dotsteward" --instance "$inst" upgrade "$@" </dev/null
}

# Two components own pins: an official binary and a pypi application.
json_edit "$manifest" '
data["components"].append({"name": "example-release", "method": "official-binary", "install": {"pin": "agent_tools.example-release", "dest": "~/.local/bin/example-release"}})
data["components"][0]["method"] = "pypi"
'
mkdir -p "$inst/hosts"
printf 'schema_version = 1\n' >"$inst/hosts/other-host.toml"
printf '\n[hosts]\nproducer = "example-host"\n' >>"$inst/workstation.toml"
git -C "$inst" add -A
git -C "$inst" commit -q -m "chore: two machines, this one the producer"
git -C "$inst" push -q origin HEAD:main
x=$(git -C "$inst" rev-parse HEAD)
release_x=$(json_get "$versions" '.agent_tools["example-release"]')
requirements=$inst/components/example-tool/requirements.txt
requirements_x=$(<"$requirements")

# Y: the producer moves both.
digest=$(printf '%064d' 7)
rows "$(row agent_tools.example-release github-release 4.0.0 4.1.0 update '{"tag":"v4.1.0","asset":"example-release-linux-x64.tar.gz","size":4242,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz"}')" \
  "$(row pypi.example-tool pypi 1.0.0 1.1.0 update)"
upgrade --tracked >/dev/null 2>&1 || true
git -C "$inst" fetch -q origin
y=$(git -C "$inst" rev-parse origin/main)
[[ $y != "$x" ]] || ds_fail "nothing was published"
assert_contains "$(git -C "$inst" show "$y:components/example-tool/requirements.txt")" "example-tool==1.1.0"

# other-host went back to X: both went red there.
jq -n --arg x "$x" --arg y "$y" '{schema_version: 1, host: "other-host", machine_key: "ffeeddccbbaa99887766554433221100",
  recorded_at: "2026-01-02T00:00:00Z", recorded_by: "upgrade", components: {},
  held: {commit: $x, lock_commit: $y, components: ["example-release", "example-tool"], at: "2026-01-02T00:00:00Z"}}' \
  >"$DS_TEST_ROOT/other.json"
blob=$(git -C "$bare" hash-object -w "$DS_TEST_ROOT/other.json")
tree=$(printf '100644 blob %s\tstate.json\n' "$blob" | git -C "$bare" mktree)
commit=$(git -C "$bare" -c user.name=o -c user.email=o@example.invalid commit-tree "$tree" -m "state: other-host")
git -C "$bare" update-ref refs/heads/state/other-host "$commit"

# Upstream still calls them the latest; the answer puts both groups back.
upgrade --tracked >/dev/null 2>&1 || true
published=$DS_TEST_ROOT/published
git clone -q "$bare" "$published"
assert_eq "$release_x" "$(jq -c '.agent_tools["example-release"]' "$published/versions.lock.json")"
assert_eq "$requirements_x" "$(<"$published/components/example-tool/requirements.txt")"
assert_eq '"1.0.0"' "$(jq -c '.pypi["example-tool"].version' "$published/versions.lock.json")"
assert_exit 0 "$fw/cli/dotsteward" --instance "$published" pins check
assert_json "$state/holds.json" '[.holds[] | select(.id == "pypi.example-tool" and .version == "1.1.0")] | length == 1'

# The next run moves neither again while upstream calls the red versions the latest.
tip=$(git -C "$bare" rev-parse main)
upgrade --tracked >/dev/null 2>&1 || true
assert_eq "$tip" "$(git -C "$bare" rev-parse main)"
