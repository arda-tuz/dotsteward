# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# The flows of plugins/dotsteward/skills/dotsteward-init (SPEC 9.7, 4.4):
# the frontmatter text, the reference set, the new-instance flow (read-only
# machine checks, sudo explained first, Nix only from the pinned release's
# verified installer and only after the user agrees, components and methods
# from the catalog, init, a private repository, bootstrap or rebuild, e2e,
# the hand-over to dotsteward-maintain), the existing-instance flow (clone,
# the identity facts of `dotsteward context --json`, no edit needed,
# bootstrap or rebuild, e2e), the login shell of an adopted machine set
# before e2e, the supported platforms, every flag the commands outside the
# dotsteward CLI pass, and no command or path of the single-user scripts the
# CLI replaced.

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

# subsection_of FILE HEADING: the lines of the level-3 section whose heading
# starts with HEADING, up to the next heading.
subsection_of() {
  awk -v heading="### $2" '
    /^##+ / { inside = (index($0, heading) == 1) }
    inside { print }
  ' "$1"
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

# The skill runs before any instance exists: no overlay precedence and no
# classification; it runs the instance's gate once before the first push,
# and the framework skills of the instance take over afterwards.
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
  ".dotsteward/cli.sh gate --scope maintain" \
  "push -u origin main" \
  "./bootstrap.sh --profile" \
  "./rebuild.sh --profile" \
  "login-shell set --profile" \
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
# The gate proves the tree before the first push (the order of the
# instance's AGENTS.md): the repository is created without --push, and the
# push follows the gate.
assert_not_contains "$repo_lines" "--push" "the repository is created before the gate, without the push"
# shellcheck disable=SC2016 # literal shell text of the skill
assert_contains "$all_fenced" 'git -C "$dir" push -u origin main' "the instance is pushed after the gate"
grep -qF 'gate --scope maintain' <<<"$all_fenced" || ds_fail "no fenced gate before the first push"
assert_contains "$(subsection_of "$skill" "3.5")" "AGENTS.md" "the gate step names the rule of the instance's AGENTS.md"
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
  "login-shell set --profile" \
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
# The adopt path: the rebuild only moves a versioned Nix zsh login shell to
# the stable path (login-shell migrate), and only the bootstrap sets it, so
# an adopted machine whose instance manages the login shell sets it with
# login-shell set before e2e checks it (core:login-shell).
for file in "$new_ref" "$existing_ref" "$platform_ref"; do
  # shellcheck disable=SC2016 # literal shell text of the skill
  grep -q '\.dotsteward/cli\.sh login-shell set --profile' "$file" ||
    ds_fail "${file#"$DS_REPO_ROOT"/} does not set the login shell of an adopted machine with login-shell set"
done

# A local-only instance: e2e without --keep-going stops at core:repo-remote
# (remote-unreachable or remote-mismatch) until the push, the bootstrap that
# ends with it exits non-zero, so the machine is verified with --keep-going
# and that one finding is the expected one.
local_repo=$(section "$new_ref" "Repository")
for text in "--keep-going" "core:repo-remote" "remote-unreachable" "remote-mismatch" "./bootstrap.sh"; do
  assert_contains "$local_repo" "$text" "new-instance.md, the local repository"
done
# shellcheck disable=SC2016 # literal shell text of the skill
assert_contains "$(fenced "$new_ref")" 'e2e --profile "$profile" --keep-going' \
  "new-instance.md verifies a local-only instance with --keep-going"
assert_contains "$new_flow" "--keep-going" "the new-instance flow verifies a local-only instance with --keep-going"
assert_contains "$new_flow" "core:repo-remote" "the new-instance flow names the expected finding of a local-only instance"

# Coding-agent shells usually have no terminal: the commands that ask for
# sudo or an installer confirmation go to the user's own terminal when this
# shell has none or sudo has no cached credentials.
rules=$(awk '/^## Rules/ { inside = 1; next } /^## / { inside = 0 } inside { print }' "$skill")
for text in "in their own terminal" "[ -t 0 ]" "sudo -n true" "--install-nix-only" "login-shell set" "platform-prereqs.md"; do
  assert_contains "$rules" "$text" "the terminal rule of SKILL.md"
done
# Every step that runs one of them points at that rule: the Nix install
# (3.2), the machine setup (3.6) and the existing-instance flow (section 4,
# its Nix install and its setup).
subsection() {
  awk -v heading="### $2" '
    /^##+ / { inside = (index($0, heading) == 1) }
    inside { print }
  ' "$1"
}
for heading in "3.2" "3.6"; do
  grep -q 'own terminal' <<<"$(subsection "$skill" "$heading")" ||
    ds_fail "SKILL.md $heading does not point its sudo steps at the terminal rule"
done
[[ $(grep -c 'own terminal' <<<"$existing_flow") -ge 2 ]] ||
  ds_fail "SKILL.md section 4 does not point both its Nix install and its setup at the terminal rule"
for file in "$new_ref" "$existing_ref" "$platform_ref"; do
  grep -q 'own terminal' "$file" || ds_fail "${file#"$DS_REPO_ROOT"/} does not send the sudo steps to the user's own terminal"
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
login_shell_help=$("$DS_REPO_ROOT/cli/dotsteward" login-shell --help)
e2e_help=$("$DS_REPO_ROOT/cli/dotsteward" e2e --help)
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
check_flags "login-shell" "$login_shell_help" "$(sed -n 's/.*cli\.sh login-shell //p' <<<"$all_fenced" | sed 's/[;&|].*//')"
check_flags "e2e" "$e2e_help" "$(sed -n 's/.*cli\.sh e2e //p' <<<"$all_fenced" | sed 's/[;&|].*//')"
check_flags "bootstrap.sh" "$bootstrap_help" "$(sed -n 's/.*bootstrap\.sh"\{0,1\} //p' <<<"$all_fenced" | sed 's/[;&|].*//')"

# No command or path of the single-user scripts the CLI replaced, and no
# CI-only switch (e2e --skip-repo-checks is for CI fixtures).
for file in "${all_files[@]}" "$skill_dir/agents/openai.yaml"; do
  # shellcheck disable=SC2088 # literal text, not a path
  for stale in '~/.dotfiles' '.local/state/dotfiles' 'update.sh --' 'scripts/pins.py' \
    'scripts/validate.sh' 'scripts/preflight.sh' 'DOTSTEWARD_ASSUME_YES=1' '--skip-repo-checks'; do
    if grep -qF -- "$stale" "$file"; then
      ds_fail "${file#"$DS_REPO_ROOT"/} names [$stale]"
    fi
  done
done

# Another framework source (a local checkout, a fork, a branch): 3.4 points
# at init's --framework-url, and new-instance.md shows the whole run from a
# local checkout, with the same source for the Nix install, nix run and the
# pin, and says that such a pin works only where the source exists.
init_step=$(subsection_of "$skill" "3.4")
assert_contains "$init_step" "--framework-url" "3.4 names the other framework sources"
assert_contains "$init_step" "references/new-instance.md" "3.4 points at the details of the other sources"
source_ref=$(section "$new_ref" "Another framework source")
[[ -n $source_ref ]] || ds_fail "new-instance.md has no section 'Another framework source'"
# shellcheck disable=SC2016 # literal shell text of the skill
for text in '--framework-url "path:$framework"' 'run "path:$framework#dotsteward" -- init' \
  '"$framework/template/bootstrap.sh" --install-nix-only' 'git+https://' 'this machine' 'dotsteward-update'; do
  assert_contains "$source_ref" "$text" "new-instance.md, another framework source"
done
grep -q 'framework source' <<<"$rules" || ds_fail "the one-release rule does not cover another framework source"

