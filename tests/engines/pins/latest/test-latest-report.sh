# shellcheck shell=bash
# `dotsteward pins latest` over a synthetic instance that declares every
# latest adapter, against loopback fakes (HTTP server, git remotes, gh and
# apt-cache stubs): the report schema and serializer, the status of every
# row, ordering, --all, the human summary, grouped compares, HEAD requests
# that stay HEAD across redirects, and that nothing but --out is written.
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world
url=$DS_HTTPFIX_URL

tree_listing() {
  (cd "$inst" && find . -print0 | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null || true)
}
before=$(tree_listing)

# --- --all: every row ---------------------------------------------------------

assert_exit 0 latest --all --out "$report"
assert_not_contains "$DS_STDERR" "Traceback"
assert_eq "" "$DS_STDERR" "stderr of a run without errors"

expected_all="update agent_tools.example-bin.linux-x64
update agent_tools.example-cli
update agent_tools.example-release
update desktop_packages.example-app
update desktop_packages.example-editor
update desktop_packages.example-viewer
update flake_inputs.example-lib
update nix.installer
update npm.@example/example-app
review agent_tools.example-plugin
review flake_inputs.example-term
review flake_inputs.nixpkgs
review framework
review skills.example-vendored
held nix_packages.example-manual
held npm_security_overrides.example-dep
manual skills.example-snapshot
current example_watch
current flake_inputs.home-manager
follows nix_packages.example-lint
follows nix_packages.example-shell
current npm_security_overrides.@example/example-app
current skills.example-bound
current skills.example-second
follows ubuntu_packages.example-app"
assert_eq "$expected_all" "$(statuses)" "statuses and order with --all"

# Report schema and the exact serializer.
assert_json "$report" 'keys_unsorted == ["schema_version", "researched_at", "items"]'
assert_json "$report" '.schema_version == "1.0"'
assert_json "$report" '.researched_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'
assert_json "$report" 'all(.items[]; keys_unsorted == ["id", "kind", "current", "latest", "status", "source", "details"])'
assert_json "$report" 'all(.items[]; (.details | type) == "object")'
python3 - "$report" <<'PY' || ds_fail "the report is not written with the lock serializer"
import json
import sys

text = open(sys.argv[1], encoding="utf-8").read()
assert text == json.dumps(json.loads(text), indent=2, ensure_ascii=False) + "\n"
PY
assert_file_mode "$report" 644

# Human output: the summary, then one line per row (--all lists every row).
researched=$(jq -r .researched_at "$report")
first_line=${DS_STDOUT%%$'\n'*}
assert_eq "[pins] Researched at $researched: 25 items, 17 need attention" "$first_line"
assert_eq 26 "$(wc -l <<<"$DS_STDOUT")" "summary plus one line per row"
assert_contains "$DS_STDOUT" \
  $'\n'"$(printf '%-8s %-44s %30s -> %s' update agent_tools.example-bin.linux-x64 1.0.0 1.0.2)"
assert_contains "$DS_STDOUT" $'\nfollows  ubuntu_packages.example-app'
assert_contains "$DS_STDOUT" "36.x needs a newer host library"
assert_contains "$DS_STDOUT" "plugins/example-web/index.md"
while IFS= read -r line; do
  ((${#line} <= 220)) || ds_fail "row line longer than 220 characters: $line"
done <<<"$DS_STDOUT"

# --- rows, adapter by adapter -------------------------------------------------

# github-release with the repository declared and an asset template; the
# declared row replaces the built-in flake input row of the same id.
assert_eq 1 "$(jq '[.items[] | select(.id == "flake_inputs.example-term")] | length' "$report")"
assert_eq '{"id":"flake_inputs.example-term","kind":"github-release","current":"0.8.0","latest":"0.9.0","status":"review","source":"https://github.com/example-org/example-term/releases","details":{"tag":"v0.9.0","asset":"example-term_0.9.0_amd64.deb","size":194,"sha256":"950f43fd2ac691e81cbe68303e3aa30904a4b55a82eac7dcc01687dbd351ff46","url":"https://github.com/example-org/example-term/releases/download/v0.9.0/example-term_0.9.0_amd64.deb"}}' \
  "$(row flake_inputs.example-term)"
# A tag prefix and a literal asset name; the current version is the pin's
# minimum_version.
assert_eq '{"id":"agent_tools.example-release","kind":"github-release","current":"1.3.0","latest":"1.4.0","status":"update","source":"https://github.com/example-org/example-cli/releases","details":{"tag":"cli-v1.4.0","asset":"example-cli-linux-x64.tar.gz","size":8192,"sha256":"3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d","url":"https://github.com/example-org/example-cli/releases/download/cli-v1.4.0/example-cli-linux-x64.tar.gz"}}' \
  "$(row agent_tools.example-release)"
# Built-in flake input row: the repository comes from the pin's reference;
# without a GitHub release the newest stable tag answers (v3.0.0-beta.1 and
# nightly are not stable).
assert_eq '{"id":"flake_inputs.example-lib","kind":"github-release","current":"2.0.0","latest":"2.1.0","status":"update","source":"https://github.com/example-org/example-lib/releases","details":{"tag":"v2.1.0"}}' \
  "$(row flake_inputs.example-lib)"
# A flake input with neither a channel nor a version has no row.
assert_eq "" "$(row flake_inputs.example-src)"

# npm: package name from another lock field, from the for_each key, and a
# holdback.
assert_eq "{\"id\":\"agent_tools.example-cli\",\"kind\":\"npm\",\"current\":\"1.1.0\",\"latest\":\"1.2.3\",\"status\":\"update\",\"source\":\"$url/npm/@example/example-app\",\"details\":{\"integrity\":\"sha512-UXdR2pq5/a9k4BKS7ZdgEF4hCSEpWBhCl2PIm/7hIHsdPWSMXMi9ndlvlfCqmYFWmxv8l1377nVJhTT3M364HQ==\",\"git_head\":\"11f6ad8ec52a2984abaafd7c3b516503785c2072\",\"node_engine\":\">=20\"}}" \
  "$(row agent_tools.example-cli)"
assert_eq '["npm","1.1.0","1.2.3","update"]' "$(row npm.@example/example-app '[.kind, .current, .latest, .status]')"
assert_eq '["1.2.3","1.2.3","current"]' "$(row npm_security_overrides.@example/example-app '[.current, .latest, .status]')"
assert_eq '["1.0.0","2.0.0","held","2.x drops the API the bundle uses"]' \
  "$(row npm_security_overrides.example-dep '[.current, .latest, .status, .details.note]')"

# official-manifest: a text version endpoint plus a JSON manifest with
# dotted field paths, and a manifest whose download URL is sized by a HEAD
# request.
assert_eq "{\"id\":\"agent_tools.example-bin.linux-x64\",\"kind\":\"official-manifest\",\"current\":\"1.0.0\",\"latest\":\"1.0.2\",\"status\":\"update\",\"source\":\"$url/bin/stable\",\"details\":{\"url\":\"$url/bin/1.0.2/linux-x64/example-bin\",\"size\":4096,\"sha256\":\"cd0aa9856147b6c5b4ff2b7dfee5da20aa38253099ef1b4a64aced233c9afe29\"}}" \
  "$(row agent_tools.example-bin.linux-x64)"
editor_size=$(stat -c %s "$www/editor/download/example-editor_1.105.1_amd64.deb")
assert_eq "{\"id\":\"desktop_packages.example-editor\",\"kind\":\"official-manifest\",\"current\":\"1.100.0\",\"latest\":\"1.105.1\",\"status\":\"update\",\"source\":\"https://example.invalid/editor/updates\",\"details\":{\"url\":\"$url/editor/1.105.1/linux-deb-x64/stable\",\"size\":$editor_size,\"sha256\":\"aaa9402664f1a41f40ebbc52c9993eb66aeb366602958fdfaa283b71e64db123\"}}" \
  "$(row desktop_packages.example-editor)"

# apt-index: the newest stable version of the package (1.3.0~rc1 is a
# pre-release), with its pool URL, size and digest.
assert_eq "{\"id\":\"desktop_packages.example-app\",\"kind\":\"apt-index\",\"current\":\"1.1.0\",\"latest\":\"1.2.3\",\"status\":\"update\",\"source\":\"$url/apt\",\"details\":{\"url\":\"$url/apt/pool/main/e/example-app/example-app_1.2.3_amd64.deb\",\"size\":193,\"sha256\":\"1c509468908c576b9d7f830e06e33b904fb8078f729a291c16aeec9f6aecaa3d\"}}" \
  "$(row desktop_packages.example-app)"

# deb-url: the version comes from the file name the latest URL redirects
# to; size and Last-Modified from a HEAD request.
viewer_size=$(stat -c %s "$www/viewer/pool/example-viewer_2.1.0_amd64.deb")
assert_eq "{\"id\":\"desktop_packages.example-viewer\",\"kind\":\"deb-url\",\"current\":\"2.0.0\",\"latest\":\"2.1.0\",\"status\":\"update\",\"source\":\"$url/viewer/latest/linux-deb\",\"details\":{\"file\":\"example-viewer_2.1.0_amd64.deb\",\"url\":\"$url/viewer/pool/example-viewer_2.1.0_amd64.deb\",\"size\":$viewer_size,\"last_modified\":\"Tue, 01 Sep 2026 12:00:00 GMT\"}}" \
  "$(row desktop_packages.example-viewer)"

# nix-release (built in from the lock's nix section): newest stable tag of
# the Nix repository, the installer URL of that version, its published
# checksum and size.
installer_size=$(stat -c %s "$www/nix/nix-2.31.1/install")
installer_sha256=$(<"$www/nix/nix-2.31.1/install.sha256")
assert_eq "{\"id\":\"nix.installer\",\"kind\":\"nix-release\",\"current\":\"2.30.0\",\"latest\":\"2.31.1\",\"status\":\"update\",\"source\":\"$url/nix/\",\"details\":{\"url\":\"$url/nix/nix-2.31.1/install\",\"size\":$installer_size,\"sha256\":\"$installer_sha256\"}}" \
  "$(row nix.installer)"

# channel-head (built in for flake inputs with a channel).
pinned=$(rev example-org/nixpkgs nixos-25.11~1)
head=$(rev example-org/nixpkgs nixos-25.11)
assert_eq "{\"id\":\"flake_inputs.nixpkgs\",\"kind\":\"channel-head\",\"current\":\"${pinned:0:12}\",\"latest\":\"${head:0:12}\",\"status\":\"review\",\"source\":\"https://github.com/example-org/nixpkgs\",\"details\":{\"channel\":\"nixos-25.11\",\"head\":\"$head\",\"newest_series\":\"nixos-26.05\"}}" \
  "$(row flake_inputs.nixpkgs)"
hm=$(rev example-org/home-manager release-25.11)
assert_eq "[\"${hm:0:12}\",\"${hm:0:12}\",\"current\",\"release-25.11\"]" \
  "$(row flake_inputs.home-manager '[.current, .latest, .status, .details.newest_series]')"

# git-compare: watched paths decide between review and current.
base=$(rev example-org/example-plugins main~1)
tip=$(rev example-org/example-plugins main)
assert_eq "{\"id\":\"agent_tools.example-plugin\",\"kind\":\"git-compare\",\"current\":\"${base:0:12}\",\"latest\":\"${tip:0:12}\",\"status\":\"review\",\"source\":\"https://github.com/example-org/example-plugins\",\"details\":{\"head\":\"$tip\",\"release\":null,\"ahead_by\":1,\"changed_paths\":[\"plugins/example-web/index.md\"],\"files_truncated\":false}}" \
  "$(row agent_tools.example-plugin)"
assert_eq '["git-compare","current",[]]' "$(row example_watch '[.kind, .status, .details.changed_paths]')"

# skill-source (built in from the skills lock): one compare for the two
# skills of the same repository and revision; only vendored files and the
# skill structure count. The repo-owned skill has no row, a non-hex
# revision is manual, a release-bound skill compares with the release tag.
assert_eq '["skill-source","review",["skills/example-vendored/references/notes.md"]]' \
  "$(row skills.example-vendored '[.kind, .status, .details.changed_paths]')"
assert_eq '["skill-source","current",[]]' "$(row skills.example-second '[.kind, .status, .details.changed_paths]')"
assert_eq "" "$(row skills.example-local)"
assert_eq '{"id":"skills.example-snapshot","kind":"manual","current":"local-snapshot","latest":null,"status":"manual","source":"https://github.com/example-org/example-snapshot","details":{"note":"local snapshot; compare with the upstream source manually"}}' \
  "$(row skills.example-snapshot)"
tool=$(rev example-org/example-tool v1.0.0)
assert_eq "[\"skill-source\",\"current\",\"${tool:0:12}\",\"v1.0.0\",0]" \
  "$(row skills.example-bound '[.kind, .status, .latest, .details.release, .details.ahead_by]')"
skills_base=$(rev example-org/example-skills main~1)
skills_tip=$(rev example-org/example-skills main)
assert_call_count 1 gh "api repos/example-org/example-skills/compare/*"
assert_call_count 1 gh "api repos/example-org/example-skills/compare/$skills_base...$skills_tip"
assert_call_count 0 gh "api repos/example-org/example-tool/compare/*"

# framework (built in): the tag of the dotsteward input against the newest
# release of its upstream.
assert_eq '{"id":"framework","kind":"framework","current":"v0.1.0","latest":"v0.2.0","status":"review","source":"https://github.com/example/dotsteward/releases","details":{"tag":"v0.2.0","upstream":"github:example/dotsteward"}}' \
  "$(row framework)"

# manual, follows and local-apt.
assert_eq '{"id":"nix_packages.example-manual","kind":"manual","current":"35.0.0","latest":"36.0.0","status":"held","source":"https://example.invalid/example-manual/","details":{"note":"36.x needs a newer host library"}}' \
  "$(row nix_packages.example-manual)"
assert_eq '{"id":"nix_packages.example-lint","kind":"follows-example-watch","current":"0.11.0","latest":null,"status":"follows","source":"example-watch","details":{"note":"pinned by the example-watch lint requirements"}}' \
  "$(row nix_packages.example-lint)"
assert_eq '{"id":"nix_packages.example-shell","kind":"follows-nixpkgs","current":"5.9","latest":null,"status":"follows","source":"nixpkgs","details":{"note":"run '"'"'dotsteward sync --nix'"'"' after a nixpkgs update"}}' \
  "$(row nix_packages.example-shell)"
assert_eq '{"id":"ubuntu_packages.example-app","kind":"local-apt","current":"1.0.0","latest":"1.2.3","status":"follows","source":"apt-cache policy","details":{}}' \
  "$(row ubuntu_packages.example-app)"
assert_eq "" "$(row ubuntu_packages.example-plain)"

# HEAD requests stay HEAD across redirects; nothing is downloaded whole.
requests=$(<"$DS_HTTPFIX_LOG")$'\n'
assert_contains "$requests" "HEAD /viewer/latest/linux-deb"$'\n'
assert_contains "$requests" "HEAD /viewer/pool/example-viewer_2.1.0_amd64.deb"$'\n'
assert_not_contains "$requests" "GET /viewer/"
assert_contains "$requests" "HEAD /editor/download/example-editor_1.105.1_amd64.deb"$'\n'
assert_not_contains "$requests" "GET /editor/download/"
assert_contains "$requests" "GET /nix/nix-2.31.1/install.sha256"$'\n'
assert_contains "$requests" "HEAD /nix/nix-2.31.1/install"$'\n'
assert_not_contains "$requests" "GET /nix/nix-2.31.1/install"$'\n'

# Nothing in the instance changed.
assert_eq "$before" "$(tree_listing)" "latest changed the instance"

# --- default: rows that follow other pins are left out --------------------------

all_report=$DS_TEST_ROOT/all.json
mv -- "$report" "$all_report"
assert_exit 0 latest
assert_eq "" "$DS_STDERR"
[[ ! -e $report ]] || ds_fail "a report was written without --out"
first_line=${DS_STDOUT%%$'\n'*}
[[ $first_line =~ ^\[pins\]\ Researched\ at\ [0-9T:Z-]+:\ 22\ items,\ 17\ need\ attention$ ]] ||
  ds_fail "unexpected summary: $first_line"
# Only rows that need attention are listed.
assert_eq 18 "$(wc -l <<<"$DS_STDOUT")" "summary plus the attention rows"
assert_not_contains "$DS_STDOUT" "flake_inputs.home-manager"
assert_contains "$DS_STDOUT" $'\nmanual   skills.example-snapshot'

assert_exit 0 latest --out "$report" --jobs 1
assert_eq "$(grep -v -e '^follows ' <<<"$expected_all")" "$(statuses)" "statuses without --all, one job"
assert_json "$report" '[.items[] | select(.status == "follows")] | length == 0'
assert_eq "$before" "$(tree_listing)" "latest changed the instance"
