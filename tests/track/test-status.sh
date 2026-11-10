# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# `dotsteward status` is one read-only overview of this machine, offline and fast: the machine
# (name, platform, profile, framework), the checkout against what the last fetch knows of the
# remote, whether the active generation is the checkout and its E2E, every tracked component with
# its method, updater, constraint and holds, whether it is here and installed or why not, what other
# machines brought that waits for an answer, the skills and plugins, the last record of the state
# branch and the components of that record the intent no longer has (orphans), and what
# review.json holds. It writes nothing, reaches no network, starts no command of the framework,
# and answers on a machine without a name too.
# shellcheck source=tests/track/helpers.sh
source "$DS_REPO_ROOT/tests/track/helpers.sh"

ds_use_stubs dpkg-query
os_release=$DS_TEST_ROOT/os-release
printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' >"$os_release"
export DOTSTEWARD_OS_RELEASE=$os_release
ds_dpkg_installed example-tracked 1.0-1
ds_dpkg_installed example-tracked-too 1.1-1

# The intent: a constrained deb component, one for another machine, one for a tag this machine
# lacks.
python3 - "$up_inst/workstation.toml" <<'EOF'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace('track = ["example-tracked-too"]', 'track = ["example-tracked-too"]\nversion = "1.*"\nreason = "the plugins need 1.x"')
open(path, "w", encoding="utf-8").write(text)
EOF
printf '\n[components.example-viewer]\nenable = true\nmachines = ["other-host"]\n' >>"$up_inst/workstation.toml"
printf '\n[components.example-gpu]\nenable = true\ntags = ["gpu"]\n' >>"$up_inst/workstation.toml"
mkdir -p "$up_inst/components/example-gpu"
printf '{ ... }:\n{\n  dotsteward.components.example-gpu = { };\n}\n' >"$up_inst/components/example-gpu/default.nix"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "feat: scoped components"
git -C "$up_inst" push -q origin HEAD:main

# A record on the state branch of this machine, then a component goes from the intent.
assert_exit 0 "$fw/cli/dotsteward" --instance "$up_inst" state record --no-push
git -C "$up_inst" rev-parse --verify --quiet refs/heads/state/example-host >/dev/null ||
  ds_fail "no record on the state branch"
python3 - "$up_inst/workstation.toml" <<'EOF'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r'\[components\.claude-code\]\nenable = true\nmethod = "official-binary"\n', '', text)
open(path, "w", encoding="utf-8").write(text)
EOF
git -C "$up_inst" commit -q -am "feat: stop tracking claude-code"
git -C "$up_inst" push -q origin HEAD:main

# A hold of this machine, an active generation that is the checkout with a passed E2E, a change in
# the checkout, a commit of another machine that the last fetch saw and the checkout lacks.
jq -n '{schema_version: 1, holds: [{component: "codex", id: "agent_tools.codex.linux", version: "9.9.9",
  reason: "e2e-red", since: "2026-11-01T00:00:00Z"}]}' >"$DOTSTEWARD_STATE_ROOT/holds.json"
generation=/nix/store/00000000000000000000000000000000-home-manager-generation
mkdir -p "$DOTSTEWARD_STATE_ROOT/current" "$DOTSTEWARD_STATE_ROOT/update"
jq -n --arg tree "$(head_tree)" --arg root "$up_inst" --arg generation "$generation" \
  '{tree_oid: $tree, profile: "workstation", root: $root, generation: $generation}' \
  >"$DOTSTEWARD_STATE_ROOT/current/activation.json"
jq -n --arg generation "$generation" '{result: "passed", generation: $generation,
  recorded_at: "2026-11-02T00:00:00Z"}' >"$DOTSTEWARD_STATE_ROOT/update/e2e.json"
push_from_elsewhere "docs: a change of another machine"
git -C "$up_inst" fetch -q origin
edit "a change here"

before=$(snapshot)
touch "$UP_CONTROL/network-down"
clear_log
reset_logs
started=$(date +%s%N)
assert_exit 0 status --json
elapsed_ms=$((($(date +%s%N) - started) / 1000000))
rm -f -- "$UP_CONTROL/network-down"
assert_eq "$before" "$(snapshot)" "status changed the checkout, a ref or the state root"
assert_eq "" "$(<"$UP_LOG")" "status started a command"
assert_no_network
((elapsed_ms < 5000)) || ds_fail "status took ${elapsed_ms} ms"

assert_stdout_json '.command == "status" and .schema_version == 1'
assert_stdout_json '.machine.name == "example-host" and .machine.profile == "workstation"'
assert_stdout_json '.machine.platform == "ubuntu-24.04" and (.machine.framework_version | type) == "string"'
assert_stdout_json ".checkout.branch == \"main\" and .checkout.head == \"$(head_oid)\""
assert_stdout_json '.checkout.ahead == 0 and .checkout.behind == 1 and .checkout.changes == [" M docs/guide.md"]'
assert_stdout_json '.activation.active == true and .activation.e2e == "pass"'
assert_stdout_json '[.components[].name] == ["codex", "example-app", "example-gpu", "example-viewer"]'
assert_stdout_json '.components[] | select(.name == "example-app") | .method == "deb" and .here == true
  and .installed == "installed" and .packages == {"example-tracked": "1.0-1", "example-tracked-too": "1.1-1"}
  and .constraint == {version: "1.*", reason: "the plugins need 1.x"}'
assert_stdout_json '.components[] | select(.name == "example-viewer") | .here == false and .reason == "machines"'
assert_stdout_json '.components[] | select(.name == "example-gpu") | .here == false and .reason == "tags"'
assert_stdout_json '.components[] | select(.name == "codex") | .method == "official-binary"
  and .held == [{id: "agent_tools.codex.linux", version: "9.9.9", reason: "e2e-red", since: "2026-11-01T00:00:00Z"}]'
assert_stdout_json '.holds | length == 1'
assert_stdout_json '.orphans == ["claude-code"]'
assert_stdout_json '.state.recorded_at != null and .state.waiting == true'
assert_stdout_json '(.skills | type) == "object" and (.plugins | type) == "array" and (.incoming | type) == "array"'

# The same overview as text.
assert_exit 0 status
for word in example-host ubuntu-24.04 workstation "1 behind" example-app installed "machines" codex 9.9.9 \
  claude-code "orphan"; do
  assert_contains "$DS_STDOUT" "$word"
done

# What another machine brought waits for an answer here.
jq -n '{schema_version: 1, components: ["codex", "example-app"], plugins: []}' \
  >"$DOTSTEWARD_STATE_ROOT/machine/known.json.new"
mv -- "$DOTSTEWARD_STATE_ROOT/machine/known.json.new" "$DOTSTEWARD_STATE_ROOT/machine/known.json"
git -C "$up_inst" checkout -q -- docs/guide.md
git -C "$up_inst" merge -q --ff-only origin/main
other=$DS_TEST_ROOT/other-clone
git clone -q "$up_bare" "$other"
printf '\n[components.example-viewer2]\nenable = true\n' >>"$other/workstation.toml"
mkdir -p "$other/components/example-viewer2"
printf '{ ... }:\n{\n  dotsteward.components.example-viewer2 = { };\n}\n' >"$other/components/example-viewer2/default.nix"
git -C "$other" add -A
git -C "$other" -c user.name=other -c user.email=other@example.invalid commit -q \
  -m "feat: track example-viewer2" -m "Dotsteward-Machine: other-host"
git -C "$other" push -q origin HEAD:main
git -C "$up_inst" pull -q --ff-only origin main
assert_exit 0 status --json
assert_stdout_json '[.incoming[] | .id] == ["component:example-viewer2"]'
assert_stdout_json '.incoming[0].by == "other-host"'
assert_stdout_json '.activation.active == false and .checkout.behind == 0'
assert_stdout_json '.components[] | select(.name == "example-viewer2") | .here == false and .reason == "incoming"'

# A machine without a name: still an overview.
rm -f -- "$DOTSTEWARD_STATE_ROOT/machine.json"
assert_exit 0 status --json
assert_stdout_json '.machine.name == null and .state == null and .orphans == []'
assert_stdout_json '[.components[].name] | index("example-app") != null'
