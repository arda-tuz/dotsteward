# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# `dotsteward add NAME` turns "track NAME" into one maintain transaction for a catalog component:
# it opens the transaction with maintain begin, writes [components.NAME] with enable = true into
# workstation.toml and finishes with the one dotsteward apply, whose steps, options and exit status
# it keeps: the gate before the commit, the commit with the subject "feat: track NAME" and the
# trace line, the rebuild and E2E of the committed tree, the push. A second add has nothing left to
# do; the scope options write machines, tags, profiles and the method, and --json prints one
# document with the report of apply in it.
# shellcheck source=tests/track/helpers.sh
source "$DS_REPO_ROOT/tests/track/helpers.sh"

base=$(remote_oid)
clear_log
assert_exit 0 add example-viewer --activate --publish
assert_contains "$DS_STDOUT" "published"
assert_order "^generate  root=$up_inst\$" '^static ' "^rebuild --profile workstation --switch root=$up_inst\$" \
  "^e2e --profile workstation .*--expected-remote-base $base( |.*)root=$up_inst\$"
head=$(head_oid)
assert_eq "$head" "$(remote_oid)" "the commit is published"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)" "one commit on the base"
assert_eq "feat: track example-viewer" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "example-host" "$(machine_trailer HEAD)" "the trace line names this machine"
assert_eq "workstation.toml" "$(git -C "$up_inst" diff --name-only HEAD^ HEAD -- . ':!.dotsteward')" \
  "the commit changes the intent only"
toml_at HEAD '.components["example-viewer"] == {enable: true}'
toml_at HEAD '.components["example-app"].enable == true and .components["example-app"].track == ["example-tracked-too"]'
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "the checkout is clean"
apply_report '.command == "apply" and .status == "ok" and .data.published == true'
# The comments and the layout of the file stay as they were.
assert_eq "$(git -C "$up_inst" show HEAD^:workstation.toml)" \
  "$(git -C "$up_inst" show HEAD:workstation.toml | head -n "$(git -C "$up_inst" show HEAD^:workstation.toml | wc -l)")" \
  "the table is added after the text of the file, which stays as it was"

# Again: the component is tracked already, nothing is opened, gated or committed.
clear_log
assert_exit 0 add example-viewer --activate --publish
assert_contains "$DS_STDOUT" "example-viewer is tracked already"
assert_no_step '^static '
assert_no_step '^rebuild '
assert_eq "$head" "$(head_oid)" "no second commit"

# The scope of a machine, tags, profiles and a method; --json prints one document on standard output.
clear_log
assert_exit 0 add example-viewer --here --tags gpu,laptop --profiles workstation --method nix \
  -m "feat: example-viewer on this machine only" --no-activate --publish --json
assert_stdout_json '.command == "add" and .component == "example-viewer" and .change == "changed"'
assert_stdout_json '.apply.command == "apply" and .apply.status == "ok" and .apply.data.published == true'
assert_stdout_json '.exit_code == 0'
assert_no_step '^rebuild '
toml_at HEAD '.components["example-viewer"] == {enable: true, machines: ["example-host"], tags: ["gpu", "laptop"],
  profiles: ["workstation"], method: "nix"}'
assert_eq "feat: example-viewer on this machine only" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "$(head_oid)" "$(remote_oid)" "published"

# A component that the file disables comes back with enable = true, its other keys kept.
python3 - "$up_inst/workstation.toml" <<'EOF'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace('[components.codex]\nenable = true', '[components.codex]\nenable = false'))
EOF
git -C "$up_inst" commit -q -am "feat: codex off"
git -C "$up_inst" push -q origin HEAD:main
assert_exit 0 add codex --publish
toml_at HEAD '.components.codex == {enable: true, method: "official-binary"}'
assert_eq "feat: track codex" "$(git -C "$up_inst" log -1 --format=%s)"

# Usage errors write nothing: a value the schema refuses, a name that is no component name, a
# subject that is no conventional commit.
head=$(head_oid)
assert_exit 2 add example-viewer --method carrier-pigeon
assert_contains "$DS_STDERR" "method"
assert_exit 2 add 'Not A Name'
assert_exit 2 add example-viewer --here --machines example-host
assert_exit 2 add example-viewer -m "track it"
assert_eq "$head" "$(head_oid)" "no commit"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "nothing written"
