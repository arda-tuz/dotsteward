# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# The two kinds of hold have names of their own: `pin:<id>` is what upgrade holds when a move went
# red, `component:<name>` what the owner holds. A pin id that is also the name of a component stays a
# pin hold, and --retry-held takes it back as it says. A component hold for a component the instance
# does not have holds nothing and says so, and --retry-held leaves it, since it is the owner's. The
# hold of a pin the research no longer has is over. A comment the owner wrote in the holds of the
# host file stays when upgrade adds or takes away a hold.
# shellcheck source=tests/upgrade/holds-helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/holds-helpers.sh"

# --- a pin id that is a component name: a pin hold all the same --------------------------------------
move codex 2.0.0 download
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked
remote_holds example-host | assert_json - 'keys == ["pin:codex"] and .["pin:codex"].version == "2.0.0"'
review_json '[.items[] | select(.code == "red-held" and .id == "codex")] | length == 1'

# The owner adds a hold of a component the instance does not have, with comments of their own.
git -C "$up_inst" pull -q --ff-only origin main
cat >>"$up_inst/hosts/example-host.toml" <<'TOML'

# the owner's own words about the hold below
[holds."component:example-gone"]
version = "3.0"   # the plugin API breaks here
reason = "waits for the plugins"
TOML
git -C "$up_inst" commit -q -am "chore(hosts): the owner holds example-gone"
git -C "$up_inst" push -q origin HEAD:main

clear_log
printf '{"items": [{"id": "codex", "latest": "2.0.0", "status": "update"}]}\n' >"$UP_CONTROL/latest-rows"
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^pins .*apply')" "--skip codex"
review_json '[.items[] | select(.code == "held" and .id == "codex" and .kind == "pin" and .run == "dotsteward upgrade --retry-held")] | length == 1'
review_json '[.items[] | select(.code == "hold-unknown" and .id == "example-gone")] | length == 1'

# --retry-held takes back the pin hold, the pin moves; the owner's hold and its comments stay.
clear_log
assert_exit 3 upgrade --tracked --retry-held
assert_not_contains "$(steps '^pins .*apply')" "--skip codex"
assert_eq 2.0.0 "$(git -C "$up_bare" show main:versions.lock.json | jq -r '.codex')"
remote_holds example-host | assert_json - 'keys == ["component:example-gone"]'
host_file=$(git -C "$up_bare" show main:hosts/example-host.toml)
assert_contains "$host_file" "# the owner's own words about the hold below"
assert_contains "$host_file" "# the plugin API breaks here"

# --- the hold of a pin the research no longer has is over --------------------------------------------
clear_log
rm -f -- "$UP_CONTROL/moves"
move example.gone 1.0 pypi
printf 'example:gone\n' >"$UP_CONTROL/e2e-red-once"
printf '{"items": [{"id": "example.gone", "latest": "1.0", "status": "update"}]}\n' >"$UP_CONTROL/latest-rows"
assert_exit 3 upgrade --tracked
remote_holds example-host | assert_json - 'has("pin:example.gone")'
clear_log
rm -f -- "$UP_CONTROL/moves"
printf '{"items": []}\n' >"$UP_CONTROL/latest-rows"
assert_exit 3 upgrade --tracked
remote_holds example-host | assert_json - 'has("pin:example.gone") | not'
remote_holds example-host | assert_json - 'has("component:example-gone")'
