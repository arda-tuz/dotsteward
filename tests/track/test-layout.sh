# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# add and remove leave workstation.toml as a person would: a new table goes after the last
# [components] table, never between a comment and the header it is about; a new key goes at the end
# of its table; remove takes the table with the comment above it when that comment names the
# component, and keeps a comment that may be about more as a paragraph of its own; every other line
# stays as it was.
# shellcheck source=tests/track/helpers.sh
source "$DS_REPO_ROOT/tests/track/helpers.sh"

python3 - "$up_inst/workstation.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text += """
# Applications from vendor repositories, install only.
[components.example-chat]
enable = true

# example-lid: the lid never suspends the machine.
[components.example-lid]
enable = true

[components.example-last]
enable = true

# The updaters beyond apt (this comment is about the table below).
[[upgrade.tools]]
name = "example-tool"
check = "true"
update = "true"
"""
open(path, "w", encoding="utf-8").write(text)
PY
for name in example-chat example-lid example-last; do
  mkdir -p "$up_inst/components/$name"
  printf '{ ... }:\n{\n  dotsteward.components.%s = { };\n}\n' "$name" >"$up_inst/components/$name/default.nix"
done
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "feat: a layout with comments"
git -C "$up_inst" push -q origin HEAD:main

# A new table: after [components.example-last], before the comment of [[upgrade.tools]].
assert_exit 0 add example-viewer --machines example-host --publish
expected=$(git -C "$up_inst" show HEAD^:workstation.toml | python3 -c '
import sys
text = sys.stdin.read()
print(text.replace("[components.example-last]\nenable = true\n\n",
  "[components.example-last]\nenable = true\n\n[components.example-viewer]\nenable = true\nmachines = [\"example-host\"]\n\n"), end="")')
assert_eq "$expected" "$(git -C "$up_inst" show HEAD:workstation.toml)" "the new table is not where a person puts it"

# A new key: at the end of its table.
assert_exit 0 add example-lid --tags laptop --publish
assert_contains "$(git -C "$up_inst" show HEAD:workstation.toml)" \
  $'# example-lid: the lid never suspends the machine.\n[components.example-lid]\nenable = true\ntags = ["laptop"]\n\n[components.example-last]'

# Remove: a comment that names the component goes with it, one that may be about more stays.
assert_exit 0 remove example-lid --publish
text=$(git -C "$up_inst" show HEAD:workstation.toml)
assert_not_contains "$text" "example-lid"
assert_contains "$text" $'[components.example-chat]\nenable = true\n\n[components.example-last]'
assert_exit 0 remove example-chat --publish
text=$(git -C "$up_inst" show HEAD:workstation.toml)
assert_contains "$DS_STDOUT" "the comment above [components.example-chat] stays"
assert_contains "$text" $'# Applications from vendor repositories, install only.\n\n[components.example-last]'
assert_contains "$text" $'# The updaters beyond apt (this comment is about the table below).\n[[upgrade.tools]]'
