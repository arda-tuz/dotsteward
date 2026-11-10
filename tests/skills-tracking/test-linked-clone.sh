# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A downloaded skill is often a link from a skill root into a clone kept elsewhere, the
# skill one directory of it. The link is followed: a clean clone with a remote is where the
# skill comes from, and --all pins that remote, the directory and the commit, as for a
# record of `npx skills`. The clone moves by itself later: agents install never writes
# through the link and agents check stays green. A clone with changes or without a remote
# says why it is unknown, here and in the refusal of --all. An answer about a skill that was
# seen as unknown before looks again, also after --never.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
new_machine b
install=(agents install --profile workstation --skip-validation)
agents_skills=$(home_of a)/.agents/skills
sources=$(home_of a)/.local/share/skill-sources
public=https://github.com/example-org/figures
mkdir -p "$sources"

# The upstream: a repository with two skills, each a directory of it, with a license.
upstream=$world/figures.git
upstream_work=$world/figures
git init -q -b main "$upstream_work"
for skill in figure-making chart-making; do
  mkdir -p "$upstream_work/$skill"
  printf -- '---\nname: %s\ndescription: Synthetic skill.\n---\n\nversion one\n' "$skill" >"$upstream_work/$skill/SKILL.md"
  printf 'MIT\n' >"$upstream_work/$skill/LICENSE"
done
printf '# Figures\n' >"$upstream_work/README.md"
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
assert_eq "{}" "$(item a figure-making .)"

# --- the clone moves by itself; nothing writes through the link, nothing turns red ------------

git -C "$(clone_of a)" pull -q --ff-only
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

# Once the clone is clean again, the answer looks again.
rm -f "$clone/chart-making/NOTES.md"
ds_code a skills track chart-making --here
entry=$(remote_entry chart-making)
assert_eq "$public" "$(jq -r .source <<<"$entry")"
assert_eq chart-making "$(jq -r .source_path <<<"$entry")"
assert_json - '.machines == ["a"]' <<<"$entry"

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
