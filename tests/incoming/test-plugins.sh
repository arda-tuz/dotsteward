# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A plugin of a marketplace another machine added: a question, left out until the answer.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

machine_up laptop1
machine_up laptop2

add_plugin() {
  local clone
  clone=$(clone_of laptop1)
  cat >>"$clone/workstation.toml" <<TOML

[[components.claude-code.options.plugins]]
spec = "$1"
${2:-}
TOML
  git -C "$clone" add -A
  git -C "$clone" commit -q -m $'feat: a plugin\n\nDotsteward-Machine: laptop1'
  git -C "$clone" push -q origin main
}

add_plugin one@market
up_to_date laptop2
assert_exit 0 ds laptop2 incoming list --json
assert_json - '.items[0].id == "plugin:one@market" and .items[0].kind == "plugin" and .items[0].by == "laptop1"' <<<"$DS_STDOUT"
assert_eq '["one@market"]' "$(skipped laptop2 plugins)"
assert_exit 0 ds laptop2 skills effective --json
assert_eq incoming "$(jq -r '.reasons["plugin:one@market"]' <<<"$DS_STDOUT")"
assert_exit 0 ds laptop2 incoming show plugin:one@market
assert_contains "$DS_STDOUT" 'one@market'

# Ask later keeps it out, the answer lets it in.
assert_contains "$(ask_on_tty laptop2 l incoming)" 'plugin one@market (new) - machine laptop1'
assert_eq '["one@market"]' "$(skipped laptop2 plugins)"
assert_exit 0 ds laptop2 incoming answer plugin:one@market --install
assert_eq '[]' "$(skipped laptop2 plugins)"
assert_eq '' "$(waiting laptop2)"
assert_json "$(state_of laptop2)/machine/known.json" '.plugins | index("one@market") != null'

# Never: in the host file, and it holds.
up_to_date laptop1
add_plugin two@market
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer plugin:two@market --never
assert_contains "$(remote_file hosts/laptop2.toml)" 'two@market'
assert_eq '' "$(waiting laptop2)"
assert_exit 0 ds laptop2 skills effective --json
assert_eq declined "$(jq -r '.reasons["plugin:two@market"]' <<<"$DS_STDOUT")"
