# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # fixture text with a literal $ is written on purpose
# T2: every generic instance contract has a failing fixture: vendored skill
# integrity (symlinks, digests, license, lock names and directories,
# framework skill names; expected_skill_count, a copy of the number of
# entries, is optional and ignored), shell hygiene (bash -n, exec bit,
# ShellCheck version and
# findings), policy bans, the launcher and bootstrap copies, the versions
# lock policy, the update allowlist versus the settings buffer, byte-protected
# files and overlays. All failures of a run are reported before exiting 1.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

command -v shellcheck >/dev/null 2>&1 || ds_fail "the static tests need shellcheck on PATH"

base=$DS_TEST_ROOT/base
make_instance "$base"
case_no=0

# fresh: a new copy of the base instance as the working directory.
fresh() {
  case_no=$((case_no + 1))
  cp -a "$base" "$DS_TEST_ROOT/case-$case_no"
  cd "$DS_TEST_ROOT/case-$case_no"
}

# fails CHECK MESSAGE...: `static --only CHECK` exits 1 and reports each
# MESSAGE as "static CHECK: MESSAGE".
fails() {
  local check=$1 message
  shift
  assert_exit 1 static --only "$check"
  for message in "$@"; do
    assert_contains "$DS_STDERR" "[dotsteward] ERROR: static $check: $message"
  done
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: static checks failed (instance): $check"
}

skill=agent/skills/example-skill

# --- skills ------------------------------------------------------------------
fresh
ln -s references/guide.md "$skill/link.md"
fails skills "$skill/link.md: vendored skills must not contain symbolic links"

fresh
mv agent/skills agent/real-skills
ln -s real-skills agent/skills
fails skills "agent/skills: the vendored skills directory must not be a symbolic link"

fresh
printf 'changed\n' >>"$skill/SKILL.md"
fails skills "example-skill: SKILL.md digest does not match agent/skills.lock.json"

fresh
printf 'extra\n' >"$skill/references/extra.md"
fails skills "example-skill: directory digest does not match agent/skills.lock.json"

fresh
rm "$skill/LICENSE"
write_skill_lock "$PWD"
fails skills "example-skill: no license file"

# A skill of the user's own (a repo-owned sentinel revision) needs no license,
# and every other rule still holds for it.
fresh
rm "$skill/LICENSE"
write_skill_lock "$PWD"
own_filter='.skills[0].revision = "same-as-instance-checkout"'
jq "$own_filter" agent/skills.lock.json >lock.tmp && mv lock.tmp agent/skills.lock.json
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --instance "$PWD" static --only skills
printf 'extra\n' >"$skill/references/extra.md"
fails skills "example-skill: directory digest does not match agent/skills.lock.json"

fresh
rm "$skill/LICENSE"
write_skill_lock "$PWD"
printf '\n[compat]\nrepo_owned_revision = "same-as-example-checkout"\n' >>workstation.toml
own_filter='.skills[0].revision = "same-as-example-checkout"'
jq "$own_filter" agent/skills.lock.json >lock.tmp && mv lock.tmp agent/skills.lock.json
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --instance "$PWD" static --only skills

# Own plugins of the lock (own_plugins[], agent/plugins/<directory>).
fresh
plugin=agent/plugins/example-plugin
mkdir -p "$plugin/.claude-plugin"
printf '{"name": "example-plugin"}\n' >"$plugin/.claude-plugin/plugin.json"
plugin_sha=$(dir_sha256_of "$plugin")
write_own_plugins() {
  jq --arg sha "$1" '.own_plugins = [{name: "example-plugin", directory: "example-plugin", agents: ["claude"], directory_sha256: $sha}]' \
    agent/skills.lock.json >lock.tmp
  mv lock.tmp agent/skills.lock.json
}
write_own_plugins "$plugin_sha"
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --instance "$PWD" static --only skills
write_own_plugins "$(printf '0%.0s' {1..64})"
fails skills "example-plugin: directory digest does not match agent/skills.lock.json"
write_own_plugins "$plugin_sha"
mkdir agent/plugins/unlisted
fails skills "agent/plugins: directories do not match the lock (expected example-plugin, found example-plugin unlisted)"
rmdir agent/plugins/unlisted
ln -s .claude-plugin/plugin.json "$plugin/link"
fails skills "agent/plugins/example-plugin/link: own plugins must not contain symbolic links"
rm "$plugin/link"
jq '.own_plugins[0].directory = "../example-plugin"' agent/skills.lock.json >lock.tmp && mv lock.tmp agent/skills.lock.json
fails skills "example-plugin: invalid directory ../example-plugin"

fresh
sed -i 's/^name: example-skill$/name: other-skill/' "$skill/SKILL.md"
write_skill_lock "$PWD"
fails skills "example-skill: SKILL.md declares name other-skill"

fresh
add_skill "$PWD" second-skill
fails skills "agent/skills: directories do not match the lock (expected example-skill, found example-skill second-skill)"

# expected_skill_count only copies the number of entries, which are the
# lock: a stale or a missing count is no finding.
fresh
jq '.expected_skill_count = 2' agent/skills.lock.json >lock.tmp && mv lock.tmp agent/skills.lock.json
assert_exit 0 static --only skills
fresh
jq 'del(.expected_skill_count)' agent/skills.lock.json >lock.tmp && mv lock.tmp agent/skills.lock.json
assert_exit 0 static --only skills

fresh
add_skill "$PWD" dotsteward-update
write_skill_lock "$PWD"
fails skills "dotsteward-update: framework skills never appear in agent/skills.lock.json"

fresh
jq '.skills[0].skill_sha256 = "abc"' agent/skills.lock.json >lock.tmp && mv lock.tmp agent/skills.lock.json
fails skills "example-skill: skill_sha256 is not a sha256 hex digest"

fresh
rm agent/skills.lock.json
fails skills "agent/skills.lock.json is missing but agent/skills holds vendored skills"

# Skill entries that are not objects are findings, not unexpected errors,
# also when no skill directory exists to compare with.
fresh
rm -rf agent/skills
jq -n '{schema_version: "1.0", expected_skill_count: 1, skills: ["x"]}' >agent/skills.lock.json
fails skills "agent/skills.lock.json: every skill entry must be an object"
assert_not_contains "$DS_STDERR" "failed unexpectedly"
fresh
jq '.skills += [5] | .expected_skill_count = 2' agent/skills.lock.json >lock.tmp && mv lock.tmp agent/skills.lock.json
printf 'changed\n' >>"$skill/SKILL.md"
fails skills "agent/skills.lock.json: every skill entry must be an object" \
  "example-skill: SKILL.md digest does not match agent/skills.lock.json"
assert_not_contains "$DS_STDERR" "failed unexpectedly"

# No vendored skills and no lock: nothing to check.
fresh
rm -rf agent/skills agent/skills.lock.json
assert_exit 0 static --only skills

# --- shell -------------------------------------------------------------------
fresh
printf '#!/usr/bin/env bash\nif then\n' >scripts/broken.sh
chmod 0755 scripts/broken.sh
chmod 0644 scripts/hello.sh
printf 'printf ok\n' >scripts/plain.sh
fails shell "scripts/broken.sh: bash -n failed" \
  "scripts/hello.sh: has a shebang but is not executable" \
  "scripts/plain.sh: has neither a shebang nor a '# shellcheck shell=' directive"

# A shebang names the interpreter, so extensionless scripts are checked too.
fresh
printf '#!/bin/sh\nif then\n' >scripts/tool
chmod 0755 scripts/tool
fails shell "scripts/tool: bash -n failed"

fresh
printf '#!/usr/bin/env bash\nfiles=$(ls)\necho $files\n' >scripts/lint.sh
chmod 0755 scripts/lint.sh
fails shell "shellcheck reported findings"
assert_contains "$DS_STDOUT$DS_STDERR" "SC2086"

# ShellCheck must be the version the instance pins.
fresh
jq '.nix_packages.shellcheck = { expected: "locked nixpkgs package", resolved: "0.0.1" }' versions.lock.json >lock.tmp
mv lock.tmp versions.lock.json
fails shell "ShellCheck 0.0.1 is pinned in versions.lock.json but"
# A versions lock the pin cannot be read from fails the check instead of
# skipping the pin.
fresh
jq '.nix_packages = "none"' versions.lock.json >lock.tmp && mv lock.tmp versions.lock.json
fails shell "versions.lock.json cannot be read as a versions lock, so the pinned ShellCheck version is unknown"
assert_not_contains "$DS_STDERR" "failed unexpectedly"
fresh
printf '{ broken\n' >versions.lock.json
fails shell "versions.lock.json cannot be read as a versions lock, so the pinned ShellCheck version is unknown"
fresh
installed=$(shellcheck --version | awk '$1 == "version:" { print $2; exit }')
jq --arg v "$installed" '.nix_packages.shellcheck = { expected: "locked nixpkgs package", resolved: $v }' \
  versions.lock.json >lock.tmp
mv lock.tmp versions.lock.json
assert_exit 0 static --only shell

# --- bans --------------------------------------------------------------------
fresh
printf '#!/usr/bin/env bash\n%s -fsSL https://example.invalid/i.sh | bash\n' "$BAN_FETCH" >scripts/a.sh
printf '#!/usr/bin/env bash\n%s %s origin main\n' "$BAN_PUSH" "$BAN_FORCE" >scripts/b.sh
printf '#!/usr/bin/env bash\n%s -C . push -f origin main\n' git >scripts/c.sh
printf '#!/usr/bin/env bash\napt-get install %s example-app\n' "$BAN_DOWNGRADE" >scripts/d.sh
chmod 0755 scripts/*.sh
fails bans "scripts/a.sh:2: a download piped into a shell" "scripts/b.sh:2: a forced git push" \
  "scripts/c.sh:2: a forced git push" "scripts/d.sh:2: a package downgrade flag"

# --- launcher and bootstrap ----------------------------------------------------
fresh
printf '# local change\n' >>.dotsteward/cli.sh
fails launcher ".dotsteward/cli.sh differs from the framework's template/.dotsteward/cli.sh"
fresh
rm .dotsteward/cli.sh
fails launcher ".dotsteward/cli.sh is missing"

if [[ -f $DS_REPO_ROOT/template/bootstrap.sh ]]; then
  fresh
  printf '# local change\n' >>bootstrap.sh
  fails bootstrap "bootstrap.sh differs from the framework's template/bootstrap.sh"
else
  fresh
  printf '#!/usr/bin/env bash\n' >bootstrap.sh
  chmod 0755 bootstrap.sh
  assert_exit 0 static --only bootstrap
fi

# --- hosts ---------------------------------------------------------------------
fresh
jq '.skills[0].machines = ["nobody"]' agent/skills.lock.json >lock.tmp && mv lock.tmp agent/skills.lock.json
fails hosts "agent/skills.lock.json: skill example-skill: machines names nobody, which has no hosts/nobody.toml"
mkdir -p hosts
printf 'schema_version = 1\n' >hosts/nobody.toml
assert_exit 0 static --only hosts
printf 'schema_version = 1\nunknown_key = true\n' >hosts/nobody.toml
fails hosts "hosts/nobody.toml:"
rm -rf hosts

# --- policy and versions-lock ---------------------------------------------------
# The policy is intent: workstation.toml [policy] holds it, and its defaults are the two fixed values.
fresh
assert_exit 0 static --only policy --only versions-lock
assert_not_contains "$DS_STDERR" "policy"
fresh
printf '\n[policy]\npersistent_agentic_updates = true\n' >>workstation.toml
fails policy "workstation.toml: policy.persistent_agentic_updates must be false"
fresh
printf '\n[policy]\nnative_application_updates = false\n' >>workstation.toml
fails policy "workstation.toml: policy.native_application_updates must be true"
fresh
printf '\n[policy]\npersistent_agentic_updates = false\nnative_application_updates = true\n' >>workstation.toml
assert_exit 0 static --only policy
# The versions lock holds no policy any more. One that an older instance still carries is read
# by nothing, whatever it says: static names it and stays green.
fresh
jq '.policy = {persistent_agentic_updates: true, native_application_updates: false}' versions.lock.json >lock.tmp &&
  mv lock.tmp versions.lock.json
assert_exit 0 static --only policy --only versions-lock
assert_contains "$DS_STDERR" \
  "[dotsteward] WARNING: static versions-lock: versions.lock.json: policy is read from workstation.toml [policy]; nothing reads it in the lock, remove it"
fresh
jq '.schema_version = "2.0"' versions.lock.json >lock.tmp && mv lock.tmp versions.lock.json
fails versions-lock 'versions.lock.json: schema_version must be "1.0"'
fresh
jq '.policy = "none"' versions.lock.json >lock.tmp && mv lock.tmp versions.lock.json
assert_exit 0 static --only versions-lock
assert_contains "$DS_STDERR" "versions.lock.json: policy is read from workstation.toml [policy]"
assert_not_contains "$DS_STDERR" "failed unexpectedly"
fresh
printf '{ broken\n' >versions.lock.json
fails versions-lock "versions.lock.json is not valid JSON"
fresh
rm versions.lock.json
fails versions-lock "versions.lock.json is missing"
# A configured lock path.
fresh
mv versions.lock.json pins.json
printf '\n[pins]\nversions_lock = "pins.json"\n' >>workstation.toml
assert_exit 0 static --only versions-lock

# --- allowlist ---------------------------------------------------------------
fresh
printf '\n[gate]\nupdate_allowlist = ["versions\\\\.lock\\\\.json", "local-maintained-files/.*"]\n' >>workstation.toml
fails allowlist 'gate.update_allowlist entry 2 matches the settings buffer path local-maintained-files/buffer.toml'
fresh
printf '\n[gate]\nupdate_allowlist = [".*"]\n' >>workstation.toml
fails allowlist 'gate.update_allowlist entry 1 matches the settings buffer path local-maintained-files'
fresh
printf '\n[gate]\nupdate_allowlist = ["versions\\\\.lock\\\\.json", "agent/.*"]\n' >>workstation.toml
assert_exit 0 static --only allowlist
# A configured buffer directory.
fresh
printf '\n[settings]\nbuffer_dir = "agent/settings"\n\n[gate]\nupdate_allowlist = ["agent/.*"]\n' >>workstation.toml
fails allowlist 'gate.update_allowlist entry 1 matches the settings buffer path agent/settings'
# Component contributions recorded in the committed manifest mirror.
fresh
jq -n '{schema_version: 1, update_allowlist: ["local-maintained-files/files/.*"]}' >.dotsteward/manifest.x86_64-linux.json
fails allowlist '.dotsteward/manifest.x86_64-linux.json update_allowlist entry 1 matches the settings buffer path local-maintained-files/files/'
fresh
printf '\n[gate]\nupdate_allowlist = ["(unclosed"]\n' >>workstation.toml
fails allowlist 'gate.update_allowlist entry 1 is not a valid extended regular expression'

# --- protected ---------------------------------------------------------------
fresh
printf '\n[protected]\n"home/AGENTS.md" = "%s"\n' "$(sha256_of home/AGENTS.md)" >>workstation.toml
assert_exit 0 static --only protected
printf 'changed\n' >>home/AGENTS.md
fails protected "home/AGENTS.md: bytes changed (sha256 does not match [protected])"
rm home/AGENTS.md
fails protected "home/AGENTS.md: protected file is missing"

# --- overlays ----------------------------------------------------------------
fresh
mkdir -p agent/overlays
printf 'Extra steps.\n' >agent/overlays/dotsteward-update.md
# README.md documents the directory (the template ships one); it is not an
# overlay.
printf '# Overlays\n' >agent/overlays/README.md
assert_exit 0 static --only overlays
printf 'Extra steps.\n' >agent/overlays/README.txt
fails overlays "agent/overlays/README.txt: README.txt is not a framework skill"
rm agent/overlays/README.txt
printf 'Extra steps.\n' >agent/overlays/example-skill.md
fails overlays "agent/overlays/example-skill.md: example-skill is not a framework skill"
fresh
printf '\n[skills.overlays]\ndotsteward-maintain = "docs/maintain-overlay.md"\n' >>workstation.toml
fails overlays "docs/maintain-overlay.md: overlay of dotsteward-maintain is missing"
mkdir -p docs
printf 'Extra steps.\n' >docs/maintain-overlay.md
assert_exit 0 static --only overlays

# --- every failure of a run is reported --------------------------------------
fresh
printf '# local change\n' >>.dotsteward/cli.sh
printf '\n[policy]\nnative_application_updates = false\n' >>workstation.toml
assert_exit 1 static
assert_contains "$DS_STDERR" "static launcher:"
assert_contains "$DS_STDERR" "static policy:"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: static checks failed (instance): launcher policy"
