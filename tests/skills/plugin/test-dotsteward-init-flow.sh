# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# The flows of plugins/dotsteward/skills/dotsteward-init (SPEC 9.7, 4.4):
# the frontmatter text, the reference set, the new-instance flow (read-only
# machine checks, sudo explained first, Nix only from the pinned release's
# verified installer and only after the user agrees, components and methods
# from the catalog, init, a private repository, bootstrap or rebuild, e2e,
# the hand-over to dotsteward-maintain), the existing-instance flow (clone,
# the identity facts of `dotsteward context --json`, no edit needed,
# bootstrap or rebuild, e2e), the supported platforms, every flag the
# commands outside the dotsteward CLI pass, and no command or path of the
# single-user scripts the CLI replaced.

skill_dir=$DS_REPO_ROOT/plugins/dotsteward/skills/dotsteward-init
skill=$skill_dir/SKILL.md
new_ref=$skill_dir/references/new-instance.md
existing_ref=$skill_dir/references/existing-instance.md
platform_ref=$skill_dir/references/platform-prereqs.md
[[ -f $skill ]] || ds_fail "missing plugins/dotsteward/skills/dotsteward-init/SKILL.md"

# first_line FILE AFTER TEXT: the first line number greater than AFTER that
# contains TEXT (fixed string), or fails the test.
first_line() {
  local file=$1 after=$2 text=$3 found
  found=$(awk -v after="$after" -v text="$text" 'NR > after && index($0, text) { print NR; exit }' "$file")
  [[ -n $found ]] || ds_fail "${file#"$DS_REPO_ROOT"/}: no [$text] after line $after"
  printf '%s\n' "$found"
}

# in_order FILE TEXT...: every TEXT occurs, each after the previous one.
in_order() {
  local file=$1 line=0 text
  shift
  for text in "$@"; do
    line=$(first_line "$file" "$line" "$text")
  done
}

# section FILE HEADING: the lines of the level-2 section whose heading
# starts with HEADING, up to the next level-2 heading.
section() {
  awk -v heading="## $2" '
    /^## / { inside = (index($0, heading) == 1) }
    inside { print }
  ' "$1"
}

# fenced FILE...: the lines inside fenced blocks, backslash continuations
# joined.
fenced() {
  awk '
    FNR == 1 { open = 0; buffer = "" }
    /^[ \t]*(```|~~~)/ { open = !open; next }
    !open { next }
    /\\$/ { buffer = buffer substr($0, 1, length($0) - 1) " "; next }
    { print buffer $0; buffer = "" }
  ' "$@"
}

all_files=("$skill" "$skill_dir"/references/*.md)
all_fenced=$(fenced "${all_files[@]}")

# Frontmatter: the description of SPEC 9.7, word for word.
expected_description="Set up a dotsteward workstation: create a new private instance repository from the template, or install an existing instance on this machine."
description=$(awk 'NR == 1 { next } /^---[ \t]*$/ { exit } /^description:/ { sub(/^description:[ \t]*/, ""); print }' "$skill")
# The text holds ": ", which ends a plain YAML scalar, so the skill loaders
# can parse the frontmatter only when the value is double-quoted.
[[ $description == \"*\" ]] || ds_fail "the frontmatter description is not a double-quoted YAML string"
description=${description#\"}
description=${description%\"}
assert_eq "$expected_description" "$description" "frontmatter description"

# References: the two flows, the platforms and the generated catalog.
references=$(find "$skill_dir/references" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
assert_eq "catalog.md existing-instance.md new-instance.md platform-prereqs.md " \
  "$references" "reference files"

# The skill runs before any instance exists: no overlay precedence, no
# classification, no gate of its own; the framework skills of the instance
# take over afterwards.
for name in dotsteward-maintain dotsteward-update dotsteward-contribute; do
  grep -q "$name" "$skill" || ds_fail "SKILL.md does not name $name for the changes after setup"
done

# The machine checks come first and are read-only.
checks=$(section "$skill" "2.")
[[ -n $checks ]] || ds_fail "SKILL.md has no section 2 (the machine checks)"
for text in "uname" "/etc/os-release" "sw_vers" "command -v nix git gh" "df -Pk"; do
  assert_contains "$checks" "$text" "the machine checks"
done
grep -qi 'read-only' <<<"$checks" || ds_fail "SKILL.md does not call the machine checks read-only"
grep -q 'references/platform-prereqs.md' <<<"$checks" ||
  ds_fail "the machine checks do not compare with references/platform-prereqs.md"
# sudo is explained (the Nix daemon, system packages, the login shell)
# before the first command that writes anything.
grep -qi 'sudo' <<<"$checks" || ds_fail "the machine checks do not explain the sudo needs"
for need in "Nix daemon" "system packages" "login shell"; do
  grep -qi "$need" <<<"$checks" || ds_fail "the sudo explanation does not name [$need]"
done

# The new-instance flow, in the order of SPEC 9.7.
in_order "$skill" \
  "## 2." \
  "command -v nix git gh" \
  "sudo" \
  "## 3." \
  "gh release view --repo arda-tuz/dotsteward" \
  "git clone --depth 1 --branch" \
  "--install-nix-only" \
  "references/catalog.md" \
  "gh config get git_protocol" \
  "run \"github:arda-tuz/dotsteward/\$tag\" -- init" \
  "gh repo create" \
  "git -C" \
  "./bootstrap.sh --profile" \
  "./rebuild.sh --profile" \
  ".dotsteward/cli.sh e2e --profile" \
  "dotsteward-maintain"

new_flow=$(section "$skill" "3.")
# Nix: only when missing, only after the user agrees, from the release's
# verified installer, never a piped download.
grep -qi 'agree' <<<"$new_flow" || ds_fail "the new-instance flow installs Nix without the user's agreement"
assert_contains "$(fenced "$skill" "$new_ref")" "gh release download" "the release can be downloaded with gh"
assert_contains "$(fenced "$skill")" "template/bootstrap.sh\" --install-nix-only" \
  "Nix comes from the template bootstrap of the release"
if grep -Eq '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z)?sh' <<<"$all_fenced"; then
  ds_fail "a fenced command pipes a download into a shell"
fi
grep -q 'curl | sh' "$skill" || ds_fail "SKILL.md does not rule out curl | sh"
# One release for the whole run: the downloaded installer, nix run and the
# framework reference of init.
# shellcheck disable=SC2016 # literal shell text of the skill
assert_contains "$all_fenced" 'github:arda-tuz/dotsteward/$tag' "nix run uses the chosen release"
# shellcheck disable=SC2016 # literal shell text of the skill
assert_contains "$all_fenced" '--framework-ref "$tag"' "init pins the chosen release"
# Components and methods come from the catalog reference.
grep -q 'references/catalog.md' <<<"$new_flow" || ds_fail "the new-instance flow does not offer references/catalog.md"
grep -q 'references/new-instance.md' "$skill" || ds_fail "SKILL.md does not link references/new-instance.md"
# init: non-interactive, with the remote that origin will print.
init_lines=$(grep -- '-- init' <<<"$all_fenced") || ds_fail "no fenced init command"
assert_contains "$init_lines" "--non-interactive" "init runs non-interactively"
assert_contains "$init_lines" "--remote" "init gets the remote"
assert_contains "$init_lines" "--dir" "init gets the directory"
assert_contains "$init_lines" "--components" "init gets the components"
grep -q 'git remote get-url origin' "$skill" || ds_fail "SKILL.md does not compare the remote with git remote get-url origin"
# The repository is private, or stays local on request.
repo_lines=$(grep 'gh repo create' <<<"$all_fenced") || ds_fail "no fenced gh repo create"
assert_contains "$repo_lines" "--private" "the repository is private"
assert_contains "$repo_lines" "--source" "the repository is created from the instance directory"
assert_contains "$repo_lines" "--push" "the instance is pushed"
assert_contains "$all_fenced" "--json visibility" "the visibility is verified"
grep -qi 'local' <<<"$new_flow" || ds_fail "the new-instance flow does not offer to keep the repository local"
# Activation: bootstrap on a fresh machine, rebuild on one that is set up,
# confirmed by the user first; then e2e and the summary.
grep -qi 'fresh machine' <<<"$new_flow" || ds_fail "the new-instance flow does not name the fresh-machine path"
grep -qi 'confirm' "$skill" || ds_fail "SKILL.md does not confirm the activation with the user"
assert_contains "$all_fenced" "./rollback.sh --latest --dry-run" "the summary names the rollback"

# The existing-instance flow (SPEC 4.4).
in_order "$skill" \
  "## 4." \
  "gh repo clone" \
  "--install-nix-only" \
  ".dotsteward/cli.sh context --json" \
  "runtime_matches_check" \
  "./bootstrap.sh --profile" \
  "./rebuild.sh --profile" \
  ".dotsteward/cli.sh e2e --profile"
existing_flow=$(section "$skill" "4.")
grep -q 'references/existing-instance.md' <<<"$existing_flow" ||
  ds_fail "the existing-instance flow does not link references/existing-instance.md"
grep -qi 'no file edit' <<<"$existing_flow" || ds_fail "the existing-instance flow does not say that no file edit is needed"
grep -q '\[identity\]' <<<"$existing_flow" || ds_fail "the existing-instance flow does not explain [identity]"
grep -qi 'only for checks' <<<"$existing_flow" || ds_fail "the existing-instance flow does not say [identity] is only for checks"
grep -q 'dotsteward-maintain' <<<"$existing_flow" ||
  ds_fail "the existing-instance flow does not hand an [identity] change to dotsteward-maintain"
for flag in --username --home; do
  grep -q -- "$flag" "$existing_ref" || ds_fail "existing-instance.md does not say that init's $flag is for new instances only"
done
grep -qi 'new instances only' "$existing_ref" || ds_fail "existing-instance.md does not limit --username and --home to new instances"
for field in check_username runtime_user runtime_home profiles.bootstrap profiles.check instance.checkout; do
  grep -q "$field" "$existing_ref" || ds_fail "existing-instance.md does not read $field"
done
# The fresh-machine bootstrap refuses another Nix version; the existing
# machine path is the rebuild.
grep -qi 'nix --version' "$existing_ref" || ds_fail "existing-instance.md does not check the Nix version against the pin"
grep -q 'exit 3' "$skill" || ds_fail "SKILL.md does not explain preflight exit 3 (the adaptive route)"

# Platforms: Ubuntu 24.04 on x86_64, macOS on arm64 with standalone Home
# Manager (evaluated by the framework checks).
for text in "Ubuntu 24.04" "x86_64" "arm64" "standalone Home Manager" "evaluated" "xcode-select --install"; do
  grep -q "$text" "$platform_ref" || ds_fail "platform-prereqs.md does not name [$text]"
done

# Commands outside the dotsteward CLI pass only flags that exist: init (run
# through nix run), the instance wrappers and the stage-0 bootstrap.
init_help=$("$DS_REPO_ROOT/cli/dotsteward" init --help)
rebuild_help=$("$DS_REPO_ROOT/cli/dotsteward" rebuild --help)
bootstrap_help=$(bash "$DS_REPO_ROOT/template/bootstrap.sh" --help)
check_flags() {
  local what=$1 help=$2 lines=$3 line flag
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    while IFS= read -r flag; do
      grep -qE -- "(^|[^a-z0-9-])$flag([^a-z0-9-]|\$)" <<<"$help" ||
        ds_fail "$what: $flag is not in its --help (line [$line])"
    done < <(grep -oE '(^|[[:space:]])--[a-z][a-z0-9-]*' <<<"$line" | tr -d ' \t')
  done <<<"$lines"
}
check_flags "dotsteward init" "$init_help" "$(sed -n 's/.* -- init //p' <<<"$all_fenced")"
check_flags "rebuild.sh" "$rebuild_help" "$(sed -n 's/.*\.\/rebuild\.sh //p' <<<"$all_fenced" | sed 's/[;&|].*//')"
check_flags "bootstrap.sh" "$bootstrap_help" "$(sed -n 's/.*bootstrap\.sh"\{0,1\} //p' <<<"$all_fenced" | sed 's/[;&|].*//')"

# No command or path of the single-user scripts the CLI replaced.
for file in "${all_files[@]}" "$skill_dir/agents/openai.yaml"; do
  # shellcheck disable=SC2088 # literal text, not a path
  for stale in '~/.dotfiles' '.local/state/dotfiles' 'update.sh --' 'scripts/pins.py' \
    'scripts/validate.sh' 'scripts/preflight.sh' 'DOTSTEWARD_ASSUME_YES=1'; do
    if grep -qF -- "$stale" "$file"; then
      ds_fail "${file#"$DS_REPO_ROOT"/} names [$stale]"
    fi
  done
done
