# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A downloaded skill is often a link from a skill root into a clone kept elsewhere, the
# skill one directory of it. The link is followed: a clean clone with a remote is where the
# skill comes from, and --all pins that remote, the directory and the commit, as for a
# record of `npx skills`. The clone moves by itself later: agents install never writes
# through the link and agents check stays green. A clone with changes or without a remote
# says why it is unknown, here and in the refusal of --all, and a clone of its own stays a
# question even after a file tool wrote into it. An answer about a skill that was seen as
# unknown before looks again, also after --never. The license of the clone, at its top as
# most repositories keep it, goes with the pin; credentials in the remote never do.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
new_machine b
install=(agents install --profile workstation --skip-validation)
agents_skills=$(home_of a)/.agents/skills
sources=$(home_of a)/.local/share/skill-sources
public=https://github.com/example-org/figures
mkdir -p "$sources"

# The upstream: a repository with two skills, each a directory of it, and one license at
# its top.
upstream=$world/figures.git
upstream_work=$world/figures
git init -q -b main "$upstream_work"
for skill in figure-making chart-making; do
  mkdir -p "$upstream_work/$skill/references"
  printf -- '---\nname: %s\ndescription: Synthetic skill.\n---\n\nversion one\n' "$skill" >"$upstream_work/$skill/SKILL.md"
  printf '# Guide\n' >"$upstream_work/$skill/references/guide.md"
done
printf '# Figures\n' >"$upstream_work/README.md"
printf 'Synthetic license, version 1\n' >"$upstream_work/LICENSE"
git -C "$upstream_work" add -A
git -C "$upstream_work" commit -q -m "chore: two skills"
git clone -q --bare "$upstream_work" "$upstream"
# The clone names the public remote; the bare repository stands in for it.
redirect=("-c" "url.file://$upstream.insteadOf=$public")
git "${redirect[@]}" clone -q "$public" "$sources/figures"
assert_eq "$public" "$(git -C "$sources/figures" config --get remote.origin.url)"
clone=$sources/figures
ln -s "$clone/figure-making" "$agents_skills/figure-making"

# --- the link is followed to the clone -------------------------------------------------------

assert_exit 0 ds a skills reconcile
assert_eq ask "$(item a figure-making .state)"
assert_eq downloaded "$(item a figure-making .origin)"
assert_eq "$public" "$(item a figure-making .source.url)"
assert_eq figure-making "$(item a figure-making .source.path)"
assert_eq "$(git -C "$clone" rev-parse HEAD)" "$(item a figure-making .source.revision)"

ds_code a skills track figure-making --all
entry=$(remote_entry figure-making)
assert_eq "$public" "$(jq -r .source <<<"$entry")"
assert_eq "$(git -C "$clone" rev-parse HEAD)" "$(jq -r .revision <<<"$entry")"
assert_eq figure-making "$(jq -r .source_path <<<"$entry")"
assert_eq null "$(jq -r '.machines // null' <<<"$entry")"
assert_contains "$(remote_file agent/skills/figure-making/SKILL.md)" "version one"
# The vendored copy is the directory of the upstream as it is; its license lies beside it.
if git -C "$remote" cat-file -e refs/heads/main:agent/skills/figure-making/LICENSE 2>/dev/null; then
  ds_fail "the copy stays the tree of the upstream"
fi
assert_eq "Synthetic license, version 1" "$(remote_file agent/skill-licenses/figure-making/LICENSE)"
assert_eq "{}" "$(item a figure-making .)"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a static --only skills

# --- the clone moves by itself; nothing writes through the link, nothing turns red ------------

assert_exit 0 ds a "${install[@]}"
assert_exit 0 ds a agents check --profile workstation
[[ -L $agents_skills/figure-making ]] || ds_fail "the link stays a link"
assert_eq "" "$(git -C "$clone" status --porcelain)"
printf -- '---\nname: figure-making\ndescription: Synthetic skill.\n---\n\nversion two\n' \
  >"$upstream_work/figure-making/SKILL.md"
git -C "$upstream_work" commit -q -am "chore: version two"
git -C "$upstream_work" push -q "$upstream" main
git -C "$clone" "${redirect[@]}" pull -q --ff-only
assert_exit 0 ds a "${install[@]}"
assert_exit 0 ds a agents check --profile workstation
assert_contains "$DS_STDERR" "skill figure-making follows its clone, ahead of the pinned"
assert_contains "$(cat "$clone/figure-making/SKILL.md")" "version two"
assert_eq "" "$(git -C "$clone" status --porcelain)"
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(item a figure-making .)"
# The other machine gets the pinned copy.
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b "${install[@]}"
assert_contains "$(cat "$(home_of b)/.agents/skills/figure-making/SKILL.md")" "version one"

# --- a clone with changes, and one without a remote, say why they are unknown ------------------

printf 'a local note\n' >"$clone/chart-making/NOTES.md"
ln -s "$clone/chart-making" "$agents_skills/chart-making"
assert_exit 0 ds a skills reconcile
assert_eq unknown "$(item a chart-making .origin)"
assert_contains "$(item a chart-making .origin_detail)" "uncommitted"
assert_exit 0 ds a skills status
assert_contains "$DS_STDOUT" "uncommitted"
tip=$(remote_tip)
EXPECT_STATUS=1 ds_code a skills track chart-making --all
assert_contains "$DS_STDERR" "uncommitted"
assert_contains "$DS_STDERR" "--own"
assert_eq "$tip" "$(remote_tip)"

mkdir -p "$sources/local-only/plotting"
git init -q -b main "$sources/local-only"
printf -- '---\nname: plotting\ndescription: Synthetic skill.\n---\n' >"$sources/local-only/plotting/SKILL.md"
git -C "$sources/local-only" add -A
git -C "$sources/local-only" commit -q -m "chore: a skill"
ln -s "$sources/local-only/plotting" "$agents_skills/plotting"
assert_exit 0 ds a skills reconcile
assert_eq unknown "$(item a plotting .origin)"
assert_contains "$(item a plotting .origin_detail)" "no remote"
EXPECT_STATUS=1 ds_code a skills track plotting --all
assert_contains "$DS_STDERR" "no remote"
# Given a remote, the next full look knows where it comes from.
git -C "$sources/local-only" remote add origin https://example.com/example-org/plotting.git
# What a fetch of it would leave: a remote branch at the commit.
git -C "$sources/local-only" update-ref refs/remotes/origin/main HEAD
assert_exit 0 ds a skills reconcile --full
assert_eq downloaded "$(item a plotting .origin)"
assert_eq https://example.com/example-org/plotting.git "$(item a plotting .source.url)"
assert_eq plotting "$(item a plotting .source.path)"

# Once the clone is clean again, the answer looks again.
rm -f "$clone/chart-making/NOTES.md"
ds_code a skills track chart-making --here
entry=$(remote_entry chart-making)
assert_eq "$public" "$(jq -r .source <<<"$entry")"
assert_eq chart-making "$(jq -r .source_path <<<"$entry")"
assert_json - '.machines == ["a"]' <<<"$entry"

# --- a clone of its own stays a question, whatever a file tool wrote into it --------------------

solo=$world/solo
git init -q -b main "$solo"
printf -- '---\nname: solo\ndescription: Synthetic skill.\n---\n' >"$solo/SKILL.md"
printf 'Synthetic license\n' >"$solo/LICENSE"
git -C "$solo" add -A
git -C "$solo" commit -q -m "chore: a skill at the top"
git -c "url.file://$solo.insteadOf=https://github.com/example-org/solo" \
  clone -q https://github.com/example-org/solo "$(home_of a)/.claude/skills/solo"
printf 'an edit\n' >>"$(home_of a)/.claude/skills/solo/SKILL.md"
wrote a solo
assert_exit 0 ds a skills reconcile
assert_eq ask "$(item a solo .state)"
assert_eq unknown "$(item a solo .origin)"
assert_contains "$(item a solo .origin_detail)" "uncommitted"
plugin_upstream=$world/plugin-upstream
new_plugin a plugin-upstream
mv "$(plugin_dir a plugin-upstream)" "$plugin_upstream"
git -C "$plugin_upstream" init -q -b main
git -C "$plugin_upstream" add -A
git -C "$plugin_upstream" commit -q -m "chore: a plugin"
git -c "url.file://$plugin_upstream.insteadOf=https://github.com/example-org/cloned-plugin" \
  clone -q https://github.com/example-org/cloned-plugin "$(plugin_dir a cloned-plugin)"
printf '\n' >>"$(plugin_dir a cloned-plugin)/.claude-plugin/plugin.json"
tool_wrote a "$(plugin_dir a cloned-plugin)/.claude-plugin/plugin.json"
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a cloned-plugin .state)"
assert_eq unknown "$(plugin_item a cloned-plugin .origin)"

# --- credentials in the remote stay on this machine ------------------------------------------------

kit=$world/kit
git init -q -b main "$kit"
mkdir -p "$kit/plotting-kit"
printf -- '---\nname: plotting-kit\ndescription: Synthetic skill.\n---\n' >"$kit/plotting-kit/SKILL.md"
printf 'Synthetic license\n' >"$kit/LICENSE"
git -C "$kit" add -A
git -C "$kit" commit -q -m "chore: a skill"
git clone -q "$kit" "$sources/kit"
git -C "$sources/kit" remote set-url origin https://reader:not-a-real-secret@example.com/example-org/kit.git
ln -s "$sources/kit/plotting-kit" "$agents_skills/plotting-kit"
assert_exit 0 ds a skills reconcile
assert_eq https://example.com/example-org/kit.git "$(item a plotting-kit .source.url)"
ds_code a skills track plotting-kit --here
assert_eq https://example.com/example-org/kit.git "$(jq -r .source <<<"$(remote_entry plotting-kit)")"
if git -C "$remote" grep -q not-a-real-secret refs/heads/main --; then
  ds_fail "no credential reaches the remote"
fi
if grep -rq not-a-real-secret "$(state_of a)/skills"; then
  ds_fail "no credential is kept in the state"
fi

# --- seen as unknown and declined before: --all looks again and takes the decline back ----------

git -C "$(clone_of a)" pull -q --ff-only
cp -a "$upstream_work/chart-making" "$upstream_work/table-making"
sed -i 's/^name: chart-making$/name: table-making/' "$upstream_work/table-making/SKILL.md"
git -C "$upstream_work" add -A
git -C "$upstream_work" commit -q -m "chore: a third skill"
git -C "$upstream_work" push -q "$upstream" main
git -C "$clone" "${redirect[@]}" pull -q --ff-only
ln -s "$clone/table-making" "$agents_skills/table-making"
assert_exit 0 ds a skills reconcile
ds_code a skills track table-making --never
assert_contains "$(remote_file hosts/a.toml)" table-making
# What an earlier version left: the origin unknown, no source.
pending=$(state_of a)/skills/pending.json
jq '.items["skill:table-making"] += {origin: "unknown", source: null}' "$pending" >"$pending.tmp"
mv -- "$pending.tmp" "$pending"
assert_eq declined "$(item a table-making .state)"
ds_code a skills track table-making --all
assert_not_contains "$(remote_file hosts/a.toml)" table-making
entry=$(remote_entry table-making)
assert_eq "$public" "$(jq -r .source <<<"$entry")"
assert_eq table-making "$(jq -r .source_path <<<"$entry")"
assert_eq "$(git -C "$clone" rev-parse HEAD)" "$(jq -r .revision <<<"$entry")"
assert_eq "{}" "$(item a table-making .)"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a skills reconcile
assert_eq "{}" "$(item a table-making .)"
assert_exit 0 ds a "${install[@]}"
assert_exit 0 ds a agents check --profile workstation
assert_eq "" "$(git -C "$clone" status --porcelain)"

# --- the pin moves ahead of the clone (an update of pins before the next pull): still green -------

inst=$(clone_of a)
printf -- '---\nname: figure-making\ndescription: Synthetic skill.\n---\n\nversion three\n' \
  >"$upstream_work/figure-making/SKILL.md"
git -C "$upstream_work" commit -q -am "chore: version three"
git -C "$upstream_work" push -q "$upstream" main
ahead=$(git -C "$upstream_work" rev-parse HEAD)
rm -rf "$inst/agent/skills/figure-making"
git -C "$upstream_work" archive HEAD figure-making | tar -x -C "$inst/agent/skills"
lock=$inst/agent/skills.lock.json
jq --arg revision "$ahead" --arg dsha "$(local_digest "$inst/agent/skills/figure-making")" \
  --arg sha "$(sha256sum "$inst/agent/skills/figure-making/SKILL.md" | cut -d' ' -f1)" \
  '(.skills[] | select(.name == "figure-making")) += {revision: $revision, directory_sha256: $dsha, skill_sha256: $sha}' \
  "$lock" >"$lock.tmp"
mv -- "$lock.tmp" "$lock"
assert_exit 0 ds a agents check --profile workstation
assert_contains "$DS_STDERR" "skill figure-making follows its clone"
assert_not_contains "$(cat "$clone/figure-making/SKILL.md")" "version three"
git -C "$inst" checkout -q -- agent

# --- a file tool edits a linked download that waits for its answer: still a question -------------

graphs=$world/graphs
git init -q -b main "$graphs"
mkdir -p "$graphs/graph-making"
printf -- '---\nname: graph-making\ndescription: Synthetic skill.\n---\n' >"$graphs/graph-making/SKILL.md"
printf 'Synthetic license\n' >"$graphs/LICENSE"
git -C "$graphs" add -A
git -C "$graphs" commit -q -m "chore: a skill"
git -c "url.file://$graphs.insteadOf=https://github.com/example-org/graphs" \
  clone -q https://github.com/example-org/graphs "$sources/graphs"
ln -s "$sources/graphs/graph-making" "$agents_skills/graph-making"
assert_exit 0 ds a skills reconcile
assert_eq downloaded "$(item a graph-making .origin)"
printf 'an edit through the link\n' >>"$agents_skills/graph-making/SKILL.md"
tool_wrote a "$agents_skills/graph-making/SKILL.md" post-tool-use-edit
assert_eq ask "$(item a graph-making .state)"
assert_eq unknown "$(item a graph-making .origin)"
assert_contains "$(item a graph-making .origin_detail)" "uncommitted"
find "$sources/graphs" -exec touch -h -d '2001-01-01' {} +
tip=$(remote_tip)
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "nothing is published without an answer"

# --- forget takes the license beside the copy along -------------------------------------------------

ds_code a skills forget figure-making
if git -C "$remote" cat-file -e refs/heads/main:agent/skill-licenses/figure-making 2>/dev/null; then
  ds_fail "the license goes with the skill"
fi
if git -C "$remote" cat-file -e refs/heads/main:agent/skills/figure-making 2>/dev/null; then
  ds_fail "the skill is gone from the repository"
fi
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a static --only skills
