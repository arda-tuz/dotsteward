# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# A section comment that a blank line keeps apart from its header belongs to that header: add puts
# a new table before it, remove of the table above it keeps it. A change of a comment elsewhere in
# workstation.toml is not add's: a question. A file with CRLF line endings keeps them: add writes
# the lines of the table and nothing else.
# shellcheck source=tests/track/helpers.sh
source "$DS_REPO_ROOT/tests/track/helpers.sh"

section=$'# -------------------------------------------------------------\n# Section: how this machine maintains itself.\n# -------------------------------------------------------------\n\n[maintain]\nactivate = false\n'
python3 - "$up_inst/workstation.toml" "$section" <<'PY'
import sys
path, section = sys.argv[1:]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.rstrip("\n") + "\n\n" + section)
PY
git -C "$up_inst" commit -q -am "docs: a section comment"
git -C "$up_inst" push -q origin HEAD:main

# add: the new table goes after the last components table, before the section comment.
assert_exit 0 add example-viewer --publish
text=$(git -C "$up_inst" show HEAD:workstation.toml)
assert_contains "$text" $'method = "official-binary"\n\n[components.example-viewer]\nenable = true\n\n# ----'
assert_contains "$text" "$section"
assert_eq "3 0" "$(git -C "$up_inst" diff --numstat HEAD^ HEAD -- workstation.toml | awk '{print $1, $2}')" \
  "add changed more than its table"

# remove of the table above the section keeps the section comment with its header.
assert_exit 0 remove example-viewer --publish
assert_exit 0 remove codex --publish
text=$(git -C "$up_inst" show HEAD:workstation.toml)
assert_contains "$text" "$section"
assert_not_contains "$text" "components.codex"
assert_not_contains "$DS_STDOUT" "stays, it may be about more"

# Another comment changed in the file: not add's change, a question; nothing written.
python3 - "$up_inst/workstation.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace("[components.example-app]\n", "# TODO(person): look at this\n[components.example-app]\n", 1))
PY
head=$(head_oid)
assert_exit 3 add example-viewer --publish --json
assert_stdout_json '[.ask[].code] == ["checkout-dirty"]'
assert_eq "$head" "$(head_oid)" "no commit"
git -C "$up_inst" checkout -q -- workstation.toml

# CRLF: the line endings of the file stay, add changes only its own lines.
sed -i 's/$/\r/' "$up_inst/workstation.toml"
git -C "$up_inst" commit -q -am "chore: CRLF line endings"
git -C "$up_inst" push -q origin HEAD:main
assert_exit 0 add example-viewer --publish
assert_eq "0" "$(git -C "$up_inst" show HEAD:workstation.toml | grep -vc $'\r$' || true)" "a line lost its CR"
assert_eq "3 0" "$(git -C "$up_inst" diff --numstat HEAD^ HEAD -- workstation.toml | awk '{print $1, $2}')" \
  "add rewrote the CRLF file"
assert_exit 0 remove example-viewer --publish
assert_eq "0" "$(git -C "$up_inst" show HEAD:workstation.toml | grep -vc $'\r$' || true)" "remove lost a CR"
